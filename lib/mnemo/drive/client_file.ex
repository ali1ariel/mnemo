defmodule Mnemo.Drive.ClientFile do
  @moduledoc """
  Parses the OAuth client JSON that the Google Cloud console offers for
  download.

  Desktop clients nest their fields under `"installed"`. A `"web"` key
  means the user created a Web application client instead, which cannot
  do the loopback flow — that case is reported on its own so the
  interface can say exactly what went wrong.
  """

  @max_bytes 65_536

  @type client :: %{client_id: String.t(), client_secret: String.t()}
  @type reason :: :too_large | :invalid_json | :wrong_client_type | :missing_fields

  @spec parse(binary()) :: {:ok, client()} | {:error, reason()}
  def parse(raw) when is_binary(raw) do
    if byte_size(raw) > @max_bytes do
      {:error, :too_large}
    else
      decode(raw)
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, %{"installed" => %{} = client}} -> extract(client)
      {:ok, %{"web" => %{}}} -> {:error, :wrong_client_type}
      # Tolerate a flat file someone assembled by hand.
      {:ok, %{} = flat} -> extract(flat)
      {:ok, _not_an_object} -> {:error, :missing_fields}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp extract(%{"client_id" => id, "client_secret" => secret})
       when is_binary(id) and is_binary(secret) do
    id = String.trim(id)
    secret = String.trim(secret)

    if id == "" or secret == "" do
      {:error, :missing_fields}
    else
      {:ok, %{client_id: id, client_secret: secret}}
    end
  end

  defp extract(_), do: {:error, :missing_fields}
end
