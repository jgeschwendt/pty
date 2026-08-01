defmodule Pty.PlugTest do
  # Only the pre-upgrade branches are reachable through Plug.Test — the upgrade
  # itself needs a real HTTP server; Pty.SocketTest covers what it hands off to.
  use ExUnit.Case, async: true

  import Plug.Conn
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

  test "an upgrade request is handed to the adapter" do
    # Plug.Test's conn carries no host/sec-websocket-* headers, so WebSockAdapter's
    # own validation rejects it — which is proof enough that both gates passed and
    # the connection reached the adapter rather than a 400/426.
    assert_raise WebSockAdapter.UpgradeError, fn ->
      conn(:get, "/pty?s=abc")
      |> put_req_header("upgrade", "websocket")
      |> call()
    end
  end

  defp call(conn), do: Pty.Plug.call(conn, @opts)
end
