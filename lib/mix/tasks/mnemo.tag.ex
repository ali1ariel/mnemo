defmodule Mix.Tasks.Mnemo.Tag do
  @shortdoc "Sets the release version everywhere, commits it and tags it"

  @moduledoc """
  Cuts a release: one version written to every file that states one, a
  commit holding exactly that change, and the tag the workflow builds
  from.

      mix mnemo.tag 1.2.0               # an explicit version
      mix mnemo.tag patch               # 1.2.0 -> 1.2.1
      mix mnemo.tag minor               # 1.2.1 -> 1.3.0
      mix mnemo.tag major               # 1.3.0 -> 2.0.0
      mix mnemo.tag 1.2.0 --push        # push the commit and the tag
      mix mnemo.tag 1.2.0 --force       # move a tag that already exists
      mix mnemo.tag patch --yes         # no confirmation prompt

  The version lives in four files, and `.github/workflows/release.yml`
  checks all of them against the tag before it builds anything. Bumping
  them by hand means noticing the fourth one after the tag is already
  pushed and the build has already failed, so this task writes them
  together or not at all.

  Tagging is separate from pushing. The tag is what triggers the release
  workflow, and a tag that exists only locally is one `git tag -d` away
  from never having happened — so `--push` is asked for explicitly.
  """

  use Mix.Task

  @switches [push: :boolean, force: :boolean, yes: :boolean]

  # Each pattern captures the version in group 2, so the same expression
  # both reads the current value and writes the new one. A pattern that
  # stops matching after an unrelated edit therefore fails loudly at the
  # read, instead of silently leaving that file behind.
  @files [
    %{
      path: "mix.exs",
      pattern: ~r/(version:\s+")(\d+\.\d+\.\d+[^"]*)(")/
    },
    %{
      path: "desktop/src-tauri/tauri.conf.json",
      pattern: ~r/("version":\s+")(\d+\.\d+\.\d+[^"]*)(")/
    },
    %{
      path: "desktop/src-tauri/Cargo.toml",
      pattern: ~r/^(\[package\].*?^version\s+=\s+")(\d+\.\d+\.\d+[^"]*)(")/ms
    },
    # The lock file states the workspace crate's own version too. Cargo
    # rewrites it on the next build either way, but leaving it stale
    # means the release build starts with a dirty tree.
    %{
      path: "desktop/src-tauri/Cargo.lock",
      pattern: ~r/(name = "mnemo-desktop"\nversion = ")(\d+\.\d+\.\d+[^"]*)(")/
    }
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    case invalid do
      [] -> :ok
      [{switch, _value} | _] -> Mix.raise("unknown option: #{switch}")
    end

    version = target_version(rest)
    tag = "v" <> version

    ensure_clean_tree!()
    ensure_taggable!(tag, opts)

    if confirmed?(version, tag, opts) do
      Enum.each(@files, &write_version!(&1, version))
      commit(version)
      tag(tag, version, opts)
      if opts[:push], do: push(tag, opts)
      report(tag, opts)
    else
      Mix.shell().info("Aborted, nothing was written.")
    end
  end

  ## Version

  defp target_version([]) do
    Mix.raise("pass a version (1.2.0) or a bump (major, minor, patch)")
  end

  defp target_version([bump]) when bump in ~w(major minor patch) do
    current = read_version!(hd(@files))
    parsed = Version.parse!(current)

    case bump do
      "major" -> "#{parsed.major + 1}.0.0"
      "minor" -> "#{parsed.major}.#{parsed.minor + 1}.0"
      "patch" -> "#{parsed.major}.#{parsed.minor}.#{parsed.patch + 1}"
    end
  end

  defp target_version([version]) do
    case Version.parse(version) do
      {:ok, _parsed} -> version
      :error -> Mix.raise("#{version} is not a version; expected something like 1.2.0")
    end
  end

  defp target_version(_many), do: Mix.raise("pass exactly one version or bump")

  defp read_version!(%{path: path, pattern: pattern}) do
    case Regex.run(pattern, File.read!(path), capture: :all_but_first) do
      [_prefix, version, _suffix] -> version
      _ -> Mix.raise("could not find a version in #{path}")
    end
  end

  defp write_version!(%{path: path, pattern: pattern} = file, version) do
    current = read_version!(file)

    # `\g{1}`, not `\1`: the version follows the group immediately, and
    # `\1` next to a version starting with 1 reads as a reference to
    # group 11, which does not exist and expands to nothing — taking the
    # matched line with it.
    updated = Regex.replace(pattern, File.read!(path), "\\g{1}#{version}\\g{3}", global: false)

    File.write!(path, updated)
    Mix.shell().info("  #{path}: #{current} -> #{version}")
  end

  ## Git

  defp ensure_clean_tree!() do
    case git(["status", "--porcelain"]) do
      {"", 0} ->
        :ok

      {_changes, 0} ->
        Mix.raise(
          "the working tree has changes; commit or stash them so the tag holds " <>
            "the version bump and nothing else"
        )

      {output, _code} ->
        Mix.raise("git status failed: #{output}")
    end
  end

  defp ensure_taggable!(tag, opts) do
    case git(["tag", "--list", tag]) do
      {"", 0} ->
        :ok

      {_found, 0} ->
        unless opts[:force] do
          Mix.raise(
            "#{tag} already exists. Pass --force to move it, or pick another version. " <>
              "Moving a tag that was already pushed rewrites a release others may " <>
              "have downloaded."
          )
        end

      {output, _code} ->
        Mix.raise("git tag --list failed: #{output}")
    end
  end

  defp commit(version) do
    paths = Enum.map(@files, & &1.path)

    git!(["add", "--" | paths])

    case git(["diff", "--cached", "--quiet"]) do
      # Re-tagging the version the tree already states: there is nothing
      # to commit, and the tag lands on HEAD as it is.
      {_output, 0} ->
        Mix.shell().info("Version already #{version} in every file, tagging HEAD.")

      _changed ->
        git!(["commit", "--message", "tag: #{version}"])
    end
  end

  defp tag(tag, version, opts) do
    force = if opts[:force], do: ["--force"], else: []
    git!(["tag", "--annotate"] ++ force ++ ["--message", "mnemo #{version}", tag])
  end

  defp push(tag, opts) do
    git!(["push", "origin", "HEAD"])
    git!(["push", "origin", tag] ++ if(opts[:force], do: ["--force"], else: []))
  end

  defp git(args) do
    {output, code} = System.cmd("git", args, stderr_to_stdout: true)
    {String.trim(output), code}
  end

  defp git!(args) do
    case git(args) do
      {output, 0} -> output
      {output, code} -> Mix.raise("git #{Enum.join(args, " ")} exited with #{code}:\n#{output}")
    end
  end

  ## Interaction

  defp confirmed?(version, tag, opts) do
    if opts[:yes] do
      true
    else
      {branch, _} = git(["rev-parse", "--abbrev-ref", "HEAD"])

      Mix.shell().yes?(
        "Set every version to #{version}, commit it on #{branch} and tag it #{tag}" <>
          if(opts[:push], do: ", then push both", else: "") <> ". Continue?"
      )
    end
  end

  defp report(tag, opts) do
    if opts[:push] do
      Mix.shell().info("Pushed #{tag}. The release workflow is building it.")
    else
      Mix.shell().info("""
      Tagged #{tag}. Nothing is pushed yet; the release workflow runs on:

          git push origin HEAD && git push origin #{tag}
      """)
    end
  end
end
