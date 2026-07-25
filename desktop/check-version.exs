expected =
  System.fetch_env!("EXPECTED_VERSION")
  |> String.trim()
  |> String.trim_leading("v")

tauri =
  "desktop/src-tauri/tauri.conf.json"
  |> File.read!()
  |> Jason.decode!()
  |> Map.fetch!("version")

cargo =
  case Regex.run(
         ~r/^\[package\].*?^version\s*=\s*"([^"]+)"/ms,
         File.read!("desktop/src-tauri/Cargo.toml"),
         capture: :all_but_first
       ) do
    [version] -> version
    _ -> raise "could not read the desktop Cargo package version"
  end

versions = %{
  "release tag" => expected,
  "mix.exs" => Mix.Project.config()[:version],
  "tauri.conf.json" => tauri,
  "Cargo.toml" => cargo
}

case versions |> Map.values() |> Enum.uniq() do
  [_version] ->
    IO.puts("release version #{expected} is consistent")

  _versions ->
    details = Enum.map_join(versions, "\n", fn {source, version} -> "  #{source}: #{version}" end)
    raise "release versions do not match:\n#{details}"
end
