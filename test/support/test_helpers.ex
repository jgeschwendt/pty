defmodule Pty.TestHelpers do
  @moduledoc """
  Helpers shared across Pty test modules: session cleanup, lookup and readiness, env
  restore, unique markers, bounded polling, and pty-output collection.
  """

  import ExUnit.Assertions

  alias Pty.Session

  @poll_interval_ms 25
  @poll_tries 80

  # Test cleanup: kill a session outright — the link stops its child at once.
  # A reap would wait out the hangup grace for a child that missed its SIGHUP
  # by being reaped before it had exec'd.
  def drop(id), do: with({:ok, pid} <- Session.whereis(id), do: Process.exit(pid, :kill))

  def find_session(id), do: Enum.find(Session.list(), &(&1.id == id))

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

  # A `cat` session proven exec'd by its own copy of a line: a child reaped before
  # exec swallows the SIGHUP in erlexec's inherited handler and waits out the grace.
  def ready({_id, pid} = session) do
    {:ok, _} = Session.attach(pid, self())
    Session.input(pid, "up\n")
    recv_until_marker(~r/up.*up/s)
    session
  end

  # PTY output collected until it contains `marker`; each chunk must arrive
  # within ExUnit's :assert_receive_timeout.
  def recv_until_marker(marker, acc \\ "") do
    if acc =~ marker do
      acc
    else
      assert_receive {:pty_data, data}
      recv_until_marker(marker, acc <> data)
    end
  end
end
