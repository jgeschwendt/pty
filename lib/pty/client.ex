defmodule Pty.Client do
  @moduledoc """
  The transport-agnostic contract between a session and whatever carries it.

  A *client* is any process attached to a `Pty.Session` — a WebSocket
  handler, a LiveView, a test process, an SSH channel. There is no behaviour to
  implement; the contract is three obligations:

    1. **Attach.** Call `Pty.attach/2` with the process that will receive the
       feed. The reply is the session's scrollback — write it to the terminal
       before anything else so the view is reconstructed.
    2. **Handle two messages.** The session sends `{:pty_data, binary}` for
       every chunk of PTY output and `{:pty_exit, code}` once, when the session
       ends — its child exited (`code` is the exit status), or it was reaped or
       crashed (`129`). Only a session killed outright cannot say so: monitor
       its pid to cover that too. Everything else is the client's own business.
    3. **Detach.** Dying is enough — the session monitors subscribers and drops
       them. Call `Pty.detach/2` when the client process outlives the view.

  Sessions never care who is attached: a client owns no PTY and its death is not
  the session's death.

  ## Wire framing

  `decode/1` and `dispatch/2` implement the browser protocol shared by every
  transport, so a Phoenix Channel or a LiveView `handle_event` gets the same
  validation as `Pty.Socket` without restating it:

    * `{"t":"i","d":"<keys>"}` — keyboard input → PTY stdin
    * `{"t":"b","d":"<bytes>"}` — raw input → PTY stdin, one byte per code
      point 0–255 (xterm.js's `onBinary`, which carries every X10-encoded
      mouse report)
    * `{"t":"r","cols":C,"rows":R}` — resize (SIGWINCH to the child)

  Anything else — malformed JSON, unknown type, a `"b"` code point above 255,
  non-integer or out-of-range dimensions — decodes to `:ignore`. A bad frame is never a crashed session.
  """

  alias Pty.Session

  # Guards the resize path: a client-supplied dimension reaches ioctl(TIOCSWINSZ).
  @max_dimension 1_000

  @type t :: {:input, binary} | {:resize, pos_integer, pos_integer} | :ignore

  @doc "Decode one client text frame into a command, or `:ignore`."
  @spec decode(binary) :: t
  def decode(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, decoded} -> command(decoded)
      {:error, _} -> :ignore
    end
  end

  def decode(_frame), do: :ignore

  defp command(%{"t" => "i", "d" => data}) when is_binary(data), do: {:input, data}

  # Latin-1 is exactly the code points 0–255 as bytes; anything above is an error tuple.
  defp command(%{"t" => "b", "d" => data}) when is_binary(data) do
    case :unicode.characters_to_binary(data, :utf8, :latin1) do
      bytes when is_binary(bytes) -> {:input, bytes}
      _error -> :ignore
    end
  end

  defp command(%{"t" => "r", "cols" => cols, "rows" => rows})
       when is_integer(cols) and cols > 0 and cols <= @max_dimension and
              is_integer(rows) and rows > 0 and rows <= @max_dimension,
       do: {:resize, cols, rows}

  defp command(_decoded), do: :ignore

  @doc "Apply a decoded command to a session. `:ignore` is a no-op."
  @spec dispatch(pid, t) :: :ok
  def dispatch(session, {:input, data}), do: Session.input(session, data)
  def dispatch(session, {:resize, cols, rows}), do: Session.resize(session, cols, rows)
  def dispatch(_session, :ignore), do: :ok

  @doc "Decode a client frame and apply it — the whole inbound path in one call."
  @spec handle(pid, binary) :: :ok
  def handle(session, text), do: dispatch(session, decode(text))
end
