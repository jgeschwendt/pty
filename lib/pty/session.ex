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
  way out, and returns once it is gone. Its id is free from the first instant,
  so an `ensure/2` mid-hangup starts a fresh session, while a `kill/1` by id
  meanwhile reaps that fresh one, or else waits the dying one out. Either way
  every subscriber receives `{:pty_exit, code}`: the child's exit code, or
  `129` (hung up) for a reap or a crash — unless the session is killed outright
  (`:kill`, or the supervisor's brutal kill past its shutdown timeout), which
  skips `terminate/2`; monitor it.
  A session killed outright still takes its child's process group along:
  erlexec links the two. Jobs an interactive shell moved to groups of their
  own survive that; a reap's hangup reaches them through the shell.

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
  | `:max_lag`   | `:max_lag`               | —          | `1_000` messages     |

  `:args` is a list (a lone string is one argument); `PTY_ARGS` alone is split on spaces.

  `:max_lag` must be a positive integer; anything else is refused as
  `{:error, {:spawn_failed, {:invalid_option, {:max_lag, value}}}}`. A local
  subscriber more than `:max_lag` messages behind is sent one `{:pty_lagged}`
  in place of the feed and taken off it, the hangup's relay included; it still
  receives the `{:pty_exit, code}`, and reattaches to resync from the scrollback.

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
  # URL-safe base64 alphabet, capped: an id reaches logs and admin surfaces, so
  # control/ANSI characters and unbounded length are rejected at the door.
  @session_id ~r/\A[\w-]{1,64}\z/

  ## Client API

  @doc "A fresh, URL-safe session id."
  def new_id, do: 9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc "True when `id` is well-formed enough to route on (see `new_id/0`)."
  def valid_id?(id), do: is_binary(id) and id =~ @session_id

  @doc """
  Return the running session for `id`, starting it if needed.

  `opts` configure the spawn (see the module doc) and apply only when the
  session is actually started — an already-live id is returned untouched. An
  id `valid_id?/1` refuses is `{:error, :invalid_id}`, before it can reach the
  registry or a log.
  """
  def ensure(id, opts \\ []) do
    # A live id is returned before anything is resolved. The via-name registers
    # before init/1 runs, so a racing start never spawns twice.
    with true <- valid_id?(id) || {:error, :invalid_id},
         :error <- whereis(id),
         {:ok, spec} <- spec(opts),
         {:error, {:already_started, pid}} <-
           DynamicSupervisor.start_child(@supervisor, {__MODULE__, {id, spec}}),
         do: {:ok, pid}
  catch
    # spec/1 raising on a malformed option returns as a raising init/1 would: {reason, stacktrace}.
    :error, reason -> {:error, {reason, __STACKTRACE__}}
  end

  # whereis_name, not lookup: it drops a dead pid the registry has yet to reap.
  @doc "Look up a live session by id."
  def whereis(id) do
    case Registry.whereis_name({@registry, id}) do
      :undefined -> :error
      pid -> {:ok, pid}
    end
  end

  # A pid only: a name's DOWN carries {name, node}, never matching its key.
  @doc "Subscribe `subscriber` to the live feed; returns the replay buffer."
  def attach(pid, subscriber) when is_pid(subscriber),
    do: GenServer.call(pid, {:attach, subscriber})

  @doc """
  Unsubscribe `subscriber` from the live feed. The PTY keeps running.

  Optional hygiene: a subscriber that simply dies is dropped by the monitor.
  """
  def detach(pid, subscriber), do: GenServer.cast(pid, {:detach, subscriber})

  # Guarded as erlexec's send/winsz are: an ill-typed cast would crash the
  # session, and with it every client's shell, while the caller got :ok.
  @doc "Write `data` to the PTY's stdin."
  def input(pid, data) when is_binary(data), do: GenServer.cast(pid, {:input, data})

  @doc "Resize the PTY to `cols` x `rows`."
  def resize(pid, cols, rows) when is_integer(cols) and is_integer(rows),
    do: GenServer.cast(pid, {:resize, cols, rows})

  @doc "Metadata for every live session, oldest first."
  def list do
    # By the monotonic stamp each session registers under: `started` is wall
    # seconds, which ties within one and can step back. A binary key only: a
    # dying session's {:reaping, …} key is no live session.
    @registry
    |> Registry.select([{{:"$3", :"$1", :"$2"}, [{:is_binary, :"$3"}], [{{:"$2", :"$1"}}]}])
    |> Enum.sort()
    |> Enum.flat_map(&List.wrap(info(elem(&1, 1))))
  end

  @doc "Reap one session by id or pid; returns once its child is gone, or `{:error, :not_found}`."
  def kill(id) when is_binary(id) do
    # An id a reap has already freed still names its dying session until gone:
    # terminate/2 holds {:reaping, id, pid} before it lets go of the id itself.
    # Found is not reaped: one gone by the time it is stopped is not found either.
    with {:error, :not_found} <- kill({:via, Registry, {@registry, id}}) do
      @registry
      |> Registry.select([{{{:reaping, id, :_}, :"$1", :_}, [], [:"$1"]}])
      |> Enum.map(&kill/1)
      |> Enum.find({:error, :not_found}, &(&1 == :ok))
    end
  end

  # Stopped directly, not through the supervisor, which would block every
  # ensure/2 behind a hangup. Any exit — gone already, or ended mid-stop — is
  # caught as not found.
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

  ## Spawn spec

  # Resolved in the caller, never inside the one supervisor every start queues
  # on: executable/3 probes the filesystem, and a hung mount must stall only its
  # own start. erlexec launches its child asynchronously — run/2 returns {:ok, …}
  # even for a missing binary or cwd — so both are checked here, up front.
  defp spec(opts) do
    args = opts |> resolve(:args, "PTY_ARGS", fn -> [] end) |> List.wrap()
    cmd = resolve(opts, :command, "PTY_CMD", fn -> System.get_env("SHELL") || "/bin/sh" end)
    cwd = resolve(opts, :cwd, "PTY_CWD", &File.cwd!/0)
    env = env(opts)
    max_lag = resolve(opts, :max_lag, nil, fn -> 1_000 end)

    # Any non-number outranks every integer in term order, so nil or :infinity
    # would disable the bound unseen; 0 or less would drop every subscriber.
    with true <-
           (is_integer(max_lag) and max_lag > 0) ||
             {:error, {:spawn_failed, {:invalid_option, {:max_lag, max_lag}}}},
         {:ok, executable} <- executable(cmd, cwd, env) do
      {:ok,
       %{
         argv: [executable | Enum.map(args, &String.to_charlist/1)],
         cap: resolve(opts, :scrollback, nil, fn -> 256_000 end),
         cols: resolve(opts, :cols, nil, fn -> 80 end),
         command: Enum.join([cmd | args], " "),
         cwd: cwd,
         env: env,
         max_lag: max_lag,
         rows: resolve(opts, :rows, nil, fn -> 24 end)
       }}
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
    # PATH entries are taken against the child's cwd too ("" is the cwd itself).
    path =
      (env["PATH"] || System.get_env("PATH", ""))
      |> String.split(":")
      |> Enum.map_join(":", &Path.expand(&1, cwd))

    name = if cmd =~ "/", do: Path.expand(cmd, cwd), else: cmd

    case File.dir?(cwd) && :os.find_executable(String.to_charlist(name), String.to_charlist(path)) do
      false -> {:error, {:spawn_failed, :enoent}}
      executable -> {:ok, executable}
    end
  end

  # erlexec's :env extends the inherited environment; `false` unsets a parent
  # variable. Enum.into keeps one entry per name, last wins — the caller's over
  # the TERM default — normalised to strings for executable/3's PATH lookup.
  defp env(opts) do
    opts
    |> resolve(:env, nil, fn -> [] end)
    |> Enum.into(%{"TERM" => "xterm-256color"}, fn {key, value} ->
      {to_string(key), value != false && to_string(value)}
    end)
  end

  ## Process wiring

  def start_link({id, spec}) do
    stamp = System.unique_integer([:monotonic])
    GenServer.start_link(__MODULE__, {id, spec}, name: {:via, Registry, {@registry, id, stamp}})
  end

  ## Server

  @impl true
  def init({id, spec}) do
    # Trap exits so terminate/2 runs on supervisor shutdown, and so the child's
    # exit arrives as a message through the erlexec link.
    Process.flag(:trap_exit, true)

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
      {:winsz, {spec.rows, spec.cols}},
      {:env, Map.to_list(spec.env)},
      {:cd, spec.cwd}
    ]

    case :exec.run(spec.argv, exec_opts) do
      {:ok, exec_pid, os_pid} ->
        Logger.info("session #{id} started (#{spec.command})")

        {:ok,
         spec
         |> Map.take([:cap, :cols, :command, :max_lag, :rows])
         |> Map.merge(%{
           buffer: :queue.new(),
           buffer_bytes: 0,
           exec_pid: exec_pid,
           exit: nil,
           id: id,
           os_pid: os_pid,
           started: System.system_time(:second),
           subs: %{}
         })}

      {:error, reason} ->
        {:stop, {:spawn_failed, reason}}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = Map.take(state, [:buffer_bytes, :cols, :command, :id, :rows, :started])
    {:reply, Map.put(info, :subscribers, map_size(state.subs)), state}
  end

  # A re-attach keeps its monitor: one per subscriber, however often it asks.
  # A lagged one is put back on the feed.
  def handle_call({:attach, sub}, _from, state) do
    {:reply, {:ok, state.buffer |> :queue.to_list() |> IO.iodata_to_binary()},
     put_in(state.subs[sub], unlag(state.subs[sub] || Process.monitor(sub)))}
  end

  @impl true
  def handle_cast({:detach, sub}, state) do
    {ref, state} = pop_in(state.subs[sub])
    ref && Process.demonitor(unlag(ref), [:flush])
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
  def handle_info({:stdout, os_pid, data}, %{os_pid: os_pid} = state),
    do: {:noreply, append(feed(state, data), data)}

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

  # A subscriber past max_lag queued messages gets one {:pty_lagged} in place of
  # the chunk and is held as {:lagged, ref}: off the feed, since unread its
  # mailbox would grow the VM by the child's whole output, but still monitored,
  # counted, and told the exit. It reattaches to resync from the scrollback, as
  # tmux does. Process.info/2 raises on a remote pid, so only a local one is
  # measured; a dead one is nil, sent to as before, and dropped by its DOWN.
  defp feed(state, data),
    do: %{state | subs: :maps.map(&feed(&1, &2, data, state.max_lag), state.subs)}

  defp feed(_sub, {:lagged, _} = lagged, _data, _max_lag), do: lagged

  defp feed(sub, ref, data, max_lag) do
    if node(sub) == node() and
         match?({_, n} when n > max_lag, Process.info(sub, :message_queue_len)) do
      send(sub, {:pty_lagged})
      {:lagged, ref}
    else
      send(sub, {:pty_data, data})
      ref
    end
  end

  defp unlag(ref), do: with({:lagged, ref} <- ref, do: ref)

  # The link guarantees the hung-up child's EXIT (port_closed at worst). A hangup
  # reports 129 whatever erlexec says: erlexec reports 0 for any child it
  # stopped. The reaping key is taken before the id is let go, so a kill/1 by id
  # finds this dying session while ensure/2 starts a fresh one.
  @impl true
  def terminate(_reason, state) do
    Registry.register(@registry, {:reaping, state.id, self()}, nil)
    Registry.unregister(@registry, state.id)

    state =
      with %{exit: nil} <- state do
        :exec.kill(state.os_pid, :sighup)
        Process.send_after(self(), :hangup_grace, @hangup_grace_ms)
        await_exit(state)
      end

    :maps.foreach(fn sub, _ref -> send(sub, {:pty_exit, state.exit}) end, state.subs)
  end

  # Relays what the child prints on its way out, bounded by max_lag as the live
  # feed is; past the grace, stops it.
  defp await_exit(%{exec_pid: exec_pid, os_pid: os_pid} = state) do
    receive do
      {:stdout, ^os_pid, data} ->
        await_exit(feed(state, data))

      :hangup_grace ->
        :exec.stop(exec_pid)
        await_exit(state)

      {:EXIT, ^exec_pid, _reason} ->
        %{state | exit: 129}
    end
  end
end
