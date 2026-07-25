defmodule MnemoWeb.LocaleHook do
  @moduledoc "Carries the locale resolved by the plug into LiveView processes."

  def on_mount(:default, _params, session, socket) do
    Gettext.put_locale(MnemoWeb.Gettext, session["locale"] || "en")
    {:cont, socket}
  end
end
