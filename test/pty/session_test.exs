defmodule Pty.SessionTest do
  # PTY_CMD and the global kill/kill_all touch shared state — never concurrent.
  use ExUnit.Case, async: false

  import Pty.TestHelpers

  alias Pty.Session

  @recv_deadline_ms 2_000

  setup do
    prev = for key <- ~w(PTY_CMD PTY_ARGS), do: {key, System.get_env(key)}
    on_exit(fn -> for {key, val} <- prev, do: restore_env(key, val) end)
  end

  describe "new_id/0" do
    test "returns unique, 12-char, url-safe ids" do
      ids = for _ <- 1..100, do: Session.new_id()

      assert Enum.all?(ids, &(&1 =~ ~r/\A[A-Za-z0-9_-]{12}\z/))
      assert length(Enum.uniq(ids)) == length(ids)
    end
  end

  describe "ensure/1" do
    test "starts and registers a session; same id is idempotent, different id is distinct" do
      {id, pid} = start_cat_session()
      assert {:ok, ^pid} = Session.ensure(id)
      {_, other} = start_cat_session()
      assert other != pid
    end
  end

  describe "executable resolution" do
    @describetag :tmp_dir

    test "a path resolves against :cwd, a bare name against the :env PATH", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "probe"), "#!/bin/sh\necho resolved; exec cat\n")
      File.chmod!(Path.join(dir, "probe"), 0o755)

      for opts <- [
            [command: "./probe", cwd: dir],
            [command: "probe", env: %{"PATH" => dir <> ":/bin"}]
          ] do
        id = Session.new_id()
        on_exit(fn -> drop(id) end)
        assert {:ok, pid} = Session.ensure(id, opts)
        {:ok, _} = Session.attach(pid, self())
        assert recv_until_marker("resolved") =~ "resolved"
      end

      assert {:error, {:spawn_failed, :enoent}} =
               Session.ensure(Session.new_id(), command: "probe")

      assert {:error, {:spawn_failed, :enoent}} =
               Session.ensure(Session.new_id(), command: "cat", cwd: Path.join(dir, "gone"))
    end

    test "PTY_ARGS splits on spaces" do
      System.put_env("PTY_ARGS", "-u  -n")
      {_id, pid} = start_cat_session()

      assert Session.info(pid).command == "cat -u -n"
    end
  end

  describe "subscribers" do
    test "a stray detach and a stray message are harmless; a dead subscriber is dropped" do
      {_id, pid} = start_cat_session()
      sub = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, _} = Session.attach(pid, sub)

      Session.detach(pid, self())
      send(pid, :stray)
      assert Session.info(pid).subscribers == 1

      Process.exit(sub, :kill)
      poll_until(fn -> Session.info(pid).subscribers == 0 end)

      Process.exit(pid, :kill)
      refute Session.info(pid)
      assert Session.kill(pid) == {:error, :not_found}
    end

    test "output buffers while detached, replays on attach, then reaches every subscriber" do
      {_id, pid} = start_cat_session()
      marker = unique_marker()
      Session.input(pid, marker <> "\n")
      poll_until(fn -> Session.info(pid).buffer_bytes >= byte_size(marker) end)

      assert {:ok, buffer} = Session.attach(pid, self())
      assert buffer =~ marker

      live = unique_marker()
      task = Task.async(fn -> recv_until_marker(live) end)
      {:ok, _} = Session.attach(pid, task.pid)
      Session.input(pid, live <> "\n")

      assert recv_until_marker(live) =~ live
      assert Task.await(task) =~ live
    end
  end

  describe "spawn env" do
    test ":env reaches the child, and a caller entry overrides the default TERM" do
      marker = unique_marker()
      pid = start_sh_session(env: %{"PTY_PROBE" => marker, "TERM" => "vt100"})

      assert echo(pid, ~s|probe=$PTY_PROBE term=$TERM|) =~ "probe=#{marker} term=vt100"
    end

    test "TERM defaults to xterm-256color" do
      assert echo(start_sh_session([]), ~s|term=${TERM-none}|) =~ "term=xterm-256color"
    end

    # The `false` → unset path is deliberately untested: it only bites on a variable
    # the child INHERITED, and the inherited set is erlexec's boot snapshot (see the
    # Session moduledoc), which a test running after :pty started cannot add to.
    test "a false value leaves TERM inherited rather than unset" do
      refute echo(start_sh_session(env: %{"TERM" => false}), ~s|term=${TERM-none}|) =~
               "term=xterm-256color"
    end
  end

  describe "list/0 + resize/3" do
    test "reports the documented keys and default dims, then the resized dims" do
      {id, pid} = start_cat_session()
      s = find_session(id)

      assert Enum.sort(Map.keys(s)) ==
               [:buffer_bytes, :cols, :command, :id, :rows, :started, :subscribers]

      assert %{id: ^id, cols: 80, rows: 24} = s

      # Casts then a call from one process arrive in order: no polling.
      Session.resize(pid, 80, 24)
      Session.resize(pid, 100, 40)
      assert %{cols: 100, rows: 40} = Session.info(pid)
    end
  end

  describe "kill/1 + kill_all/0" do
    test "kill reaps a live id and errors on an unknown one; kill_all reaps and counts" do
      {id, _pid} = start_cat_session()

      assert Session.kill(id) == :ok
      refute find_session(id)
      assert Session.kill("does-not-exist") == {:error, :not_found}

      start_cat_session()
      start_cat_session()

      # kill_all is global; the suite is async: false so nothing else is live.
      assert Session.kill_all() >= 2
      assert Session.list() == []
    end
  end

  describe "lifecycle" do
    test "a child exit reaches subscribers with its code, and ends the session" do
      for {line, code} <- [{"exit", 0}, {"exit 3", 3}, {"kill -KILL $$", 137}] do
        pid = start_sh_session([])
        ref = Process.monitor(pid)

        Session.input(pid, line <> "\n")

        assert_receive {:pty_exit, ^code}, @recv_deadline_ms
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @recv_deadline_ms
      end
    end

    test "a reap hangs the child up, relays its last words, and returns once it is gone" do
      pid =
        start_sh_session(
          args: ["-c", "trap 'echo bye; exit' HUP; echo up; while :; do sleep 0.05; done"]
        )

      recv_until_marker("up")
      os_pid = :sys.get_state(pid).os_pid

      assert Session.kill(pid) == :ok
      assert recv_until_marker("bye") =~ "bye"
      assert_receive {:pty_exit, 129}
      refute alive?(os_pid)
    end

    test "a child deaf to HUP and TERM is killed with its process group, still a 129" do
      pid = start_sh_session(args: ["-c", "trap '' HUP TERM; sleep 30 & echo bg=$! .; wait"])
      [_, bg] = Regex.run(~r/bg=(\d+) \./, recv_until_marker(" ."))
      os_pid = :sys.get_state(pid).os_pid

      assert Session.kill(pid) == :ok
      assert_receive {:pty_exit, 129}
      refute alive?(os_pid)
      # The orphaned sleep is reaped by launchd, not erlexec: a zombie answers kill -0.
      poll_until(fn -> not alive?(String.to_integer(bg)) end)
    end

    test "a crashed session still tells subscribers and takes its child along" do
      {_id, pid} = start_cat_session()
      {:ok, _} = Session.attach(pid, self())
      os_pid = :sys.get_state(pid).os_pid

      ExUnit.CaptureLog.capture_log(fn -> catch_exit(GenServer.call(pid, :bogus)) end)

      assert_receive {:pty_exit, 129}, @recv_deadline_ms
      refute alive?(os_pid)
    end

    test "a session killed outright still takes its child along" do
      {_id, pid} = start_cat_session()
      os_pid = :sys.get_state(pid).os_pid

      Process.exit(pid, :kill)

      poll_until(fn -> not alive?(os_pid) end)
    end

    test "erlexec going down ends the session with code 1" do
      state = %{exec_pid: self(), exit: nil}

      assert {:stop, :normal, %{exit: 1}} =
               Session.handle_info({:EXIT, self(), :port_closed}, state)
    end
  end

  describe "buffer bound" do
    test "a chunk over the cap keeps its tail; overflow evicts whole chunks oldest first" do
      # Driven through the callbacks: no pty needed to exercise the deque.
      tail = String.duplicate("t", 100)
      chunk = String.duplicate("x", 900) <> tail
      state = %{os_pid: 1, subs: %{}, buffer: :queue.new(), buffer_bytes: 0, cap: 100}
      {:noreply, kept} = Session.handle_info({:stdout, 1, chunk}, state)
      {:noreply, off} = Session.handle_info({:stdout, 1, chunk}, %{state | cap: 0})

      assert {:reply, {:ok, ^tail}, %{buffer_bytes: 100}} =
               Session.handle_call({:attach, self()}, nil, kept)

      # The tail is a copy, not a slice pinning the chunk; cap 0 queues nothing.
      assert [kept_tail] = :queue.to_list(kept.buffer)
      assert :binary.referenced_byte_size(kept_tail) == 100
      assert :queue.is_empty(off.buffer)

      # Replay is chunk-aligned: one byte over the cap drops the whole 100-byte tail.
      assert {:noreply, %{buffer: q, buffer_bytes: 1}} =
               Session.handle_info({:stdout, 1, "y"}, kept)

      assert :queue.to_list(q) == ["y"]
    end
  end

  defp alive?(os_pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true))

  defp start_cat_session do
    id = Session.new_id()
    System.put_env("PTY_CMD", "cat")
    on_exit(fn -> drop(id) end)
    {:ok, pid} = Session.ensure(id)
    {id, pid}
  end

  defp start_sh_session(opts) do
    id = Session.new_id()
    System.put_env("PTY_CMD", "sh")
    on_exit(fn -> drop(id) end)

    {:ok, pid} = Session.ensure(id, opts)
    {:ok, _buffer} = Session.attach(pid, self())
    pid
  end

  # A pty shell echoes the typed line back before running it, so both the command
  # and its output land in the collected bytes. The appended `$((21+21))` is the
  # discriminator: `sum=42` can only appear in the OUTPUT, never in the echo.
  defp echo(pid, expression) do
    Session.input(pid, ~s|echo "#{expression} sum=$((21+21))"\n|)
    recv_until_marker("sum=42")
  end
end
