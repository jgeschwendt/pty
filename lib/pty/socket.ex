defmodule Pty.Socket do
  @moduledoc """
  A `WebSock` handler that bridges one WebSocket to a `Pty.Session`.

  This is the drop-in transport: any Plug, Phoenix, Bandit or Cowboy host can
  upgrade a connection into it — directly, or through `Pty.Plug` — and get a
  working terminal without touching the process model. It owns no PTY. On
  connect it ensures the session for its id exists (or, reattaching, only finds
  it), attaches, and pushes the scrollback as the first frame — empty or not, so
  the client knows it is attached. On disconnect the handler simply dies — the
  session drops the subscription and the PTY keeps running for a later reattach.

  ## Init argument

  A map of:

    * `:session_id` (required) — which session to attach to.
    * `:session_opts` — spawn options (see `Pty.Session`), applied only when
      this connection is what starts the session.
    * `:reattach` — when true, never start a session: a client coming back to
      one it already had must not get a fresh shell under the old id.
    * `:ping_interval` — milliseconds between WebSocket pings, a positive
      integer (default `30_000`; anything else closes `1011`, logged). Only a
      received frame resets the server's idle timeout, so the client's
      automatic pongs keep a live socket open; set the upgrade's `:timeout`
      above this, and a client gone half-open is closed by it.

  ## Wire protocol

    * client → server: JSON text frames, decoded by `Pty.Client`.
    * server → client: binary frames of raw PTY output, fed straight to xterm.js;
      the first is the scrollback.
    * close `4000`: the session ended (its child exited or it was reaped).
      Private, not `1000`: Bandit closes `1000` on its own shutdown, which a
      client must take as transport loss, not as the end.
    * close `4404`: no session to attach — a reattach found none, or the one
      found ended as it attached.
    * close `4422`: refused — an id `Pty.valid_id?/1` rejects, reattaching or
      not, or a spawn whose `:command` or `:cwd` is not found or whose option
      is rejected (e.g. a bad `:cols`, or a `:max_lag` that is no positive
      integer). Permanent.
    * close `1011`: any other start failure. Retried: pty cannot tell a passing
      failure (resources) from a fault (an option that crashes init); the
      host's logs show which.
    * close `1013`: this subscriber fell over `:max_lag` messages behind and
      was taken off the feed (see `Pty.Session`). Retried: the client reattaches and gets
      the scrollback.

  The browser half lives in `priv/static/pty.js`.
  """

  @behaviour WebSock
  require Logger

  alias Pty.Client
  alias Pty.Session

  @ws_close_ended 4000
  @ws_close_internal_error 1011
  @ws_close_lagged 1013
  @ws_close_not_found 4404
  @ws_close_refused 4422

  @impl true
  def init(%{session_id: id} = arg) do
    ping = Map.get(arg, :ping_interval, 30_000)

    # Checked before either path: a reattach never reaches ensure/2's own check.
    # The interval too, so a bad one never spawns a session first — :timer takes
    # a 0, and floods the socket with pings.
    with true <- Pty.valid_id?(id) || {:error, :invalid_id},
         true <- (is_integer(ping) and ping > 0) || {:error, {:invalid_ping_interval, ping}},
         {:ok, _} <- :timer.send_interval(ping, :ping),
         {:ok, session} <- find(id, arg),
         {:ok, buffer} <- Pty.attach(session) do
      # Monitored, so even a session killed outright closes the socket.
      Process.monitor(session)
      {:push, {:binary, buffer}, %{session: session}}
    else
      # Never there, or ending as we attached: either way, gone.
      not_found when not_found in [:error, {:error, :not_found}] ->
        close(@ws_close_not_found, "session not found")

      # Only the deterministic refusals; a fixed reason fits RFC 6455's 123
      # bytes and leaks no host config.
      {:error, :invalid_id} ->
        close(@ws_close_refused, "invalid session id")

      {:error, {:spawn_failed, reason}}
      when reason == :enoent or elem(reason, 0) == :invalid_option ->
        close(@ws_close_refused, "spawn refused")

      # Neither the supervisor nor a failed init/1 logs; this line is how the
      # host tells a passing failure from a fault.
      error ->
        Logger.error("session #{id} unavailable: #{inspect(error)}")
        close(@ws_close_internal_error, "session unavailable")
    end
  end

  defp find(id, %{reattach: true}), do: Session.whereis(id)
  defp find(id, arg), do: Session.ensure(id, Map.get(arg, :session_opts, []))

  defp close(code, reason), do: {:stop, :normal, {code, reason}, %{session: nil}}

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    Client.handle(state.session, text)
    {:ok, state}
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info({:pty_data, data}, state) do
    {:push, {:binary, data}, state}
  end

  def handle_info({:pty_exit, code}, state) do
    {:stop, :normal, {@ws_close_ended, "process exited (#{code})"}, state}
  end

  def handle_info({:pty_lagged}, state) do
    {:stop, :normal, {@ws_close_lagged, "lagged"}, state}
  end

  def handle_info({:DOWN, _ref, :process, session, _reason}, %{session: session} = state) do
    {:stop, :normal, {@ws_close_ended, "session ended"}, state}
  end

  def handle_info(:ping, state), do: {:push, {:ping, ""}, state}

  def handle_info(_msg, state), do: {:ok, state}
end
