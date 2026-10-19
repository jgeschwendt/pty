# Pty

A **PTY session engine for embedding terminals in Elixir apps**. Add it to your
deps, mount one plug, load one JS file — and your app has a real terminal
(`claude`, a shell, anything) in the browser, over a real PTY (via [erlexec]).

The point is the process model, not the page: **a session owns the PTY and
outlives every connection**. Closing the tab, refreshing, or dropping the
network detaches a client; the program keeps running. Reattaching by session id
replays scrollback and rejoins the *same live process*, and several clients can
attach to one id at once (shared, multiplexed terminal).

The library serves nothing itself — no endpoint, no auth, no page. The host owns
all three.

Design, invariants and plan: [`docs/index.html`](https://gigantic.dev/pty/).

## Architecture

```
                               ┌─ SessionRegistry (id → pid) ─┐
xterm.js ─ws─► your endpoint ─► Pty.Plug ─► Pty.Socket ─attach─► Session ─erlexec─► claude
   ▲  raw bytes                  (your auth)  (a client) ◄─feed── (owns PTY,        (fork + PTY)
   └─────────────── PTY output ◄─────────────────────────────────  scrollback buffer)
```

| Module        | Role                                                                   |
| ------------- | ---------------------------------------------------------------------- |
| `Pty`         | The public API. Everything below is reachable through it.              |
| `Pty.Session` | `GenServer` owning one PTY: fan-out to subscribers, scrollback, resize. |
| `Pty.Client`  | The transport-agnostic contract, plus the shared frame decoder.         |
| `Pty.Socket`  | `WebSock` handler bridging one websocket to a session.                  |
| `Pty.Plug`    | Mounts that handler on a host endpoint (id and origin checks, upgrade). |

`:pty` is a library application: adding it to your deps starts the session
registry and the session `DynamicSupervisor`, and nothing else. You do not add
it to your own supervision tree.

The PTY layer runs **out-of-process**: erlexec drives a separate `exec-port`
daemon rather than an in-BEAM NIF, so a crash in native PTY handling takes down
one OS child, never the host's whole VM.

## Install

```elixir
# mix.exs
{:pty, github: "jgeschwendt/pty"}
```

## API

```elixir
id = Pty.new_id()                        # url-safe, 12 chars
{:ok, session} = Pty.start(id, command: "claude", cwd: "/repo")
{:ok, scrollback} = Pty.attach(session)  # subscriber defaults to self()
Pty.write(session, "ls\n")
Pty.resize(session, 120, 40)
# receive {:pty_data, bytes} … and once, {:pty_exit, code} (none if killed outright)
Pty.detach(session)                      # PTY keeps running
Pty.reap(id)                             # hang the child up, end the session
```

| Function               | Does                                                             |
| ---------------------- | ---------------------------------------------------------------- |
| `new_id/0`             | Mint a fresh url-safe session id.                                 |
| `valid_id?/1`          | Is this id safe to route and log?                                 |
| `start/2`              | Start the session for an id, or return the live one. Idempotent.  |
| `lookup/1`             | `{:ok, pid}` for a live id, else `:error`.                        |
| `attach/2`             | Subscribe to the feed; returns the scrollback to replay first.    |
| `detach/2`             | Unsubscribe. The PTY is untouched.                                |
| `write/2`              | Write to the PTY's stdin.                                         |
| `resize/3`             | Resize the PTY (SIGWINCH to the child).                           |
| `info/1`, `list/0`     | Metadata: command, uptime, subscribers, buffer size, dimensions.  |
| `reap/1`, `reap_all/0` | End sessions by hanging up (see Notes); `reap_all` concurrently.  |
| `asset_dir/0`          | Where `pty.js` lives, for `Plug.Static` or a copy step.           |

Every function takes a session as an **id** or a **pid**; an id naming no live
session is `{:error, :not_found}`. Spawn options (`:command`, `:args`, `:cwd`,
`:cols`, `:rows`, `:scrollback`) resolve as **option › application env › OS env
(`PTY_CMD`, `PTY_ARGS`, `PTY_CWD`) › default**, and apply only when `start/2`
actually starts something. `start/2` is fail-closed: erlexec launches its child
asynchronously, so `:command` is resolved up front as the child would resolve
it — a path against `:cwd`, a bare name on the `PATH` in `:env` or inherited —
and a missing binary or `:cwd` is `{:error, _}` rather than a live pid over a
dead PTY.

### Wire protocol

Client sends JSON text frames; server sends binary output, the scrollback
first (even empty — it is the "attached" signal):

- `{"t":"i","d":"<keys>"}` — keyboard input → PTY stdin
- `{"t":"r","cols":C,"rows":R}` — resize

The server closes `4000` when the session ends, `4404` when a reconnect
(`?reattach`) finds no session, `4422` when the spawn is refused (an invalid
id, `:command` or `:cwd` not found, or erlexec rejecting an option such as a
bad `:cols` — permanent), and `1011` for any other start failure, retried because pty cannot
tell a passing failure (resources) from a fault (an option that crashes init);
the host's logs show which. `1000` is never the session's: Bandit
sends it on its own shutdown, so a client treats it as transport loss.

Malformed frames (bad JSON, unknown type, out-of-range or non-integer
dimensions) are ignored at the boundary rather than crashing the session.
`Pty.Client.handle/2` is that decoder, so a LiveView or a Phoenix Channel can
carry the same protocol without `Pty.Socket`.

### Browser glue

`priv/static/pty.js` never imports xterm.js — the host hands it in, so a
bundled Phoenix page and a script injected into someone else's document can
share one file.

```js
const term = Pty.mount(el, `/pty?s=${id}`, {
  xterm: { Terminal, FitAddon, ClipboardAddon, Unicode11Addon, WebglAddon },
  onTitle: (t) => (document.title = t),   // OSC 0/2; omit inside an embedded rail
  onExit: () => el.classList.add("dead"),
});
term.dispose();  // unmount: detaches the client, the PTY keeps running
```

`Terminal` is the only required piece; each addon is used if present
(`ClipboardAddon` is what makes OSC 52 clipboard writes work; OSC 52 *reads*
are swallowed, since the reply would hand the viewer's clipboard to the shell
and so to everyone attached to the session). It reconnects
with exponential backoff on transport loss — reset only once a socket is
attached, so a refused upgrade backs off instead of hammering — and every
reconnect is attach-only: a session that ended while the client was away
closes `4404` rather than respawning under the old id. `4000`, `4404` and
`4422` stop it and fire `onExit`; every other close, `1000` included, reconnects.
`Pty.connect(term, url, opts)` wires a Terminal you built yourself.

## Integrating

### A terminal page in Phoenix (LiveView)

```elixir
# lib/my_app_web/endpoint.ex — beside the existing /assets line
plug Plug.Static, at: "/pty", from: {:pty, "priv/static"}

# lib/my_app_web/router.ex
scope "/" do
  pipe_through :browser              # your auth belongs here — see Security
  live "/terminal", TerminalLive
  get "/pty", Pty.Plug, session_opts: [command: "claude"]
end
```

```js
// assets/js/hooks/terminal.js — a LiveView hook, registered in app.js
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import Pty from "../../../deps/pty/priv/static/pty.js";
import "@xterm/xterm/css/xterm.css";

export const TerminalHook = {
  mounted() {
    this.session = Pty.mount(this.el, `/pty?s=${this.el.dataset.session}`, {
      xterm: { Terminal, FitAddon },
      onTitle: (t) => (document.title = t),
    });
  },
  destroyed() { this.session.dispose(); },
};
```

The LiveView mints the id (`Pty.new_id()`), keeps it in its assigns, and
renders `<div id="term" phx-hook="TerminalHook" phx-update="ignore"
data-session={@session}>`. `phx-update="ignore"` is load-bearing: LiveView must
not diff xterm's DOM.

Under a strict CSP (`script-src 'self'`), bundle xterm.js with your own asset
pipeline rather than pulling it from a CDN — the websocket itself is
same-origin and already allowed by `connect-src 'self'`. And mount the `/pty`
route in a pipeline that does not parse bodies or guard JSON mutations; it is
an upgrade, not an API call.

### A terminal rail in an injecting reverse proxy

A dev proxy that injects an overlay script into proxied pages can grow a
terminal rail. The terminal route must be matched **before** the proxy's own
WebSocket passthrough — otherwise the upgrade is forwarded to the app being
proxied.

```elixir
# the proxy's endpoint — plug order is load-bearing
plug Plug.Static, at: "/__proxy/assets", from: {MyProxy, :assets_dir, []}
plug :terminal
plug MyProxy.WS       # WebSocket passthrough to the proxied app
plug MyProxy.HTTP     # catch-all forward

defp terminal(%{request_path: "/__proxy/pty"} = conn, _opts) do
  opts = Pty.Plug.init(session_opts: [cwd: File.cwd!()])
  conn |> Pty.Plug.call(opts) |> halt()
end

defp terminal(conn, _opts), do: conn
```

The injected overlay grows a rail and mounts the terminal into it:

```js
var rail = document.createElement("div");
Object.assign(rail.style, { bottom: 0, height: "40vh", position: "fixed" /* … */ });
document.body.appendChild(rail);
Pty.mount(rail, "/__proxy/pty?s=" + sessionId, { xterm: { Terminal, FitAddon } });
// no onTitle — the rail must not rename the page it is injected into
```

Two proxy specifics. If the proxy ships as an escript, it carries no `priv/` —
embed `pty.js` (and xterm's own files) at compile time, reading them from
`Pty.asset_dir()`, and materialize them next to the overlay's own assets.
And the injected script is same-origin, so a proxied app's `script-src 'self'`
and `style-src 'self'` both still pass; keep loading xterm from the proxy's
own asset mount, never a CDN.

## Security

The library ships **no authentication**. A reachable session is a shell or
`claude` running as your user — remote code execution by design. The host gates
the route that mounts `Pty.Plug` (an authenticated browser pipeline, or a
loopback-only bind), and anything beyond loopback belongs behind TLS.

A WebSocket handshake escapes CORS, so `Pty.Plug` refuses (`403`) a browser
`Origin` whose host is not the request's own — otherwise any page on another
site could open a terminal on a loopback-only host. `:check_origin` takes
`true` (default), an exact origin list, or `false`. The default compares host
only (as Phoenix does), so a proxy in front must forward `Host`, and on
loopback, where every local port shares the host, a list
(`["http://localhost:4000"]`) is the stricter choice. A page on another host
that connects with an absolute `ws(s)://` url needs its origin listed. Nor can
a `Host` comparison stop DNS rebinding: a loopback host reachable by name
should also pin the `Host` it answers to.

Session ids are unguessable and validated (`[\w-]{1,64}`) before they reach a
log or the registry, but an id is a name, not a credential.

## Notes

- **Sessions accumulate.** One per id you mint, alive until its child exits or
  you `reap/1` it. A host that mints an id per page load wants an idle sweep:
  `Pty.list/0` reports `subscribers` and `started` — reap what has had zero
  subscribers for your TTL. A client that vanished without closing (lid shut,
  network dropped) leaves that count too: `Pty.Socket` pings every
  `:ping_interval` (30 s), and `Pty.Plug`'s idle `:timeout` (90 s; keep it
  above the interval) closes a socket that stops answering. A live browser
  answers by itself, so a terminal whose human is only thinking stays open.
- **Scrollback is raw bytes**: a bounded deque of output chunks (`:scrollback`,
  256 KB default, chunk-aligned; a single chunk over the cap keeps its tail).
  Replay redraws a full-screen TUI correctly in practice but is not a VT
  snapshot; for exactness, parse terminal state server-side and redraw from
  that.
- **Reaping hangs up**: SIGHUP, the signal a real terminal sends when its
  window closes (interactive shells ignore SIGTERM). A child still alive 2 s
  later gets SIGTERM, then SIGKILL 1 s after, both to its process group.
  Whatever it prints on the way out still reaches subscribers, then
  `{:pty_exit, 129}`; `reap/1` returns once the child is gone, but the id is
  free from the start — a `start/2` meanwhile gets a fresh session. erlexec links
  each child to its session, so even a session killed outright takes its child
  along — no orphaned PTYs. A reap in a child's first instant, before it has
  exec'd, can miss the hangup and take the escalation path.

## Development

```sh
mise install          # bun + elixir + erlang, pinned in mise.toml
mix deps.get
mix test
bun test --coverage   # pty.js
```

Sessions in the suite spawn `cat` and `sh` over real PTYs — no mocks, no server.
`pty.js` runs unmodified against hand-written fakes of the WebSocket, the
timers and xterm.js, so the JS suite needs no `bun install`.

[erlexec]: https://hex.pm/packages/erlexec
