defmodule Mnemo.SettingsTest do
  use Mnemo.DataCase, async: false

  alias Mnemo.Settings

  test "device_id is generated on first use and stays stable" do
    id = Settings.device_id()
    assert {:ok, _} = Ecto.UUID.cast(id)
    assert Settings.device_id() == id
  end

  test "put, get and delete round-trip" do
    assert Settings.get("locale") == nil
    Settings.put("locale", "pt_BR")
    assert Settings.get("locale") == "pt_BR"
    Settings.put("locale", "en")
    assert Settings.get("locale") == "en"
    Settings.delete("locale")
    assert Settings.get("locale") == nil
  end
end
