defmodule Pty.Session do
  @moduledoc """
  A long-lived PTY, decoupled from any client connection.

  One `Session` owns one child process running in a real PTY. Clients (a
  `Pty.Socket`, a LiveView, anything holding a pid) *attach* as subscribers:
  they receive a replay of recent output, then a live feed. Detaching (closing
  the tab, refreshing, network drop) does not touch the PTY — the process keeps
  running in the background and any UI can reattach by session id. Multiple
  clients may attach at once; they share one multiplexed terminal.

  A session ends when its child process exits, or when it is reaped (`kill/1`,
  `kill_all/0`, or shutdown). Reaping hangs the child up the way a closed
  window does — SIGHUP, and a child still alive 2 s later gets SIGTERM, then
  SIGKILL 1 s after, both to its process group — relays what it prints on the
  way out, and returns once it is gone. Either way every subscriber receives
  `{:pty_exit, code}`: the child's exit code, or `129` (hung up) for any reap.
  A session killed outright still takes its child along: erlexec links the
  two, so no path leaves an orphaned PTY.

  Prefer the `Pty` facade; this module is the process itself.

  ## Spawn options

  Passed to `ensure/2`, and resolved per key as **option › application env ›
  OS env › default**:

  | Option       | Application env (`:pty`) | OS env     | Default              |
  | ------------ | ------------------------ | ---------- | -------------------- |
  | `:command`   | `:command`               | `PTY_CMD`  | `$SHELL` or `/bin/sh`|
  | `:args`      | `:args`                  | `PTY_ARGS` | `[]`                 |
  | `:cwd`       | `:cwd`                   | `PTY_CWD`  | the node's cwd       |
  | `:env`       | `:env`                   | —          | `[]`                 |
  | `:cols`      | `:cols`                  | —          | `80`                 |
  | `:rows`      | `:rows`                  | —          | `24`                 |
  | `:scrollback`| `:scrollback`            | —          | `256_000` bytes      |

  ## Environment

  `:env` takes a map or a list of pairs and *layers over* the environment the
  child would otherwise inherit — it does not replace it. `TERM` is set to
  `xterm-256color` first, so a caller entry may override it. A value of `false`
  unsets a variable the parent had, which is how a host keeps something out of
  the child's environment rather than merely not adding it:

      Pty.start(id, command: "claude", env: %{"CLAUDE_CONFIG_DIR" => dir, "ANTHROPIC_MODEL" => false})

  One caveat, verified against erlexec 2.3: **the inherited environment is
  snapshotted at boot.** The child inherits from erlexec's `exec-port` daemon,
  forked when `:pty` starts, so a `System.put_env/2` afterwards never reaches a
  session. Pass anything set at runtime through `:env` explicitly.
  """

  # :temporary — a dead session must not be resurrected as an empty shell.
  use GenServer, restart: :temporary
  require Logger

  @registry Pty.SessionRegistry
  @supervisor Pty.SessionSupervisor
  # SIGHUP first: interactive shells (and claude) ignore SIGTERM but exit on
  # hangup. Past the grace erlexec stops the child: SIGTERM, then SIGKILL after
  # @kill_timeout_s. Both stay under the supervisor's 5 s shutdown.
  @hangup_grace_ms 2_000
  @kill_timeout_s 1

  ## Client API

  @doc "A fresh, URL-safe session id."
  def new_id, do: 9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc """
  Return the running session for `id`, starting it if needed.

  `opts` configure the spawn (see the module doc) and apply only when the
  session is actually started — an already-live id is returned untouched.
  """
  def ensure(id, opts \\ []) do
    # The via-name registers before init/1 runs, so a live id never spawns.
    with {:error, {:already_started, pid}} <-
           DynamicSupervisor.start_child(@supervisor, {__MODULE__, {id, opts}}),
         do: {:ok, pid}
  end

  @doc "Look up a live session by id."
  def whereis(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "Subscribe `subscriber` to the live feed; returns the replay buffer."
  def attach(pid, subscriber), do: GenServer.call(pid, {:attach, subscriber})

  @doc """
  Unsubscribe `subscriber` from the live feed. The PTY keeps running.

  Optional hygiene: a subscriber that simply dies is dropped by the monitor.
  """
  def detach(pid, subscriber), do: GenServer.cast(pid, {:detach, subscriber})

  @doc "Write `data` to the PTY's stdin."
  def input(pid, data), do: GenServer.cast(pid, {:input, data})

  @doc "Resize the PTY to `cols` x `rows`."
  def resize(pid, cols, rows), do: GenServer.cast(pid, {:resize, cols, rows})

  @doc "Metadata for every live session, oldest first."
  def list do
    @registry
    |> Registry.select([{{:_, :"$1", :_}, [], [:"$1"]}])
    |> Enum.flat_map(&List.wrap(info(&1)))
    |> Enum.sort_by(& &1.started)
  end

  @doc "Reap one session by id or pid; returns once its child is gone, or `{:error, :not_found}`."
  def kill(id) when is_binary(id), do: kill({:via, Registry, {@registry, id}})

  # Stopped directly, not through the supervisor, which would block every
  # ensure/2 behind a hangup. A gone session exits :noproc, caught here.
  def kill(pid) do
    GenServer.stop(pid, :shutdown)
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc "Reap every session at once. Returns the number reaped."
  def kill_all do
    # Straight from the supervisor: a session too busy to answer info/1 is
    # reaped all the same, and every hangup runs concurrently.
    @supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} -> Task.async(fn -> kill(pid) end) end)
    |> Task.await_many(:infinity)
    |> Enum.count(&(&1 == :ok))
  end

  @doc "Metadata for one live session, or `nil` if it is gone."
  def info(pid) when is_pid(pid) do
    GenServer.call(pid, :info, 1_000)
  catch
    :exit, _ -> nil
  end

  ## Process wiring

  def start_link({id, opts}) do
    GenServer.start_link(__MODULE__, {id, opts}, name: {:via, Registry, {@registry, id}})
  end

  ## Server

  @impl true
  def init({id, opts}) do
    # Trap exits so terminate/2 runs on supervisor shutdown, and so the child's
    # exit arrives as a message through the erlexec link.
    Process.flag(:trap_exit, true)

    cmd = resolve(opts, :command, "PTY_CMD", fn -> System.get_env("SHELL") || "/bin/sh" end)
    args = resolve(opts, :args, "PTY_ARGS", fn -> [] end) |> List.wrap()
    cols = resolve(opts, :cols, nil, fn -> 80 end)
    rows = resolve(opts, :rows, nil, fn -> 24 end)
    cap = resolve(opts, :scrollback, nil, fn -> 256_000 end)
    cwd = resolve(opts, :cwd, "PTY_CWD", &File.cwd!/0)
    env = env(opts)
    command_line = Enum.join([cmd | args], " ")

    exec_opts = [
      :stdin,
      :stdout,
      # In pty mode stdout/stderr share one master fd; fold stderr into stdout
      # so subscribers get the single coherent stream a real terminal carries.
      {:stderr, :stdout},
      # Linked, not monitored: if this process dies by any means, erlexec stops
      # the child — SIGTERM, then SIGKILL, to its whole process group.
      :link,
      {:kill_timeout, @kill_timeout_s},
      :kill_group,
      :pty,
      # A real terminal echoes typed input; keep echo on to match that.
      :pty_echo,
      # erlexec's winsz is {rows, cols} — the reverse of our cols/rows API.
      {:winsz, {rows, cols}},
      {:env, Map.to_list(env)},
      {:cd, cwd}
    ]

    # erlexec launches its child asynchronously: run/2 returns {:ok, ...} even for
    # a missing binary or cwd and reports the failure later as an exit. A live
    # {:ok, pid} for either would violate ensure/2's contract, so both are checked
    # up front (see executable/3).
    with {:ok, executable} <- executable(cmd, cwd, env),
         argv = [executable | Enum.map(args, &String.to_charlist/1)],
         {:ok, exec_pid, os_pid} <- :exec.run(argv, exec_opts) do
      Logger.info("session #{id} started (#{command_line})")

      {:ok,
       %{
         id: id,
         exec_pid: exec_pid,
         os_pid: os_pid,
         command: command_line,
         started: System.system_time(:second),
         subs: %{},
         buffer: :queue.new(),
         buffer_bytes: 0,
         cap: cap,
         exit: nil,
         cols: cols,
         rows: rows
       }}
    else
      {:error, reason} -> {:stop, {:spawn_failed, reason}}
    end
  end

  # option › application env › OS env › default. The OS-env rung is a
  # convenience for hosts that configure pty the way the standalone app did.
  defp resolve(opts, key, os_env, default) do
    with :error <- Keyword.fetch(opts, key),
         :error <- Application.fetch_env(:pty, key),
         nil <- os_env && System.get_env(os_env) do
      default.()
    else
      {:ok, value} ->
        value

      value when is_binary(value) ->
        if key == :args, do: String.split(value, " ", trim: true), else: value
    end
  end

  # A path is taken against the child's cwd, a bare name searched on the `:env`
  # PATH if given, else the node's own; a missing cwd finds nothing.
  defp executable(cmd, cwd, env) do
    path = env["PATH"] || System.get_env("PATH", "")

    # PATH entries are taken against the child's cwd too ("" is the cwd itself).
    path = path |> String.split(":") |> Enum.map_join(":", &Path.expand(&1, cwd))
    name = if cmd =~ "/", do: Path.expand(cmd, cwd), else: cmd

    case File.dir?(cwd) && :os.find_executable(String.to_charlist(name), String.to_charlist(path)) do
      false -> {:error, :enoent}
      executable -> {:ok, executable}
    end
  end

  # erlexec's :env extends the inherited environment; `false` unsets a parent
  # variable. Map.new keeps one entry per name, last wins — the caller's over the
  # TERM default — normalised to strings for executable/3's PATH lookup.
  defp env(opts) do
    [{"TERM", "xterm-256color"} | Enum.to_list(resolve(opts, :env, nil, fn -> [] end))]
    |> Map.new(fn
      {key, false} -> {to_string(key), false}
      {key, value} -> {to_string(key), to_string(value)}
    end)
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = Map.take(state, [:id, :command, :started, :buffer_bytes, :cols, :rows])
    {:reply, Map.put(info, :subscribers, map_size(state.subs)), state}
  end

  def handle_call({:attach, sub}, _from, state) do
    ref = Process.monitor(sub)

    {:reply, {:ok, state.buffer |> :queue.to_list() |> IO.iodata_to_binary()},
     put_in(state.subs[sub], ref)}
  end

  @impl true
  def handle_cast({:detach, sub}, state) do
    {ref, state} = pop_in(state.subs[sub])
    ref && Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_cast({:input, data}, state) do
    :exec.send(state.os_pid, data)
    {:noreply, state}
  end

  # Unchanged dims skip winsz, a synchronous round trip through erlexec.
  def handle_cast({:resize, cols, rows}, %{cols: cols, rows: rows} = state), do: {:noreply, state}

  def handle_cast({:resize, cols, rows}, state) do
    :exec.winsz(state.os_pid, rows, cols)
    {:noreply, %{state | cols: cols, rows: rows}}
  end

  @impl true
  def handle_info({:stdout, os_pid, data}, %{os_pid: os_pid} = state) do
    broadcast(state.subs, {:pty_data, data})
    {:noreply, append(state, data)}
  end

  # The child exited: the link delivers its status. terminate/2 tells subscribers.
  def handle_info({:EXIT, exec_pid, reason}, %{exec_pid: exec_pid} = state),
    do: {:stop, :normal, %{state | exit: exit_code(reason)}}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, update_in(state.subs, &Map.delete(&1, pid))}

  # A stray message (an EXIT from some other linked process) is no reason to die.
  def handle_info(_msg, state), do: {:noreply, state}

  defp exit_code(:normal), do: 0

  defp exit_code({:exit_status, raw}) do
    case :exec.status(raw) do
      {:status, code} -> code
      # Signal death: 128 + signal number (shell convention). The low 7 bits of
      # erlexec's raw wait(2) status carry the signal number (WTERMSIG).
      {:signal, _sig, _core} -> 128 + Bitwise.band(raw, 0x7F)
    end
  end

  # port_closed: erlexec itself went down, taking the child with it.
  defp exit_code(_other), do: 1

  # Replayed to reconstruct the terminal on (re)attach: a bounded deque of raw
  # output chunks, evicted whole, so replay is chunk-aligned and ≤ cap. A chunk
  # alone over the cap keeps a copy of its tail (a bare slice would pin the whole
  # chunk), so a replay is never emptied; an empty one is not queued.
  defp append(state, <<>>), do: state

  defp append(%{cap: cap} = state, data) when byte_size(data) > cap,
    do: append(state, :binary.copy(binary_part(data, byte_size(data), -cap)))

  defp append(%{buffer: q, buffer_bytes: n} = state, data),
    do: trim(%{state | buffer: :queue.in(data, q), buffer_bytes: n + byte_size(data)})

  defp trim(%{buffer: q, buffer_bytes: n, cap: cap} = state) when n > cap do
    {{:value, head}, q} = :queue.out(q)
    trim(%{state | buffer: q, buffer_bytes: n - byte_size(head)})
  end

  defp trim(state), do: state

  defp broadcast(subs, msg), do: :maps.foreach(fn sub, _ref -> send(sub, msg) end, subs)

  # Every end — exit, reap, crash — passes here, so every subscriber hears it
  # once. A live child is hung up and awaited; the link guarantees its EXIT
  # (port_closed at worst). A reap reports 129 — 128 + SIGHUP, as a shell
  # reports a hung-up child — whatever erlexec says: it overrides the status of
  # any child it stopped with 0.
  @impl true
  def terminate(_reason, state) do
    code =
      state.exit ||
        (
          :exec.kill(state.os_pid, :sighup)
          Process.send_after(self(), :hangup_grace, @hangup_grace_ms)
          await_exit(state)
        )

    broadcast(state.subs, {:pty_exit, code})
  end

  # Relays what the child prints on its way out; past the grace, stops it.
  defp await_exit(%{exec_pid: exec_pid, os_pid: os_pid} = state) do
    receive do
      {:stdout, ^os_pid, data} ->
        broadcast(state.subs, {:pty_data, data})
        await_exit(state)

      :hangup_grace ->
        :exec.stop(exec_pid)
        await_exit(state)

      {:EXIT, ^exec_pid, _reason} ->
        129
    end
  end
end
