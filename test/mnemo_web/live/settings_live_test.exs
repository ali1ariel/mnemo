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

  test "presents setup as two numbered steps that both have to happen", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/settings")

    assert has_element?(view, "#drive-setup")
    assert html =~ "Step 1"
    assert html =~ "Step 2"
    assert html =~ "both are needed"
  end

  test "spells out that credentials are reused across computers", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings")

    assert html =~ "reuse the very same ones on every computer"
    assert html =~ "once per computer"
    assert html =~ "Already set mnemo up on another computer?"
  end

  test "step 1 tracks whether credentials exist and step 2 points back at it", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/settings")

    assert html =~ "Pending"
    assert html =~ "Finish step 1 first"

    view
    |> form("#credentials-form", credentials: %{client_id: "id-1", client_secret: "s3cret"})
    |> render_submit()

    html = render(view)
    assert html =~ "Saved"
    refute html =~ "Finish step 1 first"
    assert html =~ "credentials from step 1"
  end

  test "ships a step-by-step OAuth guide behind a disclosure", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/settings")

    assert has_element?(view, "details#oauth-guide")
    assert html =~ "How to get these credentials, step by step"
    assert html =~ "Desktop app"
    assert html =~ "https://console.cloud.google.com/auth/clients"
    assert html =~ "unverified app"
  end

  test "states the permission scope up front, outside the collapsed guide", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/settings")

    assert has_element?(view, "#privacy-note")
    assert html =~ "only ever sees the folder it creates"
    assert html =~ "only the specific Google Drive files you use with this app"
    assert html =~ "https://myaccount.google.com/permissions"

    # The reassurance must not be buried inside the disclosure the user
    # has to open — suspicion happens before anyone clicks anything.
    document = LazyHTML.from_fragment(html)
    assert LazyHTML.filter(document, "details#oauth-guide #privacy-note") |> Enum.empty?()
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

    view |> element("#change-credentials") |> render_click()

    view
    |> form("#credentials-form", credentials: %{client_id: "id-2", client_secret: ""})
    |> render_submit()

    assert Settings.google_client_id() == "id-2"
    assert Settings.google_client_secret() == "keep-me"
  end

  test "saved credentials stay compact until the user chooses to change them", %{conn: conn} do
    Settings.put_google_client_id("saved-id")
    Settings.put_google_client_secret("saved-secret")

    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#credentials-saved-summary")
    assert has_element?(view, "#change-credentials")
    refute has_element?(view, "#credentials-editor")
    refute has_element?(view, "#credentials-form")

    view |> element("#change-credentials") |> render_click()

    assert has_element?(view, "#credentials-editor")
    assert has_element?(view, "#credentials-form")
    html = render(view)
    assert html =~ "saved-id"
    assert html =~ "Leave the field blank to keep it."
    refute html =~ "saved-secret"
  end

  test "saved cover key shows a badge and stays compact until changed", %{conn: conn} do
    Settings.put("steamgriddb_api_key", "saved-cover-key")

    {:ok, view, html} = live(conn, ~p"/settings")

    assert has_element?(view, "#cover-art .badge-success")
    assert has_element?(view, "#cover-key-saved-summary")
    assert has_element?(view, "#change-cover-key")
    refute has_element?(view, "#cover-form")
    refute html =~ "saved-cover-key"

    view |> element("#change-cover-key") |> render_click()

    assert has_element?(view, "#cover-form")
  end

  test "saving a cover key collapses its editor", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#cover-form")

    view
    |> form("#cover-form", cover: %{steamgriddb_api_key: "new-cover-key"})
    |> render_submit()

    assert Settings.get("steamgriddb_api_key") == "new-cover-key"
    assert has_element?(view, "#cover-key-saved-summary")
    refute has_element?(view, "#cover-form")
  end

  describe "importing the JSON file from Google" do
    defp upload_json(view, content, name \\ "client_secret_123.json") do
      file =
        file_input(view, "#client-file-form", :client_file, [
          %{name: name, content: content, type: "application/json"}
        ])

      render_upload(file, name)
    end

    defp desktop_json(client_id, secret) do
      Jason.encode!(%{
        "installed" => %{
          "client_id" => client_id,
          "project_id" => "mnemo-123",
          "client_secret" => secret,
          "redirect_uris" => ["http://localhost"]
        }
      })
    end

    test "saves both keys and flips step 1 to done", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      upload_json(view, desktop_json("imported-id.apps.googleusercontent.com", "GOCSPX-imported"))

      assert Settings.google_client_id() == "imported-id.apps.googleusercontent.com"
      assert Settings.google_client_secret() == "GOCSPX-imported"

      html = render(view)
      assert html =~ "Credentials saved."
      assert has_element?(view, "#credentials-saved-summary")
      refute has_element?(view, "#credentials-form")
      refute html =~ "GOCSPX-imported"
    end

    test "a web application client is named as the wrong type", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      json = Jason.encode!(%{"web" => %{"client_id" => "x", "client_secret" => "y"}})
      upload_json(view, json)

      assert render(view) =~ "Web application"
      assert Settings.google_client_id() == nil
    end

    test "junk content is rejected without touching the stored credentials", %{conn: conn} do
      Settings.put_google_client_id("kept-id")
      Settings.put_google_client_secret("kept-secret")

      {:ok, view, _html} = live(conn, ~p"/settings")
      view |> element("#change-credentials") |> render_click()
      upload_json(view, "this is not json")

      assert render(view) =~ "not valid JSON"
      assert Settings.google_client_id() == "kept-id"
      assert Settings.google_client_secret() == "kept-secret"
    end

    test "a JSON without the expected keys is rejected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      upload_json(view, Jason.encode!(%{"something" => "else"}))

      assert render(view) =~ "does not look like a Google OAuth client file"
      assert Settings.google_client_id() == nil
    end
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
