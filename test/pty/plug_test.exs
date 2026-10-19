defmodule Pty.PlugTest do
  # Only the pre-upgrade branches are reachable through Plug.Test — the upgrade
  # itself needs a real HTTP server; Pty.SocketTest covers what it hands off to.
  use ExUnit.Case, async: true

  import Plug.Test

  @opts Pty.Plug.init([])

  @oversize_id_len 65
  @status_bad_request 400
  @status_upgrade_required 426

  test "a missing session id is a 400" do
    conn = call(conn(:get, "/pty"))

    assert conn.status == @status_bad_request
    assert conn.resp_body =~ "invalid session id"
  end

  test "a malformed session id is a 400" do
    # %2F%0A decodes to "/\n" (path + control chars); the 65-char id overruns the
    # length cap. Both are rejected before any upgrade is attempted.
    for s <- ["%2F%0A", String.duplicate("a", @oversize_id_len)] do
      assert call(conn(:get, "/pty?s=#{s}")).status == @status_bad_request
    end
  end

  test "a valid id without an upgrade header is a 426" do
    conn = call(conn(:get, "/pty?s=abc"))

    assert conn.status == @status_upgrade_required
    assert conn.resp_body =~ "expected websocket upgrade"
  end

  test ":param reads the id from another query parameter" do
    opts = Pty.Plug.init(param: "session")

    assert Pty.Plug.call(conn(:get, "/pty?session=abc"), opts).status ==
             @status_upgrade_required

    assert Pty.Plug.call(conn(:get, "/pty?s=abc"), opts).status == @status_bad_request
  end

  test "an upgrade request is handed to Pty.Socket, reattach flag and all" do
    # :session_opts as a list, or a 1-arity fun resolved against the conn before
    # the hand-off; a finite idle timeout by default, above the ping interval.
    for {query, reattach, opts, extra, timeout} <- [
          {"s=abc", false, [session_opts: [cwd: "abc"]], %{}, 90_000},
          {"s=abc&reattach=1", true,
           [session_opts: &[cwd: &1.query_params["s"]], ping_interval: 5, timeout: 20],
           %{ping_interval: 5}, 20}
        ] do
      conn =
        conn(:get, "/pty?" <> query)
        |> Map.put(:req_headers, [
          {"host", "www.example.com"},
          {"connection", "Upgrade"},
          {"upgrade", "websocket"},
          {"sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="},
          {"sec-websocket-version", "13"}
        ])
        |> Pty.Plug.call(Pty.Plug.init(opts))

      assert [{:websocket, {Pty.Socket, arg, upgrade_opts}}] = Plug.Test.sent_upgrades(conn)
      assert upgrade_opts[:timeout] == timeout

      assert arg ==
               Map.merge(extra, %{
                 session_id: "abc",
                 session_opts: [cwd: "abc"],
                 reattach: reattach
               })
    end
  end

  test "a cross-origin upgrade is a 403 unless :check_origin admits it" do
    # A WebSocket handshake escapes CORS: without this gate any page the user
    # visits could open a shell on a loopback-only host (CSWSH).
    upgrade = fn host, origins, opts ->
      conn = conn(:get, "/pty?s=abc")
      origins = Enum.map(origins, &{"origin", &1})
      conn = %{conn | host: host, req_headers: [{"upgrade", "websocket"} | origins]}
      Pty.Plug.call(conn, Pty.Plug.init(opts))
    end

    for {host, origins, opts} <- [
          {"localhost", ["https://evil.example"], []},
          {"localhost", ["null"], []},
          {"localhost", ["http://localhost", "https://evil.example"], []},
          {"localhost", ["http://localhost"], check_origin: ["https://app.example"]}
        ] do
      assert %{status: 403, resp_body: "origin not allowed"} = upgrade.(host, origins, opts)
    end

    for {host, origins, opts} <- [
          {"localhost", ["http://localhost:4000"], []},
          {"[::1]", ["http://[::1]:4000"], []},
          {"localhost", ["https://evil.example"], check_origin: false},
          {"localhost", ["https://app.example"], check_origin: ["https://app.example"]}
        ] do
      # Past the gate, a bare `upgrade: websocket` fails RFC 6455 (no key,
      # version or `connection: upgrade`): a 426, not a raise and a 500.
      assert %{status: @status_upgrade_required} = upgrade.(host, origins, opts)
    end

    assert_raise ArgumentError, fn -> Pty.Plug.init(check_origin: nil) end
  end

  defp call(conn), do: Pty.Plug.call(conn, @opts)
end
