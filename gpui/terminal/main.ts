// GPUI xterm host.
//
// This page implements the JS half of the terminal protocol in
// gpui/ARCHITECTURE.md: keyboard input and size changes go to Rust through
// window.ipc, while Rust drives rendering through the window.lithe API with
// evaluate_script. It never touches the network, the filesystem or eval.
//
// PTY output arrives as base64 because raw terminal bytes are not valid JSON
// text. xterm decodes the Uint8Array as UTF-8 and keeps partial multi-byte
// sequences across chunks.

import { Terminal, type ITheme } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";

interface LitheConfigurePayload {
  dark?: boolean;
  background?: string;
  foreground?: string;
  cursor?: string;
  selection?: string;
  fontFamily?: string;
  fontSize?: number;
  scrollback?: number;
}

interface LitheTerminalApi {
  /** Write PTY output. `base64` holds the raw UTF-8 bytes of a terminal chunk. */
  write(base64: string): void;
  /** Apply host colors and font settings, then refit. */
  configure(payload: LitheConfigurePayload): void;
  focus(): void;
  clear(): void;
}

interface LitheIpc {
  postMessage(message: string): void;
}

declare global {
  interface Window {
    lithe: LitheTerminalApi;
    ipc?: LitheIpc;
  }
}

interface Appearance {
  dark: boolean;
  background: string;
  foreground: string;
  cursor: string;
  selection: string;
  fontFamily: string;
  fontSize: number;
  scrollback: number;
}

interface ModeDefaults {
  background: string;
  foreground: string;
  cursor: string;
  selection: string;
}

// 与 Rust 侧 `terminal_font_family()` 保持同一套回退：主字体缺失时用平台原生
// 等宽字体，避免回退到比例字体后字符被拉宽（看起来像“全角”）。
const PLATFORM_MONO_FALLBACK = /Windows/i.test(navigator.userAgent)
  ? "Consolas"
  : /Mac/i.test(navigator.userAgent)
    ? "Menlo"
    : '"Liberation Mono"';
const DEFAULT_FONT_FAMILY = `"JetBrains Mono", ${PLATFORM_MONO_FALLBACK}, monospace`;
const DEFAULT_FONT_SIZE = 13;
const DEFAULT_SCROLLBACK = 5000;
const FONT_SIZE_MIN = 6;
const FONT_SIZE_MAX = 72;
const SCROLLBACK_MIN = 100;
const SCROLLBACK_MAX = 100_000;
const MAX_FONT_FAMILY_LENGTH = 200;
const MAX_COLOR_LENGTH = 64;

// Palette values follow the VS Code terminal defaults so the terminal sits
// next to the Monaco editor without a separate color system.
const DARK_ANSI: ITheme = {
  black: "#000000",
  red: "#cd3131",
  green: "#0dbc79",
  yellow: "#e5e510",
  blue: "#2472c8",
  magenta: "#bc3fbc",
  cyan: "#11a8cd",
  white: "#e5e5e5",
  brightBlack: "#666666",
  brightRed: "#f14c4c",
  brightGreen: "#23d18b",
  brightYellow: "#f5f543",
  brightBlue: "#3b8eea",
  brightMagenta: "#d670d6",
  brightCyan: "#29b8db",
  brightWhite: "#e5e5e5",
};

const LIGHT_ANSI: ITheme = {
  black: "#000000",
  red: "#cd3131",
  green: "#00bc00",
  yellow: "#949800",
  blue: "#0451a5",
  magenta: "#bc05bc",
  cyan: "#0598bc",
  white: "#555555",
  brightBlack: "#666666",
  brightRed: "#cd3131",
  brightGreen: "#14ce14",
  brightYellow: "#b5ba00",
  brightBlue: "#0451a5",
  brightMagenta: "#bc05bc",
  brightCyan: "#0598bc",
  brightWhite: "#a5a5a5",
};

const DARK_DEFAULTS: ModeDefaults = {
  background: "#1e1e1e",
  foreground: "#d4d4d4",
  cursor: "#d4d4d4",
  selection: "rgba(38, 79, 120, 0.55)",
};

