defmodule Pty.SocketTest do
  # Drives WebSock callbacks directly; touches PTY_CMD and real sessions.
  use ExUnit.Case, async: false

  import Pty.TestHelpers

  alias Pty.Session
  alias Pty.Socket

  @default_cols 80
  @default_rows 24
  @fractional_dim 90.5
  @oversize_dim 2_000
  @resize_cols 90
  @resize_rows 30
  @ws_close_ended 4000
  @ws_close_internal_error 1011
  @ws_close_refused 4422

  setup do
    prev_cmd = System.get_env("PTY_CMD")
    System.put_env("PTY_CMD", "cat")
    on_exit(fn -> restore_env("PTY_CMD", prev_cmd) end)
    :ok
  end

  describe "init/1" do
    test "pushes the scrollback first even when it is empty — the attach signal" do
      id = fresh_id()
      assert {:push, {:binary, ""}, state} = Socket.init(%{session_id: id})
      assert is_pid(state.session)
    end

    test "a reattach attaches to a live session but never starts one" do
      id = fresh_id()

      assert {:stop, :normal, {4404, _}, %{session: nil}} =
               Socket.init(%{session_id: id, reattach: true})

      assert Pty.lookup(id) == :error

      {:ok, pid} = Session.ensure(id)
      assert {:push, _, %{session: ^pid}} = Socket.init(%{session_id: id, reattach: true})
    end

    test "replays existing scrollback as a binary push" do
      id = fresh_id()
      {:ok, pid} = Session.ensure(id)
      {:ok, _} = Session.attach(pid, self())

      marker = unique_marker()
      Session.input(pid, marker <> "\n")
      _ = recv_until_marker(marker)

      assert {:push, {:binary, buffer}, _state} = Socket.init(%{session_id: id})
      assert String.contains?(buffer, marker)
    end

    test "a refused spawn or id closes 4422 — permanent, the client stops" do
      # A missing binary (:enoent), and an option erlexec rejects (:invalid_option).
      for opts <- [[command: "/nonexistent/definitely-not-a-binary"], [cols: "x"]] do
        {result, _log} =
          ExUnit.CaptureLog.with_log(fn ->
            Socket.init(%{session_id: fresh_id(), session_opts: opts})
          end)

        assert {:stop, :normal, {@ws_close_refused, "spawn refused"}, %{session: nil}} = result
      end

      # A directly-mounted socket has no Pty.Plug in front to 400 a bad id.
      assert {:stop, :normal, {@ws_close_refused, "invalid session id"}, %{session: nil}} =
               Socket.init(%{session_id: "nl\n"})
    end

    test "any other start failure closes 1011 and the client retries" do
      # An argument that is no string crashes init/1 past the spawn check.
      {result, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          Socket.init(%{session_id: fresh_id(), session_opts: [args: [1]]})
        end)

      assert {:stop, :normal, {@ws_close_internal_error, "session unavailable"}, %{session: nil}} =
               result
    end

    test ":session_opts configure the session this connection starts" do
      id = fresh_id()
      assert {:push, _, _} = Socket.init(%{session_id: id, session_opts: [args: ["-u"]]})

      # Options beat the PTY_CMD env this suite sets, and reach the spawn.
      assert Pty.info(id).command == "cat -u"
    end
  end

  describe "handle_in/2" do
    test "an input frame reaches the pty and echoes back to the subscriber" do
      id = fresh_id()
      # init here makes THIS test process the attached subscriber.
      state = init_socket(id)

      marker = unique_marker()
      frame = {~s|{"t":"i","d":"#{marker}\\n"}|, [opcode: :text]}

      assert {:ok, ^state} = Socket.handle_in(frame, state)
      assert recv_until_marker(marker) =~ marker
    end

    test "a resize frame changes the session dimensions" do
      id = fresh_id()
      state = init_socket(id)

      frame = {~s|{"t":"r","cols":#{@resize_cols},"rows":#{@resize_rows}}|, [opcode: :text]}
      assert {:ok, ^state} = Socket.handle_in(frame, state)

      poll_until(fn ->
        s = find_session(id)
        s && s.cols == @resize_cols && s.rows == @resize_rows
      end)
    end

    test "out-of-range, zero, and non-integer resize dimensions are ignored" do
      id = fresh_id()
      state = init_socket(id)

      for {cols, rows} <- [
            {@oversize_dim, @resize_rows},
            {0, @resize_rows},
            {@fractional_dim, @resize_rows},
            {@resize_cols, @oversize_dim},
            {@resize_cols, 0},
            {@resize_cols, @fractional_dim}
          ] do
        frame = {~s|{"t":"r","cols":#{cols},"rows":#{rows}}|, [opcode: :text]}
        assert {:ok, ^state} = Socket.handle_in(frame, state)
      end

      # The synchronous :info call serializes after any wrongly-emitted resize cast.
      s = find_session(id)
      assert s.cols == @default_cols
      assert s.rows == @default_rows
    end

    test "invalid json, unknown types, and non-text frames are ignored" do
      id = fresh_id()
      state = init_socket(id)

      assert {:ok, ^state} = Socket.handle_in({"not json", [opcode: :text]}, state)
      assert {:ok, ^state} = Socket.handle_in({~s|{"t":"x"}|, [opcode: :text]}, state)
      assert {:ok, ^state} = Socket.handle_in({<<0, 1, 2>>, [opcode: :binary]}, state)
      assert {:ok, ^state} = Socket.handle_in({~s|{"t":"i","d":123}|, [opcode: :text]}, state)
    end
  end

  describe "handle_info/2" do
    test "pty data is pushed as a binary frame" do
      state = %{session: self()}
      assert {:push, {:binary, "abc"}, ^state} = Socket.handle_info({:pty_data, "abc"}, state)
    end

    test "pty exit stops with a normal websocket close" do
      state = %{session: self()}

      assert {:stop, :normal, {@ws_close_ended, reason}, ^state} =
               Socket.handle_info({:pty_exit, 0}, state)

      assert is_binary(reason)
    end

    test "a session that dies without a word closes the socket" do
      state = init_socket(fresh_id())
      Process.exit(state.session, :kill)

      assert_receive {:DOWN, _, :process, _, _} = down, 1_000

      assert {:stop, :normal, {@ws_close_ended, "session ended"}, ^state} =
               Socket.handle_info(down, state)
    end

    test "unrelated messages are ignored" do
      state = %{session: self()}
      assert {:ok, ^state} = Socket.handle_info(:whatever, state)
    end
  end

  ## Helpers

  defp fresh_id do
    id = Session.new_id()
    on_exit(fn -> drop(id) end)
    id
  end

  defp init_socket(id) do
    {:push, _frame, state} = Socket.init(%{session_id: id})
    state
  end
end
