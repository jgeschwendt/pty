# Plan

Embeddable PTY sessions for Elixir hosts: erlexec drives one OS child per
session out of process; the host owns endpoint, auth and page.

## Map

| Path                  | Holds                                                          |
| --------------------- | -------------------------------------------------------------- |
| `lib/pty.ex`          | The facade — every public call, id or pid.                     |
| `lib/pty/session.ex`  | The `GenServer` owning one PTY: spawn, fan-out, scrollback.    |
| `lib/pty/client.ex`   | The transport contract and the shared frame decoder.           |
| `lib/pty/socket.ex`   | `WebSock` handler bridging one socket to a session.            |
| `lib/pty/plug.ex`     | Upgrade gate: id validation, `Origin` check, hand-off.         |
| `priv/static/pty.js`  | Browser glue; the host hands xterm.js in.                      |
| `test/`               | ExUnit over real `cat`/`sh` PTYs — no mocks.                   |

## Invariants

- A session outlives every client; only child exit or a reap ends it.
- `start/2` is idempotent and fail-closed on a missing binary.
- A bad client frame is `:ignore`, never a crashed session.
- A WebSocket close of `1000` means the child exited; `pty.js` stops
  reconnecting on it, anything else reconnects.
- A cross-origin browser upgrade is refused unless `:check_origin` admits it.

## Hazards

- The shift sandbox denies `posix_openpt`, so 31 of the suite's tests (every
  one that spawns) fail there; run the full suite on the host.
- Run tools by install path in the sandbox: `mise x` EPERMs in an untrusted
  worktree, mix 1.18 dies on its TCP lock (1.20 only warns; set
  `MIX_OS_CONCURRENCY_LOCK=0`), and `~/.mix` is unwritable (point `MIX_HOME`
  under `$TMPDIR`, rebar3 copied in).
- `Origin` is compared with `Host`, so DNS rebinding is outside the check.

## Next

1. Reaped sessions: verify on the host that `Pty.reap/1` leaves attached
   sockets open with no `{:pty_exit, _}`, then fix and pin it with a test.
2. Coverage gate: `mix test --cover` thresholds at 90 %; the house bar is 100.
3. No CI and no pre-push hook yet.
