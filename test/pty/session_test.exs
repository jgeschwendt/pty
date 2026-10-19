defmodule Pty.SessionTest do
  # PTY_CMD and the global kill/kill_all touch shared state — never concurrent.
  use ExUnit.Case, async: false

  import Pty.TestHelpers

  alias Pty.Session

  setup do
    prev = for key <- ~w(PTY_CMD PTY_ARGS), do: {key, System.get_env(key)}
    on_exit(fn -> for {key, val} <- prev, do: restore_env(key, val) end)
  end

  test "new_id/0 returns unique, 12-char, url-safe ids" do
    ids = for _ <- 1..100, do: Session.new_id()

    assert Enum.all?(ids, &(&1 =~ ~r/\A[A-Za-z0-9_-]{12}\z/))
    assert length(Enum.uniq(ids)) == length(ids)
  end

  test "ensure/1 starts and registers a session; same id is idempotent, different id is distinct" do
    {id, pid} = start_session()
    assert {:ok, ^pid} = Session.ensure(id)
    {_, other} = start_session()
    assert other != pid
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
        start_sh_session(opts)
        assert recv_until_marker("resolved") =~ "resolved"
      end

      # Resolved in the caller, outside the one supervisor every start shares:
      # neither a refusal nor a live id (nor a hung mount) waits on it.
      {id, pid} = start_session()
      :sys.suspend(Pty.SessionSupervisor)
      on_exit(fn -> :sys.resume(Pty.SessionSupervisor) end)
      assert {:ok, ^pid} = Session.ensure(id)

      assert {:error, {:spawn_failed, :enoent}} =
               Session.ensure(Session.new_id(), command: "probe")

      assert {:error, {:spawn_failed, :enoent}} =
               Session.ensure(Session.new_id(), command: "cat", cwd: Path.join(dir, "gone"))
    end

    test "PTY_ARGS splits on spaces" do
      System.put_env("PTY_ARGS", "-u  -n")
      {_id, pid} = start_session()

      assert Session.info(pid).command == "cat -u -n"
    end
  end

  describe "subscribers" do
    test "a re-attach keeps one monitor, a name is refused, strays are harmless, the dead dropped" do
      {_id, pid} = start_session()
      sub = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, _} = Session.attach(pid, sub)
      {:ok, _} = Session.attach(pid, sub)
      assert Process.info(pid, :monitors) == {:monitors, [process: sub]}
      # apply/3: the call is ill-typed on purpose, which the compiler would flag.
      assert_raise FunctionClauseError, fn -> apply(Session, :attach, [pid, :a_name]) end

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
      {_id, pid} = start_session()
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

    test "one past :max_lag is held off the feed with a single {:pty_lagged}, bounded; a reattach resumes; the rest never lag" do
      pid =
        start_sh_session(
          args: ["-c", "for i in $(seq 20); do echo $i; sleep 0.01; done; echo done; exec cat"],
          max_lag: 3
        )

      task = Task.async(fn -> recv_until_marker("done") end)
      {:ok, _} = Session.attach(pid, task.pid)
      assert Task.await(task) =~ "done"
      # Still a monitored subscriber, counted: only off the feed.
      poll_until(fn -> Process.info(pid, :monitors) == {:monitors, [process: self()]} end)
      assert Session.info(pid).subscribers == 1

      # The stalled mailbox stops at max_lag + 1 chunks and the one notice.
      for _ <- 0..3, do: assert_received({:pty_data, _})
      assert_received {:pty_lagged}
      refute_received _

      {:ok, _} = Session.attach(pid, self())
      assert Process.info(pid, :monitors) == {:monitors, [process: self()]}
      Session.input(pid, "back\n")
      recv_until_marker("back")
    end

    test "only a live local subscriber is measured: a dead or remote one is sent to as before" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, _, _, _}
      # Process.info/2 raises on a pid of another node.
      remote =
        self()
        |> :erlang.term_to_binary()
        |> String.replace("#{node()}", "remote@nohost")
        |> :erlang.binary_to_term()

      subs = Map.new([self(), dead, remote], &{&1, make_ref()})
      state = %{os_pid: 1, subs: subs, buffer: :queue.new(), buffer_bytes: 0, cap: 0, max_lag: -1}

      assert {:noreply, %{subs: kept}} = Session.handle_info({:stdout, 1, "x"}, state)
      assert kept == %{subs | self() => {:lagged, subs[self()]}}
      assert_received {:pty_lagged}
      # A detach demonitors a lagged one too.
      assert Session.handle_cast({:detach, self()}, %{state | subs: kept}) ==
               {:noreply, %{state | subs: Map.delete(subs, self())}}
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

    # printenv, not ${TERM}: sh sets an unexported TERM=dumb when none is set.
    test "a false value unsets TERM" do
      assert echo(start_sh_session(env: %{"TERM" => false}), "term=$(printenv TERM || echo none)") =~
               "term=none"
    end
  end

  test "list/0 + resize/3 report the documented keys and default dims, oldest first, then the resized dims" do
    {id, pid} = start_session()
    assert %{id: ^id, cols: 80, rows: 24} = s = find_session(id)
    assert is_integer(s.started)

    assert Enum.sort(Map.keys(s)) ==
             [:buffer_bytes, :cols, :command, :id, :rows, :started, :subscribers]

    # All within one `started` second: the order is the start order, not ETS's.
    ids = [id | for(_ <- 1..9, do: elem(start_session(), 0))]
    assert ids == for(%{id: i} <- Session.list(), i in ids, do: i)

    # Casts then a call from one process arrive in order: no polling.
    Session.resize(pid, 80, 24)
    Session.resize(pid, 100, 40)
    assert %{cols: 100, rows: 40} = Session.info(pid)
  end

  test "kill/1 reaps a live id and errors on an unknown one; kill_all/0 reaps and counts" do
    {id, _pid} = ready(start_session())
    # Held, the registry cannot drop the dead session's keys itself: only terminate/2 can.
    parts = for {_, part, _, _} <- Supervisor.which_children(Pty.SessionRegistry), do: part
    Enum.each(parts, &:sys.suspend/1)

    assert Session.kill(id) == :ok
    assert Session.kill(id) == {:error, :not_found}
    Enum.each(parts, &:sys.resume/1)
    refute find_session(id)
    assert Session.whereis(id) == :error
    assert Session.kill("does-not-exist") == {:error, :not_found}

    ready(start_session())
    ready(start_session())

    # kill_all is global; the suite is async: false so nothing else is live.
    assert Session.kill_all() >= 2
    assert Session.list() == []
  end

  describe "lifecycle" do
    test "a child exit reaches subscribers with its code, and ends the session" do
      for {line, code} <- [{"exit", 0}, {"exit 3", 3}, {"kill -KILL $$", 137}] do
        pid = start_sh_session([])
        ref = Process.monitor(pid)

        Session.input(pid, line <> "\n")

        assert_receive {:pty_exit, ^code}
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
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

    test "a child deaf to HUP and TERM is killed with its process group, still a 129; its id is free at once" do
      pid = start_sh_session(args: ["-c", "trap '' HUP TERM; sleep 30 & echo bg=$! .; wait"])
      [_, bg] = Regex.run(~r/bg=(\d+) \./, recv_until_marker(" ."))
      %{id: id, os_pid: os_pid} = :sys.get_state(pid)

      reap = Task.async(fn -> Session.kill(pid) end)
      # Mid-hangup, a start gets a fresh session rather than the dying one.
      poll_until(fn -> Session.whereis(id) == :error end)
      assert {:ok, fresh} = Session.ensure(id)
      assert fresh != pid
      assert Task.await(reap) == :ok
      assert_receive {:pty_exit, 129}
      refute alive?(os_pid)
      # The orphaned sleep is reaped by launchd, not erlexec: a zombie answers kill -0.
      poll_until(fn -> not alive?(String.to_integer(bg)) end)
    end

    test "a kill by id during another reap's hangup returns once the child is gone; its flood is bounded too" do
      pid =
        start_sh_session(
          args: [
            "-c",
            "trap '' TERM; trap 'seq 100000' HUP; echo up; while :; do sleep 0.1; done"
          ],
          max_lag: 3
        )

      recv_until_marker("up")
      %{id: id, os_pid: os_pid} = :sys.get_state(pid)

      reap = Task.async(fn -> Session.kill(pid) end)
      poll_until(fn -> Session.whereis(id) == :error end)
      assert Session.kill(id) == :ok
      refute alive?(os_pid)
      assert Task.await(reap) == :ok
      # The hangup relays through the same max_lag; a lagged subscriber still hears the end.
      for _ <- 0..3, do: assert_received({:pty_data, _})
      assert_received {:pty_lagged}
      assert_received {:pty_exit, 129}
      refute_received _
    end

    test "a crashed session still tells subscribers and takes its child along" do
      {_id, pid} = ready(start_session())
      os_pid = :sys.get_state(pid).os_pid

      ExUnit.CaptureLog.capture_log(fn -> catch_exit(GenServer.call(pid, :bogus)) end)

      assert_receive {:pty_exit, 129}
      refute alive?(os_pid)
    end

    test "a session killed outright still takes its child along" do
      {_id, pid} = ready(start_session())
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

  test "buffer bound: a chunk over the cap keeps its tail; overflow evicts whole chunks oldest first" do
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

  defp alive?(os_pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true))

  defp start_session(cmd \\ "cat", opts \\ []) do
    id = Session.new_id()
    System.put_env("PTY_CMD", cmd)
    on_exit(fn -> drop(id) end)
    {:ok, pid} = Session.ensure(id, opts)
    {id, pid}
  end

  defp start_sh_session(opts) do
    {_id, pid} = start_session("sh", opts)
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
