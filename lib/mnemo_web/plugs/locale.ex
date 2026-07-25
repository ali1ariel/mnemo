defmodule MnemoWeb.Plugs.Locale do
  @moduledoc """
  Locale resolution: explicit preference in settings wins, then
  `Accept-Language` (the webview reflects the OS locale), then English.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    locale = Mnemo.Settings.locale() || from_header(conn) || "en"
    Gettext.put_locale(MnemoWeb.Gettext, locale)
    put_session(conn, :locale, locale)
  end

  defp from_header(conn) do
    conn
    |> get_req_header("accept-language")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(fn tag -> tag |> String.split(";") |> hd() |> String.trim() end)
    |> Enum.find_value(&match_locale/1)
  end

  defp match_locale(tag) do
    known = Gettext.known_locales(MnemoWeb.Gettext)
    tag = String.replace(tag, "-", "_")
    prefix = tag |> String.split("_") |> hd()

    Enum.find(known, &(&1 == tag)) || Enum.find(known, &String.starts_with?(&1, prefix))
  end
end
