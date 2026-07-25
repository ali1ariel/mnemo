defmodule Mnemo.Drive.ClientFileTest do
  use ExUnit.Case, async: true

  alias Mnemo.Drive.ClientFile

  defp desktop_json(overrides \\ %{}) do
    installed =
      Map.merge(
        %{
          "client_id" => "975751473433-abc.apps.googleusercontent.com",
          "project_id" => "mnemo-123456",
          "auth_uri" => "https://accounts.google.com/o/oauth2/auth",
          "token_uri" => "https://oauth2.googleapis.com/token",
          "client_secret" => "GOCSPX-secret",
          "redirect_uris" => ["http://localhost"]
        },
        overrides
      )

    Jason.encode!(%{"installed" => installed})
  end

  test "reads a desktop client file as downloaded from the console" do
    assert {:ok, client} = ClientFile.parse(desktop_json())
    assert client.client_id == "975751473433-abc.apps.googleusercontent.com"
    assert client.client_secret == "GOCSPX-secret"
  end

  test "trims whitespace around the values" do
    assert {:ok, client} =
             ClientFile.parse(
               desktop_json(%{"client_id" => "  id-1  ", "client_secret" => "\n secret \t"})
             )

    assert client.client_id == "id-1"
    assert client.client_secret == "secret"
  end

  test "a web application client is reported as the wrong type" do
    json =
      Jason.encode!(%{
        "web" => %{"client_id" => "id-1", "client_secret" => "secret"}
      })

    assert ClientFile.parse(json) == {:error, :wrong_client_type}
  end

  test "rejects files missing either key" do
    assert ClientFile.parse(desktop_json(%{"client_secret" => ""})) == {:error, :missing_fields}

    assert ClientFile.parse(Jason.encode!(%{"installed" => %{"client_id" => "x"}})) ==
             {:error, :missing_fields}

    assert ClientFile.parse(Jason.encode!(%{"unrelated" => true})) == {:error, :missing_fields}
    assert ClientFile.parse(Jason.encode!([1, 2, 3])) == {:error, :missing_fields}
  end

  test "rejects non-JSON content" do
    assert ClientFile.parse("not json at all") == {:error, :invalid_json}
    assert ClientFile.parse(<<0, 1, 2, 3>>) == {:error, :invalid_json}
  end

  test "rejects oversized input without parsing it" do
    assert ClientFile.parse(String.duplicate("x", 70_000)) == {:error, :too_large}
  end

  test "accepts a flat file written by hand" do
    json = Jason.encode!(%{"client_id" => "id-1", "client_secret" => "secret"})
    assert {:ok, %{client_id: "id-1", client_secret: "secret"}} = ClientFile.parse(json)
  end
end
