defmodule Pty do
  @moduledoc """
  A PTY session engine for embedding terminals in Elixir apps.

  Each session is a supervised process that owns one child running in a real
  PTY, buffers its output, and fans that output out to any number of attached
  clients. Sessions outlive their clients: closing the tab detaches, it does not
  kill the terminal, and reattaching by id replays scrollback into the same live
  process.

      {:ok, session} = Pty.start(Pty.new_id(), command: "claude")
      {:ok, scrollback} = Pty.attach(session)
      Pty.write(session, "ls\\n")
      # receive {:pty_data, bytes} … {:pty_exit, code}

  This module is the whole public API. `Pty.Session` is the process,
  `Pty.Client` the transport contract, `Pty.Socket` a ready WebSock
  handler, and `Pty.Plug` mounts that handler on a host's endpoint.

  Every function takes a session as either its **id** (a binary) or its **pid**.
  An id that names no live session yields `{:error, :not_found}` — only
  `start/2` creates.
  """

  alias Pty.Session

  # URL-safe base64 alphabet, capped: an id reaches logs and admin surfaces, so
  # control/ANSI characters and unbounded length are rejected at the door.
  @session_id ~r/\A[\w-]{1,64}\z/

  @type session :: pid | binary
  @type info :: %{
          id: binary,
          command: binary,
          started: integer,
          subscribers: non_neg_integer,
          buffer_bytes: non_neg_integer,
          cols: pos_integer,
          rows: pos_integer
        }

  @doc """
  Directory holding the browser glue (`pty.js`).

  Plug hosts can serve it straight from the app —
  `plug Plug.Static, at: "/pty", from: {:pty, "priv/static"}` — while a
  bundler or an escript that carries no `priv/` copies the file out of here.
  """
  @spec asset_dir() :: binary
  def asset_dir, do: :pty |> :code.priv_dir() |> Path.join("static")

  @doc "A fresh, URL-safe session id."
  @spec new_id() :: binary
  defdelegate new_id, to: Session

  @doc "True when `id` is well-formed enough to route on (see `new_id/0`)."
  @spec valid_id?(term) :: boolean
  def valid_id?(id) when is_binary(id), do: id =~ @session_id
  def valid_id?(_id), do: false

  @doc """
  Start the session for `id`, or return the one already running.

  Idempotent: `opts` (see `Pty.Session`) configure the spawn and are ignored
  when the id is already live, which is what makes reattach-by-id work.
  """
  @spec start(binary, keyword) :: {:ok, pid} | {:error, term}
  defdelegate start(id, opts \\ []), to: Session, as: :ensure

  @doc "Look up a live session by id."
  @spec lookup(binary) :: {:ok, pid} | :error
  defdelegate lookup(id), to: Session, as: :whereis

  @doc """
  Subscribe `subscriber` to the session's live feed.

  Returns the scrollback buffer to replay before the feed. The subscriber then
  receives `{:pty_data, binary}` and, once, `{:pty_exit, code}`.
  """
  @spec attach(session, pid) :: {:ok, binary} | {:error, :not_found}
  def attach(session, subscriber \\ self()) do
    with {:ok, pid} <- resolve(session), do: Session.attach(pid, subscriber)
  catch
    # A pid that died, or a session whose child exited before the call landed.
    :exit, _ -> {:error, :not_found}
  end

  @doc "Unsubscribe `subscriber`. The PTY keeps running."
  @spec detach(session, pid) :: :ok | {:error, :not_found}
  def detach(session, subscriber \\ self()) do
    with {:ok, pid} <- resolve(session), do: Session.detach(pid, subscriber)
  end

  @doc "Write `data` to the PTY's stdin."
  @spec write(session, binary) :: :ok | {:error, :not_found}
  def write(session, data) do
    with {:ok, pid} <- resolve(session), do: Session.input(pid, data)
  end

  @doc "Resize the PTY to `cols` x `rows` (SIGWINCH to the child)."
  @spec resize(session, pos_integer, pos_integer) :: :ok | {:error, :not_found}
  def resize(session, cols, rows) do
    with {:ok, pid} <- resolve(session), do: Session.resize(pid, cols, rows)
  end

  @doc "Metadata for one session, or `nil` if it is gone."
  @spec info(session) :: info | nil
  def info(session) do
    case resolve(session) do
      {:ok, pid} -> Session.info(pid)
      {:error, :not_found} -> nil
    end
  end

  @doc "Metadata for every live session, oldest first."
  @spec list() :: [info]
  defdelegate list, to: Session

  @doc "Terminate a session by id, SIGHUPing its child."
  @spec reap(binary) :: :ok | {:error, :not_found}
  defdelegate reap(id), to: Session, as: :kill

  @doc "Terminate every session; returns how many were reaped."
  @spec reap_all() :: non_neg_integer
  defdelegate reap_all, to: Session, as: :kill_all

  defp resolve(pid) when is_pid(pid), do: {:ok, pid}

  defp resolve(id) when is_binary(id) do
    case Session.whereis(id) do
      {:ok, pid} -> {:ok, pid}
      :error -> {:error, :not_found}
    end
  end
end
