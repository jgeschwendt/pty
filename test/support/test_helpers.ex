defmodule Pty.TestHelpers do
  @moduledoc """
  Helpers shared across Pty test modules: env save/restore, session lookup,
  bounded polling, and pty-output collection.
  """

  import ExUnit.Assertions

  alias Pty.Session

  @poll_interval_ms 25
  @poll_tries 80
  @recv_deadline_ms 2_000

  def deadline(ms), do: now() + ms

  def find_session(id), do: Enum.find(Session.list(), &(&1.id == id))

  def now, do: System.monotonic_time(:millisecond)

  def restore_env(key, val),
    do: if(val, do: System.put_env(key, val), else: System.delete_env(key))

  def unique_marker, do: "MARK#{System.unique_integer([:positive])}"

  # Truthy within @poll_tries × @poll_interval_ms, or the test fails.
  def poll_until(fun, tries \\ @poll_tries) do
    fun.() ||
      (
        assert tries > 0, "condition not met within #{@poll_tries * @poll_interval_ms}ms"
        Process.sleep(@poll_interval_ms)
        poll_until(fun, tries - 1)
      )
  end

  # PTY output collected until it contains `marker`; each chunk must arrive
  # within @recv_deadline_ms.
  def recv_until_marker(marker, acc \\ "") do
    if acc =~ marker do
      acc
    else
      assert_receive {:pty_data, data}, @recv_deadline_ms
      recv_until_marker(marker, acc <> data)
    end
  end
end
