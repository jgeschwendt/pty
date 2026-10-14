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
- Every session end reaches subscribers as one `{:pty_exit, code}` (`129` for
  a reap or crash). A reap SIGHUPs, relays the child's last output, and after
  2 s lets erlexec stop it (SIGTERM, SIGKILL 1 s on, to the group); a
  session's death, however abrupt, takes its child through the erlexec link.
- Reaps never go through the supervisor (`GenServer.stop`), so a slow hangup
  never blocks `start/2`; `reap_all/0` hangs up concurrently.
- `start/2` is idempotent and fail-closed on a missing binary or cwd, resolved
  as the child would (`:cwd`, `:env` PATH).
- A bad client frame is `:ignore`, never a crashed session.
- The first server frame is the scrollback, even empty: the attach signal.
  `pty.js` resets backoff only then, and every reconnect is `?reattach` —
  attach-only. Close `4000` = session ended, `4404` = reattach found none,
  `4422` = spawn refused; `pty.js` stops on those three, anything else —
  Bandit's own shutdown `1000` included — reconnects.
- A cross-origin browser upgrade is refused unless `:check_origin` admits it.

## Hazards

- In the shift sandbox: `mise trust` the worktree, copy `deps/` from main,
  compile with `MIX_OS_CONCURRENCY_LOCK=0`, and run the suite as exactly
  `shift-test mise x -C . -- mix test --cover` (its profile allows
  `/dev/ptmx`; anything spliced in between breaks the exclusion).
- erlexec reports status `0` for any child it was asked to stop, racing the
  signal's own status — hence the fixed `129` for a reap.
- exec-port's SIGHUP handler survives in a fork until `execve`: a reap within
  a child's first milliseconds misses the hangup and waits out the 2 s grace.
  Tests clean up with `drop/1` (outright kill) for that reason. The hangup is
  deliberately not re-sent: a second HUP may cut short a child's own cleanup.
- erlexec runs a `{:kill, cmd}` under the BEAM's `$SHELL -c`, so a kill
  command is non-portable (nushell); the hangup is sent by `:exec.kill/2`.
- `Origin` is compared with `Host`, so DNS rebinding is outside the check.

## Next

1. `pty.js` has no behavioural test — `asset_test` only greps it.
2. `list/0` drops a session busy past the 1 s info timeout.
