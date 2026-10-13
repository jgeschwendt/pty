defmodule Pty.SessionTest do
  # PTY_CMD and the global kill/kill_all touch shared state — never concurrent.
  use ExUnit.Case, async: false

  import Pty.TestHelpers

  alias Pty.Session

  @buffer_cap 256_000
  @default_cols 80
  @default_rows 24
  @id_len 12
  @recv_deadline_ms 2_000
  @resize_cols 100
  @resize_rows 40
  @sample 100

  # Buffer-cap probe: 500-byte lines stay under macOS MAX_CANON (1024) so cat
  # echoes them in canonical mode; drain self-paces so the pty buffer never fills.
  @cap_deadline_ms 5_000
  @cap_line_len 500
  @cap_lines_per_block 20
  @cap_target 350_000
  @drain_idle_ms 50

  setup do
    prev_cmd = System.get_env("PTY_CMD")
    prev_args = System.get_env("PTY_ARGS")

    on_exit(fn ->
      restore_env("PTY_CMD", prev_cmd)
      restore_env("PTY_ARGS", prev_args)
    end)

    :ok
  end

  describe "new_id/0" do
    test "returns unique, 12-char, url-safe ids" do
      ids = for _ <- 1..@sample, do: Session.new_id()

      assert Enum.all?(ids, &(byte_size(&1) == @id_len))
      assert Enum.all?(ids, &(&1 =~ ~r/\A[A-Za-z0-9_-]{12}\z/))
      assert length(Enum.uniq(ids)) == length(ids)
    end
  end

  describe "ensure/1" do
    test "starts and registers a session; same id is idempotent, different id is distinct" do
      id = Session.new_id()
      System.put_env("PTY_CMD", "cat")
      on_exit(fn -> drop(id) end)

      {:ok, pid} = Session.ensure(id)
      assert is_pid(pid)
      assert {:ok, ^pid} = Session.ensure(id)

      other = Session.new_id()
      on_exit(fn -> drop(other) end)
      {:ok, pid2} = Session.ensure(other)
      assert pid2 != pid
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
      System.put_env("PTY_CMD", "cat")
      System.put_env("PTY_ARGS", "-u  -n")
      id = Session.new_id()
      on_exit(fn -> drop(id) end)

      {:ok, pid} = Session.ensure(id)
      assert Session.info(pid).command == "cat -u -n"
    end
  end

  describe "stray input" do
    test "a detach without an attach, a stray message, and a dead pid are all harmless" do
      {_id, pid} = start_cat_session()

      Session.detach(pid, self())
      send(pid, :stray)
      assert Session.info(pid).subscribers == 0

      Process.exit(pid, :kill)
      refute Session.info(pid)
      assert Session.kill(pid) == {:error, :not_found}
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

  describe "attach/2 + input/2" do
    test "attach returns a binary buffer and input reaches the pty" do
      {_id, pid} = start_cat_session()

      assert {:ok, buffer} = Session.attach(pid, self())
      assert is_binary(buffer)

      marker = unique_marker()
      Session.input(pid, marker <> "\n")
      assert {:ok, _} = Session.attach(pid, self())

      assert recv_until_marker(marker) =~ marker
    end

    test "a later subscriber gets prior output replayed in its buffer" do
      {_id, pid} = start_cat_session()
      {:ok, _} = Session.attach(pid, self())

      marker = unique_marker()
      Session.input(pid, marker <> "\n")
      _ = recv_until_marker(marker)

      # A second, independent process attaches after output exists.
      task = Task.async(fn -> Session.attach(pid, self()) end)
      assert {:ok, buffer} = Task.await(task)
      assert String.contains?(buffer, marker)
    end
  end

  describe "detached buffering" do
    test "buffers pty output with no subscriber attached, then replays it on attach" do
      {id, pid} = start_cat_session()

      marker = unique_marker()
      Session.input(pid, marker <> "\n")
      poll_until(fn -> find_session(id).buffer_bytes >= byte_size(marker) end)

      assert {:ok, buffer} = Session.attach(pid, self())
      assert String.contains?(buffer, marker)
    end
  end

  describe "broadcast fan-out" do
    test "two live subscribers both receive the broadcast feed" do
      {_id, pid} = start_cat_session()
      parent = self()
      marker = unique_marker()

      collect = fn ->
        {:ok, _} = Session.attach(pid, self())
        send(parent, :ready)
        recv_until_marker(marker)
      end

      task1 = Task.async(collect)
      task2 = Task.async(collect)

      # Both must be attached before we feed input, or one misses the broadcast.
      assert_receive :ready, @recv_deadline_ms
      assert_receive :ready, @recv_deadline_ms

      Session.input(pid, marker <> "\n")

      assert Task.await(task1, @recv_deadline_ms) =~ marker
      assert Task.await(task2, @recv_deadline_ms) =~ marker
    end
  end

  describe "list/0" do
    test "reports metadata with the documented keys" do
      {id, _pid} = start_cat_session()

      s = find_session(id)
      assert s

      assert Enum.sort(Map.keys(s)) ==
               [:buffer_bytes, :cols, :command, :id, :rows, :started, :subscribers]

      assert s.id == id
      assert s.cols == @default_cols
      assert s.rows == @default_rows
      assert is_integer(s.buffer_bytes)
      assert is_integer(s.started)
    end
  end

  describe "resize/3" do
    test "updates the reported cols and rows" do
      {id, pid} = start_cat_session()

      Session.resize(pid, @default_cols, @default_rows)
      Session.resize(pid, @resize_cols, @resize_rows)

      poll_until(fn ->
        s = find_session(id)
        s && s.cols == @resize_cols && s.rows == @resize_rows
      end)
    end
  end

  describe "subscriber cleanup" do
    test "a dead subscriber is dropped from the count" do
      {id, pid} = start_cat_session()

      sub = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, _} = Session.attach(pid, sub)
      poll_until(fn -> find_session(id).subscribers >= 1 end)

      before = find_session(id).subscribers
      Process.exit(sub, :kill)

      poll_until(fn -> find_session(id).subscribers < before end)
      assert find_session(id).subscribers == before - 1
    end
  end

  describe "kill/1" do
    test "terminates a live session and errors on an unknown id" do
      {id, _pid} = start_cat_session()

      assert Session.kill(id) == :ok
      refute find_session(id)

      assert Session.kill("does-not-exist") == {:error, :not_found}
    end
  end

  describe "kill_all/0" do
    test "terminates every session and returns the count" do
      {_id1, _} = start_cat_session()
      {_id2, _} = start_cat_session()

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
    test "the replay buffer stays capped at #{@buffer_cap} bytes while output exceeds it" do
      {id, pid} = start_cat_session()
      {:ok, _} = Session.attach(pid, self())

      line = String.duplicate("x", @cap_line_len) <> "\n"
      block = String.duplicate(line, @cap_lines_per_block)

      received = feed_until(pid, block, @cap_target, deadline(@cap_deadline_ms))

      # We saw more raw output than the cap, yet the deque never exceeded it.
      assert received > @buffer_cap
      assert find_session(id).buffer_bytes <= @buffer_cap
    end

    test "a chunk larger than the cap keeps its tail rather than emptying the replay" do
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
    end
  end

  ## Helpers — session lifecycle

  defp alive?(os_pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true))

  defp start_cat_session do
    id = Session.new_id()
    System.put_env("PTY_CMD", "cat")
    {:ok, pid} = Session.ensure(id)
    on_exit(fn -> drop(id) end)
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

  ## Helpers — pty output

  # Feed `block` repeatedly, draining echoes between writes, until `target` bytes seen.
  defp feed_until(pid, block, target, deadline) do
    do_feed(pid, block, 0, target, deadline)
  end

  defp do_feed(pid, block, received, target, deadline) do
    cond do
      received >= target ->
        received

      now() > deadline ->
        flunk("received only #{received} bytes before deadline (target #{target})")

      true ->
        Session.input(pid, block)
        do_feed(pid, block, drain(received), target, deadline)
    end
  end

  defp drain(acc) do
    receive do
      {:pty_data, data} -> drain(acc + byte_size(data))
    after
      @drain_idle_ms -> acc
    end
  end
end
