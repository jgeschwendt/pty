defmodule PtyTest do
  # The facade drives real sessions and the global reap — never concurrent.
  use ExUnit.Case, async: false

  import Pty.TestHelpers

  @id_len 12
  @oversize_id_len 65
  @recv_deadline_ms 2_000
  @resize_cols 100
  @resize_rows 40

  setup do
    prev_cmd = System.get_env("PTY_CMD")
    System.put_env("PTY_CMD", "cat")
    on_exit(fn -> restore_env("PTY_CMD", prev_cmd) end)
    :ok
  end

  describe "valid_id?/1" do
    test "accepts minted ids and rejects control characters, overruns, and non-binaries" do
      assert Pty.valid_id?(Pty.new_id())
      assert byte_size(Pty.new_id()) == @id_len

      refute Pty.valid_id?("")
      refute Pty.valid_id?("has/slash")
      refute Pty.valid_id?("nl\n")
      refute Pty.valid_id?(String.duplicate("a", @oversize_id_len))
      refute Pty.valid_id?(nil)
    end
  end

  describe "start/2 + lookup/1" do
    test "starts idempotently and is findable by id" do
      id = start_session()

      {:ok, pid} = Pty.lookup(id)
      assert {:ok, ^pid} = Pty.start(id)
      assert Pty.lookup("nope") == :error
      # Refused before it can reach the registry or a log line.
      assert Pty.start("nl\n") == {:error, :invalid_id}
    end

    test "spawn options beat the environment" do
      id = start_session(args: ["-u"])

      assert Pty.info(id).command == "cat -u"
    end
  end

  describe "attach/2 + write/2 + detach/2" do
    test "a session accepts input, feeds its subscriber, and forgets it on detach" do
      id = start_session()

      assert {:ok, scrollback} = Pty.attach(id)
      assert scrollback == <<>>

      marker = unique_marker()
      assert Pty.write(id, marker <> "\n") == :ok
      assert recv_until_marker(marker) =~ marker

      assert Pty.detach(id) == :ok
      poll_until(fn -> Pty.info(id).subscribers == 0 end)
    end

    test "reattaching by id replays the scrollback into a fresh client" do
      id = start_session()
      {:ok, _} = Pty.attach(id)

      marker = unique_marker()
      Pty.write(id, marker <> "\n")
      _ = recv_until_marker(marker)

      task = Task.async(fn -> Pty.attach(id) end)
      assert {:ok, replay} = Task.await(task, @recv_deadline_ms)
      assert String.contains?(replay, marker)
    end
  end

  describe "resize/3" do
    test "takes a pid as readily as an id" do
      id = start_session()
      {:ok, pid} = Pty.lookup(id)

      assert Pty.resize(pid, @resize_cols, @resize_rows) == :ok

      poll_until(fn ->
        s = Pty.info(id)
        s.cols == @resize_cols && s.rows == @resize_rows
      end)
    end
  end

  describe "an unknown id" do
    test "is {:error, :not_found} everywhere, and nil for info" do
      assert Pty.attach("nope") == {:error, :not_found}
      assert Pty.detach("nope") == {:error, :not_found}
      assert Pty.write("nope", "x") == {:error, :not_found}
      assert Pty.resize("nope", @resize_cols, @resize_rows) == {:error, :not_found}
      assert Pty.reap("nope") == {:error, :not_found}
      assert Pty.info("nope") == nil
    end

    test "attach/2 on a pid that died is {:error, :not_found}, not an exit" do
      {pid, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      assert Pty.attach(pid) == {:error, :not_found}
    end
  end

  describe "reap/1 + reap_all/0 + list/0" do
    test "reaping removes sessions from the listing" do
      # Each child must have exec'd: one reaped before exec waits out the hangup grace.
      [{id, _} | _] =
        for _ <- 1..3 do
          id = start_session()
          ready({id, elem(Pty.lookup(id), 1)})
        end

      assert Enum.any?(Pty.list(), &(&1.id == id))
      assert Pty.reap(id) == :ok
      refute Enum.any?(Pty.list(), &(&1.id == id))
      assert Pty.reap_all() >= 2
      assert Pty.list() == []
    end
  end

  defp start_session(opts \\ []) do
    id = Pty.new_id()
    {:ok, _pid} = Pty.start(id, opts)
    on_exit(fn -> drop(id) end)
    id
  end
end
