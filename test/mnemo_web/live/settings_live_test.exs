defmodule MnemoWeb.SettingsLiveTest do
  use MnemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mnemo.Settings

  test "renders credentials, connection and language sections", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/settings")

    assert has_element?(view, "#google-credentials")
    assert has_element?(view, "#drive-connection")
    assert has_element?(view, "#language-settings")
    assert html =~ "Client ID"
  end

  test "saves trimmed credentials", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#credentials-form",
      credentials: %{
        client_id: "  my-id.apps.googleusercontent.com  ",
        client_secret: "  s3cret  "
      }
    )
    |> render_submit()

    assert Settings.google_client_id() == "my-id.apps.googleusercontent.com"
    assert Settings.google_client_secret() == "s3cret"
    assert render(view) =~ "Credentials saved."
  end

  test "a blank client id is rejected and nothing is saved", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#credentials-form", credentials: %{client_id: "   ", client_secret: "x"})
    |> render_submit()

    assert Settings.google_client_id() == nil
    assert Settings.google_client_secret() == nil
    assert render(view) =~ "cannot be blank"
  end

  test "a blank secret keeps the stored one", %{conn: conn} do
    Settings.put_google_client_id("id-1")
    Settings.put_google_client_secret("keep-me")

    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#credentials-form", credentials: %{client_id: "id-2", client_secret: ""})
    |> render_submit()

    assert Settings.google_client_id() == "id-2"
    assert Settings.google_client_secret() == "keep-me"
  end

  test "prefills the client id and hints that a secret exists", %{conn: conn} do
    Settings.put_google_client_id("saved-id")
    Settings.put_google_client_secret("saved-secret")

    {:ok, _view, html} = live(conn, ~p"/settings")

    assert html =~ "saved-id"
    assert html =~ "Leave the field blank to keep it."
    refute html =~ "saved-secret"
  end

  test "changing the language persists and forces a full reload", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#language-form", language: %{locale: "pt_BR"})
    |> render_change()

    assert_redirect(view, "/settings")
    assert Settings.locale() == "pt_BR"
  end

  test "system default clears the stored preference", %{conn: conn} do
    Settings.put_locale("pt_BR")

    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#language-form", language: %{locale: ""})
    |> render_change()

    assert_redirect(view, "/settings")
    assert Settings.locale() == nil
  end
end