const LIGHT_DEFAULTS: ModeDefaults = {
  background: "#ffffff",
  foreground: "#1f1f1f",
  cursor: "#1f1f1f",
  selection: "rgba(173, 214, 255, 0.6)",
};

const appearance: Appearance = {
  dark: true,
  ...DARK_DEFAULTS,
  fontFamily: DEFAULT_FONT_FAMILY,
  fontSize: DEFAULT_FONT_SIZE,
  scrollback: DEFAULT_SCROLLBACK,
};

type EarlyOperation = { type: "write"; bytes: Uint8Array } | { type: "clear" };

let terminal: Terminal | null = null;
let fitAddon: FitAddon | null = null;
const earlyOperations: EarlyOperation[] = [];
let focusWhenReady = false;
let fitFrame: number | null = null;
let missingIpcWarned = false;

const container = document.getElementById("terminal");
if (!container) throw new Error("Lithe terminal: missing #terminal container");

function post(message: Record<string, unknown>): void {
  const ipc = window.ipc;
  if (!ipc || typeof ipc.postMessage !== "function") {
    if (!missingIpcWarned) {
      missingIpcWarned = true;
      console.warn("lithe: terminal IPC is unavailable");
    }
    return;
  }
  try {
    ipc.postMessage(JSON.stringify(message));
  } catch (error) {
    console.error("lithe: failed to send terminal message", error);
  }
}

