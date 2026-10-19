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
  is not a valid WebSocket upgrade (RFC 6455), and otherwise hands off to `Pty.Socket`.

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
      `reattach` parameter (any value), which `pty.js` sends on every reconnect
      after its first attach, makes the connection attach-only (see `Pty.Socket`).
    * `:ping_interval` — milliseconds between the WebSocket pings `Pty.Socket`
      sends, a positive integer (default `30_000`; see its init argument).
    * `:session_opts` — spawn options (see `Pty.Session`) for a session this
      connection starts. May be a keyword list, or a 1-arity function of the
      `conn` for per-request values (a cwd from the path, say).
    * `:timeout` — WebSocket idle timeout, default `90_000` ms; keep it above
      `:ping_interval`. A terminal is idle whenever its human is thinking, so
      idleness alone never closes it: the browser answers every ping by
      itself, and only a client that stopped answering — gone without a FIN
      (lid shut, network dropped) — times out, freeing its subscription.
  """

  @behaviour Plug

  import Plug.Conn

  @status_bad_request 400
  @status_forbidden 403
  @status_upgrade_required 426

  @impl Plug
  def init(opts) do
    check = Keyword.get(opts, :check_origin, true)
    ping = Keyword.get(opts, :ping_interval, 30_000)

    is_boolean(check) or is_list(check) or
      raise ArgumentError, ":check_origin must be a boolean or a list, got #{inspect(check)}"

    (is_integer(ping) and ping > 0) or
      raise ArgumentError, ":ping_interval must be a positive integer, got #{inspect(ping)}"

    opts
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

      # RFC 6455 checked here, not left to WebSockAdapter.upgrade/4, whose
      # raise would be a 500 and a stack trace per bad request.
      WebSockAdapter.UpgradeValidation.validate_upgrade(conn) != :ok ->
        send_resp(conn, @status_upgrade_required, "expected websocket upgrade")

      true ->
        upgrade(conn, id, opts)
    end
  end

  defp upgrade(conn, id, opts) do
    arg =
      Map.merge(Map.new(Keyword.take(opts, [:ping_interval])), %{
        session_id: id,
        session_opts: session_opts(conn, opts),
        reattach: Map.has_key?(conn.query_params, "reattach")
      })

    conn
    |> WebSockAdapter.upgrade(Pty.Socket, arg, timeout: Keyword.get(opts, :timeout, 90_000))
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
end
