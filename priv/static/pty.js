// pty browser glue — the client half of Pty.Socket's wire protocol.
//
// Framework-free and dependency-light by design: it never imports xterm.js. The
// host loads xterm however it already loads JS (bundler, <script>, import map)
// and hands the constructors in, so a Phoenix bundle and a script tag injected
// into someone else's page can share one file.
//
//   Pty.mount(el, "/pty?s=" + id, { xterm: { Terminal, FitAddon } })
//   Pty.connect(existingTerminal, "/pty?s=" + id)
//
// Server → client frames are binary PTY output, written straight through; the
// first is the scrollback, and marks the socket attached. Every reconnect asks
// with ?reattach, so a session that ended while away closes 4404 instead of
// being silently respawned under the old id; a refused spawn closes 4422.
// Client → server frames are JSON: {t:"i",d} for input, {t:"b",d} for raw
// bytes (one per char 0–255), {t:"r",cols,rows} for resize. OSC 0/2 (title) surfaces as the onTitle callback rather than a
// document.title write — an embedded rail must not rename its host page. OSC 52
// (clipboard) is xterm's ClipboardAddon, loaded only if the host passes it, and
// write-only: a read would hand the viewer's clipboard to the shell, so connect()
// swallows reads ahead of any clipboard handler registered before it.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.Pty = factory();
})(typeof self !== "undefined" ? self : this, function () {
  var RECONNECT_BASE_MS = 1000;
  var RECONNECT_MAX_MS = 15000;
  // Closes after which there is nothing to come back to: 4000 the session
  // ended, 4404 it ended while we were away, 4422 it could never start. Every
  // other code — 1000 included, which Bandit sends on its own shutdown — is
  // transport loss.
  var FINAL_CLOSE_CODES = [4000, 4404, 4422];
  // CAN, then RIS (ESC c). Written in-band rather than term.reset(), which
  // leaves xterm's parser mid-sequence — a frame the old socket cut inside an
  // OSC would swallow the scrollback — and runs ahead of writes still queued.
  var RESET = new Uint8Array([0x18, 0x1b, 0x63]);

  var DEFAULT_TERMINAL_OPTIONS = {
    allowProposedApi: true, // required by the unicode11 addon
    cursorBlink: true,
    fontFamily:
      "Menlo, Monaco, 'DejaVu Sans Mono', 'Cascadia Mono', Consolas, 'Courier New', monospace",
    fontSize: 13,
    macOptionIsMeta: true,
    scrollback: 5000,
  };

  // "/pty?s=x" → "ws://host/pty?s=x", http(s) → ws(s); an absolute ws(s):// url,
  // in any case, passes through without touching `location`. A URL object, so
  // a reconnect can add ?reattach.
  function socketUrl(url) {
    if (/^wss?:/i.test(url)) return new URL(url);
    var resolved = new URL(url, location.href);
    resolved.protocol = resolved.protocol === "https:" ? "wss:" : "ws:";
    return resolved;
  }

  /**
   * Wire an existing xterm.js Terminal to a session's websocket.
   *
   * Options: onTitle(title), onOpen() — fired on each attach, once the
   * scrollback arrives — onClose(event), onExit(event) — fired once when the
   * session ended, so the caller can tear the view down instead of waiting for
   * a reconnect that will never help; reconnect (default true).
   *
   * Returns a handle: { send(msg), sendDims(), close(), get socket() }.
   */
  function connect(term, url, options) {
    var opts = options || {};
    var reconnect = opts.reconnect !== false;
    var target = socketUrl(url);
    var delay = RECONNECT_BASE_MS;
    var socket = null;
    var closed = false;
    var timer = null;
    var attached = false;

    function send(msg) {
      if (socket && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(msg));
    }

    function sendDims() {
      send({ t: "r", cols: term.cols, rows: term.rows });
    }

    function open() {
      var fresh = true;
      // Once attached, never spawn again: a reconnect only reattaches.
      if (attached) target.searchParams.set("reattach", "1");
      socket = new WebSocket(target);
      socket.binaryType = "arraybuffer";

      socket.onmessage = function (event) {
        // The first frame is the scrollback: only now is the socket attached —
        // an upgrade the server then refuses opens too. Reset so a reconnect
        // redraws rather than appending to a stale screen, and back off afresh.
        if (fresh) {
          fresh = false;
          attached = true;
          delay = RECONNECT_BASE_MS;
          term.write(RESET);
          sendDims();
          if (opts.onOpen) opts.onOpen();
        }
        term.write(new Uint8Array(event.data));
      };

      socket.onclose = function (event) {
        if (opts.onClose) opts.onClose(event);
        if (closed) return;

        if (FINAL_CLOSE_CODES.indexOf(event.code) !== -1) {
          if (opts.onExit) opts.onExit(event);
          return;
        }

        if (!reconnect) return;
        timer = setTimeout(open, delay);
        delay = Math.min(delay * 2, RECONNECT_MAX_MS);
      };
    }

    // Disposed on close, so a host-built terminal reconnected later does not
    // carry this connection's listeners too.
    var listeners = [
      term.onData(function (data) {
        send({ t: "i", d: data });
      }),
      // X10-encoded mouse reports come only here: bytes, one per char.
      term.onBinary(function (data) {
        send({ t: "b", d: data });
      }),
      term.onResize(sendDims),
      // An OSC 52 read ("52;c;?") answers with the viewer's clipboard as input
      // to the shell — in a shared session, any attached user's. Swallowed here,
      // not in mount(), so a host's own ClipboardAddon is covered too: the most
      // recent handler is tried first, so writes still fall through to an addon
      // loaded before connect(), whatever its provider or version.
      term.parser.registerOscHandler(52, function (data) {
        return data.split(";")[1] === "?";
      }),
    ];
    if (opts.onTitle) listeners.push(term.onTitleChange(opts.onTitle));

    open();

    return {
      send: send,
      sendDims: sendDims,
      close: function () {
        closed = true;
        clearTimeout(timer);
        listeners.forEach(function (listener) {
          listener.dispose();
        });
        if (socket) socket.close();
      },
      get socket() {
        return socket;
      },
    };
  }

  /**
   * Build a Terminal into `element` and connect it.
   *
   * `opts.xterm` carries the host's xterm.js pieces: { Terminal } is required,
   * { FitAddon, ClipboardAddon, Unicode11Addon, WebglAddon } are each used if
   * present. `opts.terminal` overrides the Terminal constructor options.
   *
   * Returns the `connect` handle plus { term, fit(), dispose() }. Call
   * dispose() when unmounting — detaching the client leaves the PTY running.
   */
  function mount(element, url, options) {
    var opts = options || {};
    var xterm = opts.xterm || {};
    if (!xterm.Terminal) throw new Error("Pty.mount: opts.xterm.Terminal is required");

    var settings = Object.assign({}, DEFAULT_TERMINAL_OPTIONS, opts.terminal || {});
    var term = new xterm.Terminal(settings);
    var fitAddon = xterm.FitAddon ? new xterm.FitAddon() : null;

    if (fitAddon) term.loadAddon(fitAddon);
    term.open(element);

    if (xterm.Unicode11Addon) {
      term.loadAddon(new xterm.Unicode11Addon());
      term.unicode.activeVersion = "11";
    }
    // Before connect(), which registers the OSC 52 read guard after it.
    if (xterm.ClipboardAddon) term.loadAddon(new xterm.ClipboardAddon());
    if (xterm.WebglAddon) {
      try {
        var webgl = new xterm.WebglAddon();
        webgl.onContextLoss(function () {
          webgl.dispose();
        });
        term.loadAddon(webgl);
      } catch (_error) {
        // No WebGL (or a headless canvas) — the DOM renderer stays.
      }
    }

    function fit() {
      if (fitAddon) fitAddon.fit();
    }

    fit();

    // ResizeObserver catches the rail being dragged, a pane split, a hidden tab
    // revealed — none of which fire a window resize.
    var observer = null;
    if (typeof ResizeObserver !== "undefined") {
      var frame = null;
      observer = new ResizeObserver(function () {
        cancelAnimationFrame(frame);
        frame = requestAnimationFrame(fit);
      });
      observer.observe(element);
    }

    var handle = connect(term, url, opts);

    return Object.assign(handle, {
      term: term,
      fit: fit,
      dispose: function () {
        if (observer) observer.disconnect();
        handle.close();
        term.dispose();
      },
    });
  }

  return { connect: connect, mount: mount };
});
