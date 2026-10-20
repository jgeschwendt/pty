# pty

## Map

| where | what |
| --- | --- |
| .github/workflows/ci.yaml | the `check` job — the required status on main; renaming it stalls every PR and the merge queue |
| docs/ | the design — `index.html` (GitHub Pages, proxied at https://gigantic.dev/pty/): invariants, close codes, hazards, the shift's Next list; `figures/` the PNGs (each with a `-dark` twin), `figures/project/` the Claude Design canvas `pty figures`, `figures/export.sh` behind `mise run figures` |
| hk.pkl | pre-push gate, what CI runs; `hk install --mise` per clone |
| lib/pty.ex | the facade — the whole public API; every call takes a session as id or pid |
| lib/pty/ | `session.ex` the `GenServer` owning one PTY, `client.ex` the transport contract + frame decoder, `socket.ex` the `WebSock` handler, `plug.ex` the upgrade gate, `application.ex` the registry + `DynamicSupervisor` |
| priv/static/pty.js | browser glue; the host hands xterm.js in |
| test/ | ExUnit over real `cat`/`sh` PTYs, no mocks; `test/js/` drives `pty.js` unmodified against hand-written fakes (no `bun install`) |

## Working here

- Gate: `mise install`, `mix deps.get`, then `mix format --check-formatted && mix compile --warnings-as-errors && mix test --cover && bun test --coverage` — `--cover` enforces the 100 % threshold, plain `mix test` does not.
- Install in a host: `{:pty, github: "jgeschwendt/pty"}`. `:pty` is a library application — it starts the registry and the session supervisor itself; the host adds nothing to its tree, and serves nothing it did not mount.
- API (`Pty`): `new_id/0` (url-safe, 12 chars), `valid_id?/1`, `start/2` (idempotent: the live session, or a new one), `lookup/1`, `attach/2` (returns the scrollback to replay first; subscriber defaults to `self()`), `detach/2`, `write/2`, `resize/3`, `info/1` + `list/0` (id, command, `started` unix s, subscribers, buffer bytes, cols, rows), `reap/1` + `reap_all/0`, `asset_dir/0`. Subscribers receive `{:pty_data, bytes}`, once `{:pty_exit, code}`, or `{:pty_lagged}` — attach again to resync.
- Spawn options `:command`, `:args`, `:cwd`, `:env`, `:cols`, `:rows`, `:scrollback` (256 KB, chunk-aligned), `:max_lag` (1 000, positive integer) resolve option › application env › OS env (`PTY_CMD`, `PTY_ARGS`, `PTY_CWD`) › default, and apply only when `start/2` actually starts. `:env` (map or pairs) layers over the environment erlexec snapshotted at boot — a later `System.put_env/2` never reaches a session — and `false` unsets.
- `Pty.Plug` options: `session_opts:`, `:check_origin` (`true` compares host only, as Phoenix — a proxy must forward `Host`; an exact origin list is stricter and the right choice on loopback, where every port shares the host; `false`), idle `:timeout` (90 s), kept above `Pty.Socket`'s `:ping_interval` (30 s).
- Phoenix host: `plug Plug.Static, at: "/pty", from: {:pty, "priv/static"}` in the endpoint; `get "/pty", Pty.Plug, session_opts: [command: "claude"]` behind the authenticated pipeline, in one that neither parses bodies nor guards JSON mutations. A LiveView hook imports `deps/pty/priv/static/pty.js`, calls `Pty.mount(el, "/pty?s=" + id, {xterm: {Terminal, FitAddon}, onTitle})` in `mounted` and `dispose()` in `destroyed`; the element needs `phx-update="ignore"`. Under `script-src 'self'` bundle xterm.js, never a CDN.
- Injecting proxy host: match the terminal route (`Pty.Plug.init/1` + `call/2`, then `halt`) before the proxy's own WebSocket passthrough, or the upgrade is forwarded to the proxied app; give the rail no `onTitle`. An escript carries no `priv/` — embed `pty.js` and xterm's files from `Pty.asset_dir()` at compile time.
- `pty.js`: `Pty.mount(el, url, {xterm, onTitle, onExit})` → `dispose()` detaches, the PTY keeps running; `Terminal` is the only required piece, each addon used if present (`ClipboardAddon` makes OSC 52 writes work). `Pty.connect(term, url, opts)` wires a Terminal you built — load its `ClipboardAddon` first so the read guard runs ahead of it; `close()` unwires everything.
- Sessions accumulate: one per minted id until its child exits or it is reaped. A host minting per page load sweeps `Pty.list/0` for zero `subscribers` past its TTL.
- `Pty.Client.handle/2` is the frame decoder, so a LiveView or a Channel can carry the wire protocol without `Pty.Socket`.
