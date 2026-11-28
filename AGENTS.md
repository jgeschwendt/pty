# pty

```stele
kind: system
purpose: pty — embeddable PTY sessions for Elixir hosts; a session owns its PTY through erlexec and outlives every client
commands:
  check: mise run check
edges:
  allow:
    - edge: lib
      reason: "mix.exs names the application module and the doc groups"
invariants:
  - claim: a bad client frame decodes to `:ignore`, never a crashed session
    anchor: ※ bad-frame-ignored
  - claim: a cross-origin browser upgrade is refused unless `:check_origin` admits it
    anchor: ※ origin-refused
  - claim: reaps stop the session directly, never through the supervisor, so a slow hangup never blocks `start/2`
    anchor: ※ reap-unsupervised
```

The design is `docs/index.html` — the only design source.

<!-- @stele -->

## Hazards (0 active)


## Map

| node    | kind      | purpose                                                                                                     | unfold                                               |
| ------- | --------- | ----------------------------------------------------------------------------------------------------------- | ---------------------------------------------------- |
| .github | container | CI wiring — ci.yaml's check job (format, compile, mix and bun tests) and the stele job                      | `stele unfold .github` · or read `.github/AGENTS.md` |
| docs    | container | the design — index.html (GitHub Pages) is the only design source; page.css holds only what is pty's         | `stele unfold docs` · or read `docs/AGENTS.md`       |
| lib     | container | the Elixir library — the Pty facade, Session (one GenServer per PTY), Client frame decoder, Socket and Plug | `stele unfold lib` · or read `lib/AGENTS.md`         |
| priv    | container | static/pty.js — the browser glue; the host hands xterm.js in                                                | `stele unfold priv` · or read `priv/AGENTS.md`       |
| test    | container | ExUnit over real cat/sh PTYs, no mocks; js/ drives pty.js under bun test against hand-written fakes         | `stele unfold test` · or read `test/AGENTS.md`       |

## Indexes

All invariants: `.stele/index/invariants.md` · all hazards: `.stele/index/hazards.md`

## Engine

`stele` CLI available → `stele root | unfold <id> | invariants --touching <path> | hazards | nodes --kind <k>`. MCP: `stele serve`.
No engine → everything above is complete; nested AGENTS.md files carry the detail (nearest file wins).
<!-- @end -->
