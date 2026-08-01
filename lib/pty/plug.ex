defmodule Pty.Plug do
  @moduledoc """
  Upgrades a request to `Pty.Socket`. The one-line mount for a host endpoint.

      # Plug / Bandit
      forward "/pty", to: Pty.Plug

      # Phoenix router — inside a pipeline that does NOT parse the body
      get "/pty", Pty.Plug, []

  Every request reaching this plug is treated as a terminal upgrade; routing
  (and **authentication** — a session is a shell running as your user) is the
  host's job. It responds `400` for a missing or malformed session id, `426`
  when the id is fine but the request is not a WebSocket upgrade, and otherwise
  hands off to `Pty.Socket`.

  ## Options

    * `:param` — query parameter carrying the session id (default `"s"`).
    * `:session_opts` — spawn options (see `Pty.Session`) for a session this
      connection starts. May be a keyword list, or a 1-arity function of the
      `conn` for per-request values (a cwd from the path, say).
    * `:timeout` — WebSocket idle timeout, default `:infinity` (a terminal is
      idle whenever its human is thinking).
  """

  @behaviour Plug

  import Plug.Conn

  @status_bad_request 400
  @status_upgrade_required 426

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    conn = fetch_query_params(conn)
    id = conn.query_params[Keyword.get(opts, :param, "s")]

    cond do
      not Pty.valid_id?(id) ->
        send_resp(conn, @status_bad_request, "invalid session id")

      not upgrade?(conn) ->
        send_resp(conn, @status_upgrade_required, "expected websocket upgrade")

      true ->
        upgrade(conn, id, opts)
    end
  end

  defp upgrade(conn, id, opts) do
    arg = %{session_id: id, session_opts: session_opts(conn, opts)}

    conn
    |> WebSockAdapter.upgrade(Pty.Socket, arg, timeout: Keyword.get(opts, :timeout, :infinity))
    |> halt()
  end

  defp session_opts(conn, opts) do
    case Keyword.get(opts, :session_opts, []) do
      fun when is_function(fun, 1) -> fun.(conn)
      list -> list
    end
  end

  defp upgrade?(conn) do
    conn |> get_req_header("upgrade") |> Enum.any?(&(String.downcase(&1) =~ "websocket"))
  end
end
