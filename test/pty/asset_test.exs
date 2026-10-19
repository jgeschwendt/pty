defmodule Pty.AssetTest do
  # Characterizes the shipped browser glue: hosts load it by path, so its
  # location and entry points are part of the library's contract. Its
  # behaviour is test/js's.
  use ExUnit.Case, async: true

  setup do
    %{js: Path.join(Pty.asset_dir(), "pty.js") |> File.read!()}
  end

  test "pty.js ships in priv/static and exports both entry points", %{js: js} do
    assert js =~ "connect: connect"
    assert js =~ "mount: mount"
  end

  test "it imports nothing — the host owns xterm.js and the framework", %{js: js} do
    refute js =~ ~r/^\s*import\s/m
    refute js =~ "require("
    refute js =~ "cdn."
  end
end
