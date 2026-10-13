defmodule Pty.ClientTest do
  # decode/1 is pure; dispatch/2 targets a session started per test.
  use ExUnit.Case, async: false

  import Pty.TestHelpers

  alias Pty.Client
  alias Pty.Session

  @default_cols 80
  @default_rows 24
  @resize_cols 120
  @resize_rows 48
  @oversize_dim 2_000

  describe "decode/1" do
    test "decodes input and resize frames" do
      assert Client.decode(~s|{"t":"i","d":"ls\\n"}|) == {:input, "ls\n"}

      assert Client.decode(~s|{"t":"r","cols":#{@resize_cols},"rows":#{@resize_rows}}|) ==
               {:resize, @resize_cols, @resize_rows}
    end

    test "ignores malformed json, unknown types, and non-binary frames" do
      for frame <- ["not json", ~s|{"t":"x"}|, ~s|{"t":"i","d":123}|, <<0, 1, 2>>, :nope] do
        assert Client.decode(frame) == :ignore
      end
    end

    test "ignores out-of-range, zero, and non-integer dimensions on both axes" do
      for {cols, rows} <- [
            {@oversize_dim, @resize_rows},
            {0, @resize_rows},
            {90.5, @resize_rows},
            {@resize_cols, @oversize_dim},
            {@resize_cols, 0},
            {@resize_cols, 90.5}
          ] do
        assert Client.decode(~s|{"t":"r","cols":#{cols},"rows":#{rows}}|) == :ignore
      end
    end
  end

  describe "dispatch/2" do
    setup do
      prev_cmd = System.get_env("PTY_CMD")
      System.put_env("PTY_CMD", "cat")
      id = Session.new_id()
      {:ok, pid} = Session.ensure(id)

      on_exit(fn ->
        drop(id)
        restore_env("PTY_CMD", prev_cmd)
      end)

      %{id: id, session: pid}
    end

    test "input reaches the pty", %{session: session} do
      {:ok, _} = Session.attach(session, self())
      marker = unique_marker()

      Client.dispatch(session, {:input, marker <> "\n"})

      assert recv_until_marker(marker) =~ marker
    end

    test "resize changes the session dimensions", %{id: id, session: session} do
      Client.dispatch(session, {:resize, @resize_cols, @resize_rows})

      poll_until(fn ->
        s = find_session(id)
        s && s.cols == @resize_cols && s.rows == @resize_rows
      end)
    end

    test ":ignore touches nothing", %{id: id, session: session} do
      assert Client.dispatch(session, :ignore) == :ok

      s = find_session(id)
      assert s.cols == @default_cols
      assert s.rows == @default_rows
    end
  end
end
