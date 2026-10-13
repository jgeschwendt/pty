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
  window does — SIGHUP, then SIGKILL to its process group 2 s later — and
  returns once it is gone. Either way every subscriber receives `{:pty_exit,
  code}`: the child's exit code, or `129` (hung up) for any reap. A session killed outright still takes its child along: erlexec links
  the two, so no path leaves an orphaned PTY.

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

  Two caveats, both verified against erlexec 2.3 and both surprising:

    * **`TERM` cannot be unset.** `false` removes any other inherited variable,
      but erlexec always hands its child a `TERM` — so `%{"TERM" => false}`
      yields the inherited value, not an unset one. Override it instead. Every
      other name honours `false`.
    * **The inherited environment is snapshotted at boot.** The child inherits
      from erlexec's `exec-port` daemon, forked when `:pty` starts, so a
      `System.put_env/2` afterwards never reaches a session. Pass anything set
      at runtime through `:env` explicitly.
  """

  # :temporary — a dead session must not be resurrected as an empty shell.
  use GenServer, restart: :temporary
  import Bitwise, only: [band: 2]
  require Logger

  @registry Pty.SessionRegistry
  @supervisor Pty.SessionSupervisor
  # Replayed to reconstruct the terminal on (re)attach. Bounded deque of raw
  # output chunks (replay is chunk-aligned, ≤ cap; a chunk over the cap alone
  # is cut to its tail).
  @buffer_cap 256_000
  @default_cols 80
  # Layered under the caller's :env, so a host may override TERM.
  @default_env [{"TERM", "xterm-256color"}]
  @default_rows 24
  # SIGHUP, not SIGTERM: interactive shells (and claude) ignore SIGTERM but exit
  # on hangup. A child still alive this many seconds later gets SIGKILL.
  @hangup ~c"kill -HUP $CHILD_PID"
  @hangup_grace_s 2
  # What a reap reports: 128 + SIGHUP, as a shell reports a hung-up child.
  @hangup_code 129
  @id_bytes 9
  @info_timeout_ms 1_000
  # Signal-death exit code: 128 + signal number (shell convention). The low 7
  # bits of erlexec's raw wait(2) status carry the signal number (WTERMSIG).
  @signal_exit_base 128
  @signal_status_mask 0x7F

  ## Client API

  @doc "A fresh, URL-safe session id."
  def new_id, do: @id_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc """
  Return the running session for `id`, starting it if needed.

  `opts` configure the spawn (see the module doc) and apply only when the
  session is actually started — an already-live id is returned untouched.
  """
  def ensure(id, opts \\ []) do
    # The via-name registers before init/1 runs, so a live id never spawns.
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {id, opts}}) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
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
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {_id, pid} -> info(pid) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.started)
  end

  @doc "Reap one session by id; returns once its child is gone, or `{:error, :not_found}`."
  def kill(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(@supervisor, pid)
      [] -> {:error, :not_found}
    end
  end

  @doc "Terminate every session. Returns the number killed."
  def kill_all do
    # Straight from the supervisor: a session too busy to answer info/1 is
    # reaped all the same.
    @supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.count(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(@supervisor, pid) == :ok
    end)
  end

  @doc "Metadata for one live session, or `nil` if it is gone."
  def info(pid) when is_pid(pid) do
    GenServer.call(pid, :info, @info_timeout_ms)
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
    cols = resolve(opts, :cols, nil, fn -> @default_cols end)
    rows = resolve(opts, :rows, nil, fn -> @default_rows end)
    cap = resolve(opts, :scrollback, nil, fn -> @buffer_cap end)
    cwd = resolve(opts, :cwd, "PTY_CWD", &File.cwd!/0)
    env = env(opts)
    command_line = Enum.join([cmd | args], " ")

    # erlexec launches its child asynchronously: run/2 returns {:ok, ...} even for
    # a missing binary or cwd and reports the failure later as an exit. A live
    # {:ok, pid} for either would violate ensure/2's contract, so both are checked
    # up front — the executable as the child would find it, against its own cwd
    # and PATH.
    exec_opts = [
      :stdin,
      :stdout,
      # In pty mode stdout/stderr share one master fd; fold stderr into stdout
      # so subscribers get the single coherent stream a real terminal carries.
      {:stderr, :stdout},
      # Linked, not monitored: if this process dies by any means, erlexec stops
      # the child — the hangup, then SIGKILL to its whole process group.
      :link,
      {:kill, @hangup},
      {:kill_timeout, @hangup_grace_s},
      :kill_group,
      :pty,
      # A real terminal echoes typed input; keep echo on to match that.
      :pty_echo,
      # erlexec's winsz is {rows, cols} — the reverse of our cols/rows API.
      {:winsz, {rows, cols}},
      {:env, env},
      {:cd, cwd}
    ]

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
      {:ok, value} -> value
      value when is_binary(value) -> from_os_env(key, value)
    end
  end

  defp from_os_env(:args, value), do: String.split(value, " ", trim: true)
  defp from_os_env(_key, value), do: value

  # A path is taken against the child's cwd, a bare name searched on the PATH the
  # child will see; a missing cwd finds nothing.
  defp executable(cmd, cwd, env) do
    path =
      case List.keyfind(env, "PATH", 0) do
        {_, path} when is_binary(path) -> path
        _ -> System.get_env("PATH", "")
      end

    name = if cmd =~ "/", do: Path.expand(cmd, cwd), else: cmd

    case File.dir?(cwd) && :os.find_executable(String.to_charlist(name), String.to_charlist(path)) do
      false -> {:error, :enoent}
      executable -> {:ok, executable}
    end
  end

  # erlexec's :env extends the inherited environment rather than replacing it, and
  # a `false` value unsets a variable the parent had — the only way to keep an
  # inherited var out of the child.
  #
  # Merged by key here rather than concatenated, because erlexec resolves a
  # duplicate key by cancelling the pair: `[{"TERM", "xterm-256color"}, {"TERM",
  # false}]` drops our entry and leaves the INHERITED TERM standing, so a caller
  # asking to unset a var @default_env also sets would silently get the parent's
  # value. Merging first means erlexec sees one entry per name.
  defp env(opts) do
    overrides = opts |> resolve(:env, nil, fn -> [] end) |> normalize_env()

    @default_env |> Map.new() |> Map.merge(overrides) |> Enum.sort()
  end

  defp normalize_env(env) do
    Map.new(env, fn
      {key, false} -> {to_string(key), false}
      {key, value} -> {to_string(key), to_string(value)}
    end)
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = %{
      id: state.id,
      command: state.command,
      started: state.started,
      subscribers: map_size(state.subs),
      buffer_bytes: state.buffer_bytes,
      cols: state.cols,
      rows: state.rows
    }

    {:reply, info, state}
  end

  def handle_call({:attach, sub}, _from, state) do
    ref = Process.monitor(sub)
    {:reply, {:ok, replay(state)}, put_in(state.subs[sub], ref)}
  end

  defp replay(%{buffer: q}), do: q |> :queue.to_list() |> IO.iodata_to_binary()

  @impl true
  def handle_cast({:detach, sub}, state) do
    {ref, subs} = Map.pop(state.subs, sub)
    ref && Process.demonitor(ref, [:flush])
    {:noreply, %{state | subs: subs}}
  end

  def handle_cast({:input, data}, state) do
    :exec.send(state.os_pid, data)
    {:noreply, state}
  end

  def handle_cast({:resize, cols, rows}, state) do
    # winsz takes rows first, cols second — the reverse of our API.
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

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subs: Map.delete(state.subs, pid)}}
  end

  # A stray message (an EXIT from some other linked process) is no reason to die.
  def handle_info(_msg, state), do: {:noreply, state}

  # Decode erlexec's exit reason to an integer exit code for {:pty_exit, code}.
  defp exit_code(:normal), do: 0

  defp exit_code({:exit_status, raw}) do
    case :exec.status(raw) do
      {:status, code} -> code
      {:signal, _sig, _core} -> @signal_exit_base + band(raw, @signal_status_mask)
    end
  end

  # port_closed: erlexec itself went down, taking the child with it.
  defp exit_code(_other), do: 1

  # A chunk alone over the cap keeps a copy of its tail (a bare slice would pin
  # the whole chunk), so a replay is never emptied; an empty one is not queued.
  defp append(state, <<>>), do: state

  defp append(%{cap: cap} = state, data) when byte_size(data) > cap,
    do: append(state, :binary.copy(binary_part(data, byte_size(data), -cap)))

  defp append(%{buffer: q, buffer_bytes: n, cap: cap} = state, data) do
    {q, n} = trim(:queue.in(data, q), n + byte_size(data), cap)
    %{state | buffer: q, buffer_bytes: n}
  end

  defp broadcast(subs, msg), do: Enum.each(Map.keys(subs), &send(&1, msg))

  defp trim(q, n, cap) when n > cap do
    {{:value, head}, q} = :queue.out(q)
    trim(q, n - byte_size(head), cap)
  end

  defp trim(q, n, _cap), do: {q, n}

  # Every end — exit, reap, crash — passes here, so every subscriber hears it
  # once. A live child is stopped and awaited; the link guarantees its EXIT
  # (port_closed at worst), and the supervisor's shutdown timeout bounds a reap.
  # A reap reports @hangup_code whatever erlexec says: it overrides the status
  # of any child it was asked to stop with 0, racing the signal's own status.
  @impl true
  def terminate(_reason, %{exec_pid: exec_pid} = state) do
    code =
      state.exit ||
        (
          :exec.stop(exec_pid)
          receive do: ({:EXIT, ^exec_pid, _reason} -> @hangup_code)
        )

    broadcast(state.subs, {:pty_exit, code})
  end
end
