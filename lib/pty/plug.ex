defmodule Pty.Plug do
  @moduledoc """
  Upgrades a request to `Pty.Socket`. The one-line mount for a host endpoint.

      # Plug / Bandit
      forward "/pty", to: Pty.Plug

      # Phoenix router — inside a pipeline that does NOT parse the body
      get "/pty", Pty.Plug, []

  Every request reaching this plug is treated as a terminal upgrade; routing
  (and **authentication** — a session is a shell running as your user) is the
  host's job. It responds `400` for a missing or malformed session id, `403`
  for a browser `Origin` that `:check_origin` refuses, `426` when the request
  is not a WebSocket upgrade, and otherwise hands off to `Pty.Socket`.

  ## Options

    * `:check_origin` — a WebSocket handshake escapes CORS, so any page the user
      visits could otherwise open a terminal here (cross-site WebSocket
      hijacking). `true` (default) admits an `Origin` whose host is the
      request's `Host` — host only, any scheme or port, as Phoenix does, so a
      fronting proxy must forward `Host`; a list admits exactly those
      serialized origins (`["http://localhost:4000"]`), the stricter choice on
      loopback, where every local port shares the host; `false` disables it. A request with
      no `Origin` — a non-browser client — always passes.
    * `:param` — query parameter carrying the session id (default `"s"`). A
      `reattach` parameter (any value), which `pty.js` sends on every reconnect,
      makes the connection attach-only (see `Pty.Socket`).
    * `:session_opts` — spawn options (see `Pty.Session`) for a session this
      connection starts. May be a keyword list, or a 1-arity function of the
      `conn` for per-request values (a cwd from the path, say).
    * `:timeout` — WebSocket idle timeout, default `:infinity` (a terminal is
      idle whenever its human is thinking).
  """

  @behaviour Plug

  import Plug.Conn

  @status_bad_request 400
  @status_forbidden 403
  @status_upgrade_required 426

  @impl Plug
  def init(opts) do
    case Keyword.get(opts, :check_origin, true) do
      check when is_boolean(check) or is_list(check) ->
        opts

      other ->
        raise ArgumentError, ":check_origin must be a boolean or a list, got #{inspect(other)}"
    end
  end

  @impl Plug
  def call(conn, opts) do
    conn = fetch_query_params(conn)
    id = conn.query_params[Keyword.get(opts, :param, "s")]

    cond do
      not Pty.valid_id?(id) ->
        send_resp(conn, @status_bad_request, "invalid session id")

      not origin?(conn, Keyword.get(opts, :check_origin, true)) ->
        send_resp(conn, @status_forbidden, "origin not allowed")

      not upgrade?(conn) ->
        send_resp(conn, @status_upgrade_required, "expected websocket upgrade")

      true ->
        upgrade(conn, id, opts)
    end
  end

  defp upgrade(conn, id, opts) do
    arg = %{
      session_id: id,
      session_opts: session_opts(conn, opts),
      reattach: Map.has_key?(conn.query_params, "reattach")
    }

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

  defp origin?(conn, check) do
    conn
    |> get_req_header("origin")
    |> Enum.all?(fn origin ->
      if is_list(check),
        do: origin in check,
        else: !check or URI.parse(origin).host == URI.parse("//" <> conn.host).host
    end)
  end

  defp upgrade?(conn) do
    conn |> get_req_header("upgrade") |> Enum.any?(&(String.downcase(&1) =~ "websocket"))
  end
end
