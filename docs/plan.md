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
  a reap or crash); a session's death, however abrupt, takes its child — the
  erlexec link stops it: SIGHUP, then SIGKILL to the group after 2 s.
- `start/2` is idempotent and fail-closed on a missing binary or cwd, resolved
  as the child would (`:cwd`, `:env` PATH).
- A bad client frame is `:ignore`, never a crashed session.
- The first server frame is the scrollback, even empty: the attach signal.
  `pty.js` resets backoff only then, and every reconnect is `?reattach` —
  attach-only. Close `1000` = session ended, `4404` = reattach found none;
  `pty.js` stops on both, anything else reconnects.
- A cross-origin browser upgrade is refused unless `:check_origin` admits it.

## Hazards

- In the shift sandbox: `mise trust` the worktree, copy `deps/` from main,
  compile with `MIX_OS_CONCURRENCY_LOCK=0`, and run the suite as exactly
  `shift-test mise x -C . -- mix test --cover` (its profile allows
  `/dev/ptmx`; anything spliced in between breaks the exclusion).
- erlexec reports status `0` for any child it was asked to stop, racing the
  signal's own status — hence the fixed `129` for a reap.
- `Origin` is compared with `Host`, so DNS rebinding is outside the check.

## Next

1. No CI and no pre-push hook yet.
2. `pty.js` has no behavioural test — `asset_test` only greps it.
3. `list/0` drops a session busy past the 1 s info timeout; `reap_all/0`
   reaps sequentially, so N HUP-ignoring children take 2 N s.
