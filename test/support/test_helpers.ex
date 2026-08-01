defmodule Pty.TestHelpers do
  @moduledoc """
  Helpers shared across Pty test modules: env save/restore, session lookup,
  deadline-bounded polling, and pty-output collection.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias Pty.Session

  @poll_deadline_ms 2_000
  @poll_interval_ms 25
  @recv_deadline_ms 2_000

  def deadline(ms), do: now() + ms

  def find_session(id), do: Enum.find(Session.list(), &(&1.id == id))

  def now, do: System.monotonic_time(:millisecond)

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, val), do: System.put_env(key, val)

  def unique_marker, do: "MARK#{System.unique_integer([:positive])}"

  def poll_until(fun), do: poll_until(fun, deadline(@poll_deadline_ms))

  def poll_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      now() > deadline ->
        flunk("condition not met within #{@poll_deadline_ms}ms")

      true ->
        Process.sleep(@poll_interval_ms)
        poll_until(fun, deadline)
    end
  end

  def recv_until_marker(marker) do
    recv_until_marker(marker, "", deadline(@recv_deadline_ms))
  end

  def recv_until_marker(marker, acc, deadline) do
    cond do
      String.contains?(acc, marker) ->
        acc

      now() > deadline ->
        flunk("never saw marker #{marker}; collected #{byte_size(acc)} bytes of pty output")

      true ->
        receive do
          {:pty_data, data} -> recv_until_marker(marker, acc <> data, deadline)
        after
          @poll_interval_ms -> recv_until_marker(marker, acc, deadline)
        end
    end
  end
end
