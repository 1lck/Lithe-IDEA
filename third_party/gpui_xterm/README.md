# Vendored `gpui_xterm`

Pinned copy of [Modolet/gpui_xterm](https://github.com/Modolet/gpui_xterm) used by
the Linux GPUI product for the embedded terminal.

- Upstream revision: `4bdcdbbeab4211f7938f31919819b06d755a1733` (2026-06-05)
- License: MIT (see `LICENSE`)

## Why it is vendored

Upstream depends on `gpui` from the Zed git repository and `gpui-component` from
the longbridge git repository. Lithe renders through the published
`gpui-pre`/`gpui-component` crate family re-exported by `gpui-kit`. Cargo treats a
git dependency and a registry dependency as different package identities, so the
upstream manifest cannot be consumed as-is without a compile-time type split.
`Cargo.toml` re-points the same source at Lithe's crate family and pins
`alacritty_terminal` to the version the Linux product already uses.

## Local patches

Keep this list in sync with the source. Each patch is marked with a `Lithe patch`
comment at the change site.

1. `src/terminal.rs`: `TerminalState::with_scrollback` — upstream always built
   `Config::default()` and ignored `TerminalConfig::scrollback`.
2. `src/view.rs`: `TerminalState` construction now passes `config.scrollback`.
3. `src/view.rs`: `TerminalView::state()` — exposes the engine state so the host
   product can implement search, scroll-to-bottom and display-offset queries while
   the component keeps ownership of rendering and input.
4. `src/render.rs`: `TerminalRenderer::measure_cell` measures the cell width from
   the half-width ASCII advance (`'m'`) only. Upstream took the maximum over
   `["M","W","█","▀","▄"]`; GPUI resolves fonts through its own fontdb, and on the
   target Linux systems the block-element samples fall back to a full-width (1em)
   CJK font, inflating every column to ~1.7× and making the whole grid much wider
   than a normal terminal.
5. `src/view.rs` + `src/lib.rs`: `ContextMenuLabels` and
   `TerminalView::with_context_menu_labels` — upstream hardcoded the context-menu
   labels ("Copy"/"Paste"/"Clear"); the host injects localized strings. The default
   keeps upstream's wording so the component still works standalone.

When pulling a newer upstream revision, re-apply these patches and re-run
`cargo check -p gpui_xterm`.

## Host-side behavior we do NOT patch upstream for

Copy from the context menu / Ctrl+C is delivered by the host instead. Upstream
builds a throwaway `arboard::Clipboard` per copy and drops it immediately; on X11
that drops the selection before it can be handed to a clipboard manager, so pasting
in another app yields nothing. Lithe reads the selection through the `state()`
accessor and writes it to GPUI's own platform clipboard (held for the process
lifetime), on left mouse-up and Ctrl+C. Keep the fix on the host side; do not
rewrite upstream's clipboard code.
