// Drives priv/static/pty.js, loaded unmodified, against hand-written fakes:
// the WebSocket, the timers and the host's xterm.js pieces.
import { beforeEach, expect, test } from "bun:test";

const Pty = require("../../priv/static/pty.js");

let observers, sockets, timers;

class WebSocket {
  static OPEN = 1;
  readyState = WebSocket.OPEN;
  sent = [];
  constructor(url) {
    this.url = String(url);
    sockets.push(this);
  }
  close() {
    this.closed = true;
  }
  send(frame) {
    this.sent.push(JSON.parse(frame));
  }
}

class Terminal {
  cols = 80;
  log = [];
  on = {};
  osc = [];
  parser = {
    registerOscHandler: (_id, fn) => (this.osc.push(fn), { dispose: () => this.osc.splice(this.osc.indexOf(fn), 1) }),
  };
  rows = 24;
  unicode = {};
  constructor(settings) {
    this.settings = settings;
    for (const name of ["onBinary", "onData", "onResize", "onTitleChange"])
      this[name] = (fn) => ((this.on[name] = fn), { dispose: () => delete this.on[name] });
    for (const name of ["dispose", "loadAddon", "open", "write"])
      this[name] = (arg) => this.log.push(arg === undefined ? name : [name, arg]);
    this.loadAddon = (addon) => (this.log.push(["loadAddon", addon]), addon.activate?.(this));
  }
}

// An addon class whose instances log into `log` under `name`.
const addon = (log, name, extra) =>
  class {
    constructor() {
      log.push(name);
      Object.assign(this, extra?.(this));
    }
  };

Object.assign(globalThis, {
  ResizeObserver: class {
    constructor(fn) {
      this.fn = fn;
      observers.push(this);
    }
    disconnect() {
      this.disconnected = true;
    }
    observe(el) {
      this.el = el;
    }
  },
  WebSocket,
  cancelAnimationFrame: () => {},
  clearTimeout: (t) => t && (t.cleared = true),
  location: {},
  requestAnimationFrame: (fn) => fn(),
  setTimeout: (fn, ms) => timers[timers.push({ fn, ms }) - 1],
});

beforeEach(() => {
  location.href = "https://example.test/app/page";
  observers = [];
  sockets = [];
  timers = [];
});

const frame = (socket, ...bytes) => socket.onmessage({ data: new Uint8Array(bytes).buffer });
const last = () => sockets.at(-1);
const names = (term) => term.log.map((entry) => [entry].flat()[0]);

test("socketUrl: http(s) maps to ws(s), relative to the page; ws(s) passes through", () => {
  Pty.connect(new Terminal(), "/pty?s=a");
  location.href = "http://example.test/";
  for (const url of ["pty?s=b", "HTTPS://other.test/pty", "ws://other.test/pty", "WSS://other.test/pty"])
    Pty.connect(new Terminal(), url);
  expect(sockets.map((s) => s.url)).toEqual([
    "wss://example.test/pty?s=a",
    "ws://example.test/pty?s=b",
    "wss://other.test/pty",
    "ws://other.test/pty",
    "wss://other.test/pty",
  ]);
  expect(sockets[0].binaryType).toBe("arraybuffer");
});

// The reset is in-band: CAN aborts whatever sequence a cut frame left open,
// then RIS (ESC c). term.reset() would leave xterm's parser mid-sequence.
test("the first frame attaches: an in-band reset, dims, onOpen, then writes through", () => {
  const term = new Terminal();
  let opened = 0;
  const handle = Pty.connect(term, "/pty", { onOpen: () => opened++ });
  expect(handle.socket).toBe(last());
  frame(last(), 104, 105);
  frame(last(), 33);
  expect(term.log.map((entry) => [...entry[1]])).toEqual([[0x18, 0x1b, 0x63], [104, 105], [33]]);
  expect(last().sent).toEqual([{ t: "r", cols: 80, rows: 24 }]);
  expect(opened).toBe(1);
});

test("input, resize and title travel; nothing is sent on a socket not open", () => {
  const term = new Terminal();
  const titles = [];
  const handle = Pty.connect(term, "/pty", { onTitle: (t) => titles.push(t) });
  term.on.onData("ls\r");
  term.on.onBinary("\x1b[M \xff\x80");
  term.cols = 120;
  term.on.onResize();
  handle.send({ t: "x" });
  term.on.onTitleChange("vim");
  last().readyState = 3;
  term.on.onData("lost");
  expect(last().sent).toEqual([
    { t: "i", d: "ls\r" },
    { t: "b", d: "\x1b[M \xff\x80" },
    { t: "r", cols: 120, rows: 24 },
    { t: "x" },
  ]);
  expect(titles).toEqual(["vim"]);
  const untitled = new Terminal();
  Pty.connect(untitled, "/pty");
  expect(Object.keys(untitled.on)).toEqual(["onData", "onBinary", "onResize"]);
});

