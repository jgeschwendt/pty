defmodule Pty.Application do
  @moduledoc """
  The library's OTP application: the session registry and the `DynamicSupervisor`
  sessions run under.

  `pty` is a *library* app — it listens on nothing and serves nothing. A host
  adds `:pty` to its deps and this tree comes up with it, so `Pty.start/2`
  works without the host wiring anything into its own supervision tree. The host
  owns the HTTP endpoint and mounts `Pty.Plug` (or `Pty.Socket` directly).
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Pty.SessionRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Pty.SessionSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Pty.Supervisor)
  end
end
