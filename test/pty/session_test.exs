defmodule Pty.SessionTest do
  # PTY_* and :pty app env, and the global kill_all, are shared state — never concurrent.
  use ExUnit.Case, async: false

  import Pty.TestHelpers

  alias Pty.Session

  @state %{buffer: :queue.new(), buffer_bytes: 0, cap: 0, max_lag: -1, os_pid: 1, subs: %{}}

  describe "executable resolution" do
    @describetag :tmp_dir

    test "a path resolves against :cwd, a bare name against the :env PATH", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "probe"), "#!/bin/sh\necho resolved; exec cat\n")
      File.chmod!(Path.join(dir, "probe"), 0o755)

      for opts <- [
            [command: "./probe", cwd: dir],
            [command: "probe", cwd: dir, env: %{"PATH" => ".:/bin"}]
          ] do
        start_sh_session(opts)
        recv_until_marker("resolved")
      end

      # Resolved in the caller, outside the one supervisor every start shares:
      # neither a refusal nor a live id (nor a hung mount) waits on it.
      {id, pid} = start_session()
      :sys.suspend(Pty.SessionSupervisor)
      on_exit(fn -> :sys.resume(Pty.SessionSupervisor) end)
      assert {:ok, ^pid} = Session.ensure(id, command: "probe")

      assert {:error, {:spawn_failed, :enoent}} =
               Session.ensure(Session.new_id(), command: "probe")

      assert {:error, {:spawn_failed, :enoent}} =
               Session.ensure(Session.new_id(), command: "cat", cwd: Path.join(dir, "gone"))
    end
  end

  describe "subscribers" do
    test "subscriber bookkeeping: one monitor per pid, strays harmless, the dead dropped; killed outright, the child goes too" do
      {_id, pid} = start_session()
      sub = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, _} = Session.attach(pid, sub)
      Session.detach(pid, sub)
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

      os_pid = :sys.get_state(pid).os_pid
      Process.exit(pid, :kill)
      refute Session.info(pid)
      poll_until(fn -> not alive?(os_pid) end)
    end

    test "a subscriber past :max_lag gets one {:pty_lagged} and leaves the feed until it reattaches; a reader keeps up" do
      pid =
        start_sh_session(
          args: ["-c", "for i in $(seq 20); do echo $i; sleep 0.01; done; echo done; exec cat"],
          max_lag: 3
        )

      task = Task.async(fn -> recv_until_marker("done") end)
      {:ok, _} = Session.attach(pid, task.pid)
      Task.await(task)
      # Still a monitored subscriber, counted: only off the feed.
      poll_until(fn -> Process.info(pid, :monitors) == {:monitors, [process: self()]} end)
      assert Session.info(pid).subscribers == 1

      # The stalled mailbox stops at max_lag + 1 chunks and the one notice.
      for _ <- 0..3, do: assert_received({:pty_data, _})
      assert_received {:pty_lagged}
      refute_received _

      {:ok, _} = Session.attach(pid, self())
      Session.input(pid, "back\n")
      recv_until_marker("back")
    end

    test "only a live local subscriber is measured; a detach drops a lagged one" do
      {dead, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, _, _, _}
      # Process.info/2 raises on a pid of another node.
      remote =
        self()
        |> :erlang.term_to_binary()
        |> String.replace("#{node()}", "remote@nohost")
        |> :erlang.binary_to_term()

      subs = Map.new([self(), dead, remote], &{&1, make_ref()})
      state = %{@state | subs: subs}

      assert {:noreply, %{subs: kept}} = Session.handle_info({:stdout, 1, "x"}, state)
      assert kept == %{subs | self() => {:lagged, subs[self()]}}
      assert_received {:pty_lagged}

      assert Session.handle_cast({:detach, self()}, %{state | subs: kept}) ==
               {:noreply, %{state | subs: Map.delete(subs, self())}}
    end
  end

  # printenv, not ${TERM}: sh sets an unexported TERM=dumb when none is set.
  test ":env layers over the inherited env: TERM defaults, a caller entry overrides it, false unsets it; resize sets the size" do
    for {env, term} <- [
          {%{}, "xterm-256color"},
          {%{"TERM" => "vt100"}, "vt100"},
          {%{"TERM" => false}, "none"}
        ] do
      assert echo(
               start_sh_session(env: env),
               "term=$(printenv TERM || echo none) home=$HOME size=$(stty size)"
             ) =~ "term=#{term} home=#{System.get_env("HOME")} size=24 80"
    end

    pid = start_sh_session([])
    # 80x24 is unchanged: the winsz skip. Casts then a call arrive in order: no polling.
    Session.resize(pid, 80, 24)
    Session.resize(pid, 100, 40)
    assert %{cols: 100, rows: 40} = Session.info(pid)
    assert echo(pid, "size=$(stty size)") =~ "size=40 100"
  end

  test "spec resolution and metadata: PTY_ARGS split, app env, documented keys, start order" do
    System.put_env("PTY_ARGS", "-u  -n")
    on_exit(fn -> System.delete_env("PTY_ARGS") end)
    Application.put_env(:pty, :scrollback, 4)
    on_exit(fn -> Application.delete_env(:pty, :scrollback) end)
    {id, pid} = start_session()
    assert :sys.get_state(pid).cap == 4
    assert %{id: ^id, cols: 80, rows: 24, command: "cat -u -n"} = s = find_session(id)
    assert is_integer(s.started)

    assert Enum.sort(Map.keys(s)) ==
             [:buffer_bytes, :cols, :command, :id, :rows, :started, :subscribers]

    # All within one `started` second: the order is the start order, not ETS's.
    ids = [id | for(_ <- 1..9, do: elem(start_session(), 0))]
    assert Enum.all?(ids, &(&1 =~ ~r/\A[A-Za-z0-9_-]{12}\z/))
    assert ids == for(%{id: i} <- Session.list(), i in ids, do: i)
  end

  test "kill/1 reaps a live id, then is not found even while its keys linger; kill_all/0 reaps and counts" do
    {id, _pid} = ready(start_session())
    {_, doomed} = start_session()
    # Held, the registry cannot drop the dead session's keys itself: only terminate/2 can.
    parts = for {_, part, _, _} <- Supervisor.which_children(Pty.SessionRegistry), do: part
    Enum.each(parts, &:sys.suspend/1)
    Process.exit(doomed, :kill)

    assert Session.kill(id) == :ok
    assert Session.kill(id) == {:error, :not_found}
    assert Session.list() == []
    Enum.each(parts, &:sys.resume/1)

    for _ <- 1..2, do: ready(start_session())

    assert Session.kill_all() == 2
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

      assert {:stop, :normal, %{exit: 1}} =
               Session.handle_info({:EXIT, self(), :port_closed}, %{exec_pid: self(), exit: nil})
    end

    test "a reap hangs the child up, relays its last words, and returns once it is gone" do
      pid =
        start_sh_session(
          args: ["-c", "trap 'echo bye; exit' HUP; echo up; while :; do sleep 0.05; done"]
        )

      recv_until_marker("up")
      os_pid = :sys.get_state(pid).os_pid

      assert Session.kill(pid) == :ok
      recv_until_marker("bye")
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
      assert {:ok, fresh} = Session.ensure(id, command: "cat")
      assert fresh != pid
      # A kill by id now reaps the fresh session, not the dying one.
      assert Session.kill(id) == :ok
      refute Process.alive?(fresh)
      assert Task.await(reap) == :ok
      assert_receive {:pty_exit, 129}
      refute alive?(os_pid)
      # The orphaned sleep is reaped by init, not erlexec: a zombie answers kill -0.
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
  end

  test "buffer bound: a chunk over the cap keeps its tail; overflow evicts whole chunks oldest first" do
    # Driven through the callbacks: no pty needed to exercise the deque.
    tail = String.duplicate("t", 100)
    chunk = String.duplicate("x", 900) <> tail
    {:noreply, kept} = Session.handle_info({:stdout, 1, chunk}, %{@state | cap: 100})
    {:noreply, off} = Session.handle_info({:stdout, 1, chunk}, @state)

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

  defp start_session(opts \\ []) do
    id = Session.new_id()
    on_exit(fn -> drop(id) end)
    {:ok, pid} = Session.ensure(id, opts ++ [command: "cat"])
    {id, pid}
  end

  defp start_sh_session(opts) do
    {_id, pid} = start_session(opts ++ [command: "sh"])
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
