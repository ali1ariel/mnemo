defmodule Mnemo.Drive.Auth do
  @moduledoc """
  Installed-app OAuth with PKCE and a loopback redirect.

  A throwaway `:gen_tcp` listener on `127.0.0.1:<random port>` catches the
  browser redirect; Google allows any loopback port for desktop clients.
  """

  @auth_endpoint "https://accounts.google.com/o/oauth2/v2/auth"
  @token_endpoint "https://oauth2.googleapis.com/token"
  @scope "https://www.googleapis.com/auth/drive.file"
  @flow_timeout_ms 300_000

  @doc """
  Run the whole flow: open the browser, wait for the redirect, exchange
  the code. Blocks for up to five minutes; run inside a task.

  `on_url` receives the authorization URL so the UI can show it as a
  fallback when the browser did not open.
  """
  def run(%{client_id: client_id} = client, on_url \\ fn _ -> :ok end)
      when is_binary(client_id) do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(lsock)
    redirect_uri = "http://127.0.0.1:#{port}"

    url = authorize_url(client_id, redirect_uri, challenge)
    on_url.(url)
    open_browser(url)

    deadline = System.monotonic_time(:millisecond) + @flow_timeout_ms
    result = accept_loop(lsock, deadline)
    :gen_tcp.close(lsock)

    with {:ok, code} <- result do
      exchange_code(client, code, redirect_uri, verifier)
    end
  end

  def authorize_url(client_id, redirect_uri, challenge) do
    query =
      URI.encode_query(%{
        client_id: client_id,
        redirect_uri: redirect_uri,
        response_type: "code",
        scope: @scope,
        code_challenge: challenge,
        code_challenge_method: "S256",
        access_type: "offline",
        prompt: "consent"
      })

    @auth_endpoint <> "?" <> query
  end

  defp accept_loop(lsock, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      case :gen_tcp.accept(lsock, remaining) do
        {:ok, sock} ->
          case handle_request(sock) do
            :continue -> accept_loop(lsock, deadline)
            result -> result
          end

        {:error, :timeout} ->
          {:error, :timeout}

        {:error, reason} ->
          {:error, {:listener, reason}}
      end
    end
  end

  defp handle_request(sock) do
    result =
      case :gen_tcp.recv(sock, 0, 10_000) do
        {:ok, request} -> parse_request(request)
        {:error, _} -> :continue
      end

    case result do
      {:ok, _code} -> respond(sock, 200, success_page())
      {:error, _} -> respond(sock, 200, failure_page())
      # Browsers also ask for favicon.ico; answer and keep waiting.
      :continue -> respond(sock, 404, "")
    end

    :gen_tcp.close(sock)
    result
  end

  defp parse_request(request) do
    with [line | _] <- String.split(request, "\r\n"),
         ["GET", target, _version] <- String.split(line, " "),
         %URI{query: query} when is_binary(query) <- URI.parse(target),
         params = URI.decode_query(query),
         true <- Map.has_key?(params, "code") or Map.has_key?(params, "error") do
      case params do
        %{"code" => code} -> {:ok, code}
        %{"error" => error} -> {:error, {:oauth, error}}
      end
    else
      _ -> :continue
    end
  end

  defp respond(sock, status, body) do
    reason = if status == 200, do: "OK", else: "Not Found"

    response = [
      "HTTP/1.1 #{status} #{reason}\r\n",
      "content-type: text/html; charset=utf-8\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ]

    :gen_tcp.send(sock, response)
  end

  defp success_page do
    """
    <html><body style="font-family: system-ui; display: grid; place-items: center; height: 90vh">
    <div style="text-align: center">
    <h2>mnemo is connected to Google Drive.</h2>
    <p>You can close this window. / Você já pode fechar esta janela.</p>
    </div></body></html>
    """
  end

  defp failure_page do
    """
    <html><body style="font-family: system-ui; display: grid; place-items: center; height: 90vh">
    <div style="text-align: center">
    <h2>mnemo was not authorized.</h2>
    <p>You can close this window and try again. / Feche esta janela e tente novamente.</p>
    </div></body></html>
    """
  end

  defp exchange_code(client, code, redirect_uri, verifier) do
    form = [
      code: code,
      client_id: client.client_id,
      client_secret: client.client_secret,
      redirect_uri: redirect_uri,
      grant_type: "authorization_code",
      code_verifier: verifier
    ]

    token_request(form)
  end

  def refresh(client, refresh_token) do
    form = [
      refresh_token: refresh_token,
      client_id: client.client_id,
      client_secret: client.client_secret,
      grant_type: "refresh_token"
    ]

    token_request(form)
  end

  defp token_request(form) do
    case Req.post(@token_endpoint, form: form, retry: false) do
      {:ok, %{status: 200, body: body}} ->
        {:ok,
         %{
           access_token: body["access_token"],
           refresh_token: body["refresh_token"],
           expires_in: body["expires_in"] || 3600
         }}

      {:ok, %{status: status, body: %{"error" => "invalid_grant"}}} ->
        {:error, {:invalid_grant, status}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:token_endpoint, %{status: status, body: body}}}

      {:error, exception} ->
        {:error, {:network, Exception.message(exception)}}
    end
  end

  defp open_browser(url) do
    spawn(fn ->
      case :os.type() do
        {:win32, _} -> System.cmd("cmd", ["/c", "start", "", url], stderr_to_stdout: true)
        {:unix, :darwin} -> System.cmd("open", [url], stderr_to_stdout: true)
        {:unix, _} -> System.cmd("xdg-open", [url], stderr_to_stdout: true)
      end
    end)

    :ok
  end
end
