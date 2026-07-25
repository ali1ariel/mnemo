defmodule Mnemo.CoverExternalFake do
  def configured?, do: true

  def fetch(name) do
    send(Application.fetch_env!(:mnemo, :cover_external_test_pid), {:cover_fetch, name})
    Application.fetch_env!(:mnemo, :cover_external_test_result)
  end
end
