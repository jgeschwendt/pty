defmodule Pty.Session do
  @moduledoc """
  A long-lived PTY, decoupled from any client connection.

  One `Session` owns one child process running in a real PTY. Clients (a
  `Pty.Socket`, a LiveView, anything holding a pid) *attach* as subscribers:
  they receive a replay of recent output, then a live feed. Detaching (closing
  the tab, refreshing, network drop) does not touch the PTY — the process keeps
  running in the background and any UI can reattach by session id. Multiple
  clients may attach at once; they share one multiplexed terminal.

  A session ends when its child process exits — or when it is explicitly reaped
  (`kill/1`, `kill_all/0`, or shutdown), which SIGHUPs the child.

  Prefer the `Pty` facade; this module is the process itself.

  ## Spawn options

  Passed to `ensure/2`, and resolved per key as **option › application env ›
  OS env › default**:

  | Option       | Application env (`:pty`) | OS env     | Default              |
  | ------------ | ------------------------ | ---------- | -------------------- |
  | `:command`   | `:command`               | `PTY_CMD`  | `$SHELL` or `/bin/sh`|
  | `:args`      | `:args`                  | `PTY_ARGS` | `[]`                 |
  | `:cwd`       | `:cwd`                   | `PTY_CWD`  | the node's cwd       |
  | `:cols`      | `:cols`                  | —          | `80`                 |
  | `:rows`      | `:rows`                  | —          | `24`                 |
  | `:scrollback`| `:scrollback`            | —          | `256_000` bytes      |
  """

  # :temporary — a dead session must not be resurrected as an empty shell.
  use GenServer, restart: :temporary
  import Bitwise, only: [band: 2]
  require Logger

  @registry Pty.SessionRegistry
  @supervisor Pty.SessionSupervisor
  # Replayed to reconstruct the terminal on (re)attach. Bounded deque of raw
  # output chunks (replay is chunk-aligned, ≤ cap).
  @buffer_cap 256_000
  @default_cols 80
  @default_rows 24
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
    case Registry.lookup(@registry, id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {id, opts}}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
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

  @doc "Terminate one session by id (kills its PTY). Returns :ok or {:error, :not_found}."
  def kill(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(@supervisor, pid)
      [] -> {:error, :not_found}
    end
  end

  @doc "Terminate every session. Returns the number killed."
  def kill_all do
    for %{id: id} <- list(), kill(id) == :ok, reduce: 0, do: (n -> n + 1)
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
    # Trap exits so terminate/2 runs on supervisor shutdown (DynamicSupervisor
    # sends :shutdown, which would otherwise kill us silently and orphan the PTY).
    Process.flag(:trap_exit, true)

    cmd = resolve(opts, :command, "PTY_CMD", fn -> System.get_env("SHELL") || "/bin/sh" end)
    args = resolve(opts, :args, "PTY_ARGS", fn -> [] end) |> List.wrap()
    cols = resolve(opts, :cols, nil, fn -> @default_cols end)
    rows = resolve(opts, :rows, nil, fn -> @default_rows end)
    cap = resolve(opts, :scrollback, nil, fn -> @buffer_cap end)
    command_line = Enum.join([cmd | args], " ")

    # erlexec launches its child asynchronously: run/2 returns {:ok, ...} even for
    # a missing binary and reports the failure later via the monitor DOWN. A live
    # {:ok, pid} for a nonexistent command would violate ensure/2's contract, so we
    # resolve the executable up front and refuse to start if it isn't on PATH.
    case System.find_executable(cmd) do
      nil ->
        {:stop, {:spawn_failed, :enoent}}

      executable ->
        argv = Enum.map([executable | args], &String.to_charlist/1)

        exec_opts = [
          :stdin,
          :stdout,
          # In pty mode stdout/stderr share one master fd; fold stderr into stdout
          # so subscribers get the single coherent stream a real terminal carries.
          {:stderr, :stdout},
          :monitor,
          :pty,
          # A real terminal echoes typed input; keep echo on to match that.
          :pty_echo,
          # erlexec's winsz is {rows, cols} — the reverse of our cols/rows API.
          {:winsz, {rows, cols}},
          # {:env, [...]} extends (does not replace) the inherited parent env, so
          # the child keeps the host's full environment with TERM overridden.
          {:env, [{"TERM", "xterm-256color"}]},
          {:cd, resolve(opts, :cwd, "PTY_CWD", &File.cwd!/0)}
        ]

        case :exec.run(argv, exec_opts) do
          {:ok, exec_pid, os_pid} ->
            Logger.info("session #{id} started (#{command_line})")

            state = %{
              id: id,
              exec_pid: exec_pid,
              os_pid: os_pid,
              command: command_line,
              started: System.system_time(:second),
              subs: %{},
              buffer: :queue.new(),
              buffer_bytes: 0,
              cap: cap,
              cols: cols,
              rows: rows
            }

            {:ok, state}

          {:error, reason} ->
            {:stop, {:spawn_failed, reason}}
        end
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
    case Map.pop(state.subs, sub) do
      {nil, _subs} ->
        {:noreply, state}

      {ref, subs} ->
        Process.demonitor(ref, [:flush])
        {:noreply, %{state | subs: subs}}
    end
  end

  def handle_cast({:input, data}, state) do
    :exec.send(state.os_pid, data)
    {:noreply, state}
  end

  def handle_cast({:resize, cols, rows}, %{cols: cols, rows: rows} = state), do: {:noreply, state}

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

  # erlexec's monitor DOWN for the child: {:DOWN, OsPid::integer, :process, ExecPid, Reason}.
  # OsPid is pinned to ours, so it never collides with a subscriber's monitor DOWN
  # (whose second element is a reference, not our integer os_pid).
  def handle_info({:DOWN, os_pid, :process, _exec_pid, reason}, %{os_pid: os_pid} = state) do
    broadcast(state.subs, {:pty_exit, exit_code(reason)})
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subs: Map.delete(state.subs, pid)}}
  end

  # erlexec (run + :monitor, no link) delivers only the DOWN above — no EXIT for the
  # child. Keep a defensive catch-all for any stray message.
  def handle_info(_msg, state), do: {:noreply, state}

  # Decode erlexec's DOWN reason to an integer exit code for {:pty_exit, code}.
  defp exit_code(:normal), do: 0

  defp exit_code({:exit_status, raw}) do
    case :exec.status(raw) do
      {:status, code} -> code
      {:signal, _sig, _core} -> @signal_exit_base + band(raw, @signal_status_mask)
    end
  end

  defp exit_code(_other), do: 1

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

  @impl true
  # SIGHUP, not SIGTERM: interactive shells (and claude) ignore SIGTERM but exit
  # on hangup — the same signal a real terminal sends when its window closes.
  def terminate(_reason, %{os_pid: os_pid}) when is_integer(os_pid) do
    :exec.kill(os_pid, 1)
    :ok
  end

  def terminate(_reason, _state), do: :ok
end