test("transport loss backs off 1 s → 15 s; an attach resets it and reattaches", () => {
  const closes = [];
  Pty.connect(new Terminal(), "/pty?s=a", { onClose: (e) => closes.push(e.code) });
  for (const code of [1000, 1006, 1011, 1006, 1006, 1006]) {
    last().onclose({ code });
    timers.at(-1).fn();
  }
  expect(timers.map((t) => t.ms)).toEqual([1000, 2000, 4000, 8000, 15000, 15000]);
  expect(last().url).toBe("wss://example.test/pty?s=a");
  frame(last());
  last().onclose({ code: 1006 });
  timers.at(-1).fn();
  expect(timers.at(-1).ms).toBe(1000);
  expect(last().url).toBe("wss://example.test/pty?s=a&reattach=1");
  expect(closes).toHaveLength(7);
});

test("1013 (lagged) after attach reattaches to resync from the scrollback, never onExit", () => {
  const exits = [];
  Pty.connect(new Terminal(), "/pty?s=a", { onExit: (e) => exits.push(e.code) });
  frame(last());
  last().onclose({ code: 1013 });
  timers.at(-1).fn();
  expect(last().url).toBe("wss://example.test/pty?s=a&reattach=1");
  expect(exits).toEqual([]);
});

test("close() disposes every listener connect added to the terminal", () => {
  const term = new Terminal();
  Pty.connect(term, "/pty", { onTitle: () => {} }).close();
  expect(term.on).toEqual({});
  expect(term.osc).toEqual([]);
});

test("4000, 4404 and 4422 are final: onExit, no reconnect", () => {
  for (const code of [4000, 4404, 4422]) {
    const exits = [];
    Pty.connect(new Terminal(), "/pty", { onExit: (e) => exits.push(e.code) });
    last().onclose({ code });
    expect(exits).toEqual([code]);
  }
  Pty.connect(new Terminal(), "/pty").socket.onclose({ code: 4000 });
  expect(timers).toEqual([]);
});

test("reconnect: false and close() both stop the loop", () => {
  Pty.connect(new Terminal(), "/pty", { reconnect: false }).socket.onclose({ code: 1006 });
  expect(timers).toEqual([]);
  const handle = Pty.connect(new Terminal(), "/pty");
  last().onclose({ code: 1006 });
  handle.close();
  last().onclose({ code: 1006 });
  expect(timers).toHaveLength(1);
  expect(timers[0].cleared).toBe(true);
  expect(last().closed).toBe(true);
});

test("mount: Terminal is required", () => {
  expect(() => Pty.mount({}, "/pty")).toThrow("opts.xterm.Terminal is required");
});

test("mount builds, fits, observes and loads every addon handed in", () => {
  const log = [];
  const el = {};
  const handle = Pty.mount(el, "/pty", {
    terminal: { fontSize: 20 },
    xterm: {
      ClipboardAddon: addon(log, "clipboard"),
      FitAddon: addon(log, "fit", () => ({ fit: () => log.push("fitted") })),
      Terminal,
      Unicode11Addon: addon(log, "unicode11"),
      WebglAddon: addon(log, "webgl", (self) => ({
        dispose: () => log.push("webgl disposed"),
        onContextLoss: (fn) => (self.lose = fn),
      })),
    },
  });
  const { term } = handle;
  expect(term.settings).toMatchObject({ allowProposedApi: true, fontSize: 20, scrollback: 5000 });
  expect(term.unicode.activeVersion).toBe("11");
  expect(names(term)).toEqual(["loadAddon", "open", "loadAddon", "loadAddon", "loadAddon"]);
  expect(term.log[1]).toEqual(["open", el]);
  observers[0].fn();
  term.log[4][1].lose();
  expect(log).toEqual(["fit", "unicode11", "clipboard", "webgl", "fitted", "fitted", "webgl disposed"]);
  expect(observers[0].el).toBe(el);
  handle.dispose();
  expect(observers[0].disconnected).toBe(true);
  expect(last().closed).toBe(true);
  expect(term.log.at(-1)).toBe("dispose");
});

test("OSC 52: writes reach the ClipboardAddon, reads never do — mounted, or loaded by the host", () => {
  const seen = [];
  const ClipboardAddon = class {
    activate(term) {
      term.parser.registerOscHandler(52, (data) => seen.push(data) > 0);
    }
  };
  const own = new Terminal();
  own.loadAddon(new ClipboardAddon());
  Pty.connect(own, "/pty");
  for (const term of [Pty.mount({}, "/pty", { xterm: { ClipboardAddon, Terminal } }).term, own])
    for (const data of ["c;aGk=", "c;?", "p;?"]) term.osc.findLast((handler) => handler(data));
  expect(seen).toEqual(["c;aGk=", "c;aGk="]);
});

test("mount degrades: no addons, a WebGL that throws, no ResizeObserver", () => {
  const { ResizeObserver } = globalThis;
  delete globalThis.ResizeObserver;
  const WebglAddon = function () {
    throw new Error("no webgl");
  };
  const handle = Pty.mount({}, "/pty", { xterm: { Terminal, WebglAddon } });
  handle.fit();
  handle.dispose();
  globalThis.ResizeObserver = ResizeObserver;
  expect(names(handle.term)).toEqual(["open", "dispose"]);
  expect(observers).toEqual([]);
});
