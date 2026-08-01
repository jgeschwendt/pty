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
// Server → client frames are binary PTY output, written straight through.
// Client → server frames are JSON: {t:"i",d} for input, {t:"r",cols,rows} for
// resize. OSC 0/2 (title) surfaces as the onTitle callback rather than a
// document.title write — an embedded rail must not rename its host page. OSC 52
// (clipboard) is xterm's ClipboardAddon, loaded only if the host passes it.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.Pty = factory();
})(typeof self !== "undefined" ? self : this, function () {
  var RECONNECT_BASE_MS = 1000;
  var RECONNECT_MAX_MS = 15000;
  var WS_CLOSE_NORMAL = 1000;

  var DEFAULT_TERMINAL_OPTIONS = {
    allowProposedApi: true, // required by the unicode11 addon
    cursorBlink: true,
    fontFamily:
      "Menlo, Monaco, 'DejaVu Sans Mono', 'Cascadia Mono', Consolas, 'Courier New', monospace",
    fontSize: 13,
    macOptionIsMeta: true,
    scrollback: 5000,
  };

  // "/pty?s=x" → "ws://host/pty?s=x"; an absolute ws(s):// url passes through.
  function socketUrl(url) {
    if (/^wss?:/.test(url)) return url;
    var resolved = new URL(url, location.href);
    resolved.protocol = resolved.protocol === "https:" ? "wss:" : "ws:";
    return resolved.href;
  }

  /**
   * Wire an existing xterm.js Terminal to a session's websocket.
   *
   * Options: onTitle(title), onOpen(), onClose(event), onExit(event) — fired
   * once when the child process itself exited, so the caller can tear the view
   * down instead of waiting for a reconnect that will never help; reconnect
   * (default true).
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

    function send(msg) {
      if (socket && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(msg));
    }

    function sendDims() {
      send({ t: "r", cols: term.cols, rows: term.rows });
    }

    function open() {
      socket = new WebSocket(target);
      socket.binaryType = "arraybuffer";

      socket.onopen = function () {
        delay = RECONNECT_BASE_MS;
        // The session replays its scrollback as the first frames; reset so a
        // reconnect redraws rather than appending to a stale screen.
        term.reset();
        sendDims();
        if (opts.onOpen) opts.onOpen();
      };

      socket.onmessage = function (event) {
        term.write(new Uint8Array(event.data));
      };

      socket.onclose = function (event) {
        if (opts.onClose) opts.onClose(event);
        if (closed) return;

        // 1000 is the child exiting — the session is gone, so reconnecting
        // would silently spawn a NEW terminal. Anything else is transport loss.
        if (event.code === WS_CLOSE_NORMAL) {
          if (opts.onExit) opts.onExit(event);
          return;
        }

        if (!reconnect) return;
        timer = setTimeout(open, delay);
        delay = Math.min(delay * 2, RECONNECT_MAX_MS);
      };
    }

    term.onData(function (data) {
      send({ t: "i", d: data });
    });
    term.onResize(sendDims);
    if (opts.onTitle) term.onTitleChange(opts.onTitle);

    open();

    return {
      send: send,
      sendDims: sendDims,
      close: function () {
        closed = true;
        clearTimeout(timer);
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
