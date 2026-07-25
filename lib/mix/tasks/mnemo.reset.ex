defmodule Mix.Tasks.Mnemo.Reset do
  @shortdoc "Wipes local sync state and/or the remote mnemo folder"

  @moduledoc """
  Puts mnemo back to a clean slate during development.

      mix mnemo.reset --local           # games, generations and blobs in SQLite
      mix mnemo.reset --remote          # the whole /mnemo folder in Drive
      mix mnemo.reset --all             # both
      mix mnemo.reset --all --yes       # no confirmation prompt
      mix mnemo.reset --local --new-device

  Your Google credentials and language preference always survive, so you
  do not have to paste them again on every iteration. `--new-device`
  additionally forgets this machine's `device_id`, making the next sync
  look like a brand new install — useful for exercising the conflict
  paths against a remote that already has history.

  The remote wipe is a permanent delete, not a move to the trash. It only
  ever touches the `/mnemo` folder mnemo itself created; the `drive.file`
  scope makes reaching anything else impossible.
  """

  use Mix.Task

  @requirements ["app.start"]

  @switches [
    local: :boolean,
    remote: :boolean,
    all: :boolean,
    yes: :boolean,
    new_device: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    if Mix.env() == :prod do
      Mix.raise("mix mnemo.reset is a development tool and refuses to run in prod")
    end

    {opts, _rest, _invalid} = OptionParser.parse(args, strict: @switches)

    local? = opts[:local] || opts[:all] || false
    remote? = opts[:remote] || opts[:all] || false

    cond do
      not local? and not remote? -> Mix.raise("pass --local, --remote or --all")
      confirmed?(opts, local?, remote?) -> execute(opts, local?, remote?)
      true -> Mix.shell().info("Aborted, nothing was deleted.")
    end
  end

  defp execute(opts, local?, remote?) do
    if remote?, do: report_remote(Mnemo.Reset.remote())
    if local?, do: report_local(Mnemo.Reset.local(new_device: opts[:new_device]))
  end

  defp report_remote({:ok, :deleted}), do: Mix.shell().info("Remote: /mnemo deleted.")
  defp report_remote({:ok, :absent}), do: Mix.shell().info("Remote: /mnemo did not exist.")

  defp report_remote({:error, reason}) do
    Mix.raise("Remote wipe failed, local state untouched: #{inspect(reason)}")
  end

  defp report_local(counts) do
    Mix.shell().info(
      "Local: #{counts.games} games, #{counts.generations} generations, " <>
        "#{counts.blobs} blobs, #{counts.settings} settings removed."
    )
  end

  defp confirmed?(opts, local?, remote?) do
    if opts[:yes] do
      true
    else
      targets =
        [remote? && "the /mnemo folder in Google Drive", local? && "all local sync state"]
        |> Enum.filter(& &1)
        |> Enum.join(" and ")

      Mix.shell().yes?("This permanently deletes #{targets}. Continue?")
    end
  end
end
