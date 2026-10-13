defmodule Pty.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :pty,
      deps: deps(),
      description: "A PTY session engine for embedding terminals in Elixir apps.",
      docs: docs(),
      # 1.18, not 1.20: nothing here uses a newer language feature, and hosts
      # pin their own toolchain. The suite is green on 1.18 and 1.20 alike.
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      name: "Pty",
      package: package(),
      start_permanent: Mix.env() == :prod,
      # The house bar: `mix test --cover` fails below it.
      test_coverage: [summary: [threshold: 100]],
      version: @version
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # A library app: the tree it starts is the session registry and the session
  # supervisor, nothing else — no listener, no config. The host owns the endpoint.
  def application do
    [
      extra_applications: [:logger],
      mod: {Pty.Application, []}
    ]
  end

  # plug + websock_adapter carry `Pty.Plug`'s upgrade; websock is the
  # behaviour `Pty.Socket` implements. No web server: the host brings one.
  defp deps do
    [
      {:erlexec, "~> 2.3"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16"},
      {:websock, "~> 0.5"},
      {:websock_adapter, "~> 0.5"}
    ]
  end

  defp package do
    [
      files: ~w(lib priv mix.exs README.md LICENSE .formatter.exs),
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/jgeschwendt/pty"}
    ]
  end

  defp docs do
    [
      extras: ["README.md"],
      groups_for_modules: [
        Core: [Pty, Pty.Session],
        Transport: [Pty.Client, Pty.Plug, Pty.Socket]
      ],
      main: "Pty"
    ]
  end
end