function readColor(value: unknown, fallback: string): string {
  if (typeof value !== "string") return fallback;
  const candidate = value.trim();
  if (!candidate || candidate.length > MAX_COLOR_LENGTH) return fallback;
  if (typeof CSS !== "undefined" && typeof CSS.supports === "function") {
    try {
      return CSS.supports("color", candidate) ? candidate : fallback;
    } catch {
      return fallback;
    }
  }
  return /^(?:#[0-9a-f]{3,8}|(?:rgb|rgba|hsl|hsla)\([^)]*\)|[a-z]+)$/i.test(candidate)
    ? candidate
    : fallback;
}

function currentTheme(): ITheme {
  return {
    ...(appearance.dark ? DARK_ANSI : LIGHT_ANSI),
    background: appearance.background,
    foreground: appearance.foreground,
    cursor: appearance.cursor,
    cursorAccent: appearance.background,
    selectionBackground: appearance.selection,
    selectionInactiveBackground: appearance.selection,
  };
}

function decodeBase64(encoded: unknown): Uint8Array | undefined {
  if (typeof encoded !== "string" || encoded.length === 0) return undefined;
  let binary: string;
  try {
    binary = window.atob(encoded);
  } catch {
    // Invalid chunks are dropped rather than surfacing as unhandled errors;
    // terminal output is best effort and the PTY keeps running.
    return undefined;
  }
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

function writeBytes(bytes: Uint8Array): void {
  if (!terminal) {
    earlyOperations.push({ type: "write", bytes });
    return;
  }
  try {
    terminal.write(bytes);
  } catch (error) {
    console.warn("lithe: terminal write failed", error);
  }
}

function fitNow(): void {
  if (!terminal || !fitAddon) return;
  // FitAddon clamps to 2x1 when the island is hidden (display: none).
  // Deferring keeps the PTY at its previous size until the panel is shown.
  if (container.clientWidth <= 0 || container.clientHeight <= 0) return;
  try {
    fitAddon.fit();
  } catch (error) {
    // A renderer that has not measured its glyphs yet is retried by the next
    // ResizeObserver frame; failing one fit must not break the page.
    console.warn("lithe: terminal fit failed", error);
  }
}

function scheduleFit(): void {
  if (fitFrame !== null) return;
  fitFrame = window.requestAnimationFrame(() => {
    fitFrame = null;
    fitNow();
  });
}

function applyAppearance(): void {
  const background = appearance.background;
  document.documentElement.style.colorScheme = appearance.dark ? "dark" : "light";
  // Keep the host page opaque and in sync with xterm so no white flash or
  // mismatched gutter shows through while the renderer boots.
  document.documentElement.style.backgroundColor = background;
  document.body.style.backgroundColor = background;

  if (!terminal) return;
  terminal.options.theme = currentTheme();
  terminal.options.fontFamily = appearance.fontFamily;
  terminal.options.fontSize = appearance.fontSize;
  terminal.options.scrollback = appearance.scrollback;
  fitNow();
}

function applyConfigure(payload: LitheConfigurePayload): void {
  if (!payload || typeof payload !== "object") return;

  const dark = typeof payload.dark === "boolean" ? payload.dark : appearance.dark;
  const modeChanged = dark !== appearance.dark;
  appearance.dark = dark;
  const defaults = dark ? DARK_DEFAULTS : LIGHT_DEFAULTS;

  // A bare { dark } toggle should also move the colors that the host did not
  // resend, so the page never mixes a light background with a dark cursor.
  appearance.background = readColor(payload.background, modeChanged ? defaults.background : appearance.background);
  appearance.foreground = readColor(payload.foreground, modeChanged ? defaults.foreground : appearance.foreground);
  appearance.cursor = readColor(payload.cursor, modeChanged ? defaults.cursor : appearance.cursor);
  appearance.selection = readColor(payload.selection, modeChanged ? defaults.selection : appearance.selection);

  if (typeof payload.fontFamily === "string") {
    const fontFamily = payload.fontFamily.trim();
    if (fontFamily) appearance.fontFamily = fontFamily.slice(0, MAX_FONT_FAMILY_LENGTH);
  }
  if (typeof payload.fontSize === "number" && Number.isFinite(payload.fontSize) && payload.fontSize > 0) {
    appearance.fontSize = Math.min(FONT_SIZE_MAX, Math.max(FONT_SIZE_MIN, payload.fontSize));
  }
  if (typeof payload.scrollback === "number" && Number.isFinite(payload.scrollback) && payload.scrollback > 0) {
    appearance.scrollback = Math.min(SCROLLBACK_MAX, Math.max(SCROLLBACK_MIN, Math.floor(payload.scrollback)));
  }

  applyAppearance();
}

// window.lithe must exist before xterm finishes opening: Rust may call write()
// or configure() as soon as the page starts loading. Writes are replayed in
// order once the terminal exists; configuration mutates the appearance state
// that the Terminal constructor reads.
window.lithe = {
  write(base64) {
    const bytes = decodeBase64(base64);
    if (!bytes) return;
    writeBytes(bytes);
  },

  configure(payload) {
    applyConfigure(payload);
  },

  focus() {
    if (terminal) {
      terminal.focus();
    } else {
      focusWhenReady = true;
    }
  },

  clear() {
    if (!terminal) {
      earlyOperations.push({ type: "clear" });
      return;
    }
    try {
      terminal.clear();
    } catch (error) {
      console.warn("lithe: terminal clear failed", error);
    }
  },
};

const fit = new FitAddon();
const term = new Terminal({
  fontFamily: appearance.fontFamily,
  fontSize: appearance.fontSize,
  cursorBlink: true,
  scrollback: appearance.scrollback,
  // Required for alpha backgrounds and translucent selection colors; it can
  // only be set before open().
  allowTransparency: true,
  theme: currentTheme(),
});

terminal = term;
fitAddon = fit;

term.loadAddon(fit);
term.onData((data) => {
  post({ type: "input", data });
});
term.onResize(({ rows, cols }) => {
  post({ type: "resize", rows, cols });
});
term.open(container);

// Replay calls made between page start and open() before announcing ready, so
// Rust sees the same ordering it produced.
for (const operation of earlyOperations.splice(0)) {
  if (operation.type === "write") {
    try {
      term.write(operation.bytes);
    } catch (error) {
      console.warn("lithe: terminal write failed", error);
    }
  } else {
    term.clear();
  }
}

if (focusWhenReady) term.focus();

// Announce before the first fit so the host never receives a resize for a PTY
// it has not created yet. The fit below still emits the initial size.
post({ type: "ready" });
fitNow();
scheduleFit();

if (typeof ResizeObserver === "function") {
  const observer = new ResizeObserver(() => scheduleFit());
  observer.observe(container);
} else {
  window.addEventListener("resize", scheduleFit);
}

// Web fonts resolve after layout; refit once glyph metrics are final.
if (document.fonts) {
  document.fonts.ready.then(() => scheduleFit()).catch(() => undefined);
}
