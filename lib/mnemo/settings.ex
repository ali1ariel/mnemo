defmodule Mnemo.Settings do
  @moduledoc """
  Key/value machine state: this device's id, cached Drive folder ids,
  preferred locale.

  Everything here is rebuildable or machine-local; the database is never
  the source of truth.
  """

  alias Mnemo.Repo
  alias Mnemo.Settings.Setting

  def get(key) when is_binary(key) do
    case Repo.get(Setting, key) do
      nil -> nil
      %Setting{value: value} -> value
    end
  end

  def put(key, value) when is_binary(key) and (is_binary(value) or is_nil(value)) do
    Repo.insert!(%Setting{key: key, value: value},
      on_conflict: {:replace, [:value]},
      conflict_target: :key
    )

    value
  end

  def delete(key) when is_binary(key) do
    case Repo.get(Setting, key) do
      nil -> :ok
      setting -> Repo.delete!(setting)
    end

    :ok
  end

  @doc """
  This machine's stable identity, generated on first use.

  It exists in order to differ between machines — it is what makes
  `device_id` on a generation meaningful for conflict detection.
  """
  def device_id do
    get("device_id") || put("device_id", Ecto.UUID.generate())
  end

  def locale, do: get("locale")
  def put_locale(locale), do: put("locale", locale)
end
