defmodule MnemoWeb.Format do
  @moduledoc false

  use Gettext, backend: MnemoWeb.Gettext

  def relative_time(nil), do: gettext("never")

  def relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      diff < 60 ->
        gettext("just now")

      diff < 3600 ->
        ngettext("%{count} minute ago", "%{count} minutes ago", div(diff, 60))

      diff < 86_400 ->
        ngettext("%{count} hour ago", "%{count} hours ago", div(diff, 3600))

      true ->
        ngettext("%{count} day ago", "%{count} days ago", div(diff, 86_400))
    end
  end
end
