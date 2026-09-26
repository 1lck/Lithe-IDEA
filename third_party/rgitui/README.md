# Vendored `rgitui` (diff-viewer subset)

Lithe vendors a **subset** of [noahbclarkson/rgitui](https://github.com/noahbclarkson/rgitui)
to render Git diffs on Linux instead of writing a second diff view.

- Upstream revision: `ead56a9ec9d43cf099f27ae1129323a08d56149e`
- License: MIT (see `LICENSE`)

## What is vendored

Only the closure needed by the diff viewer:

| Crate | Role |
| --- | --- |
| `crates/rgitui_diff` | the diff view (`DiffViewer`), pairing/highlighting, syntect |
| `crates/rgitui_ui` | its widget kit (buttons, labels, icons, scroll) |
| `crates/rgitui_theme` | its theme state (appearance + colors) |
| `crates/rgitui_git` | **plain data types only** (`FileDiff`, `DiffLine`, `FileChangeKind`, …) |
| `crates/rgitui_settings` | settings type used by the crates above |

Not vendored: the `rgitui` app crate, `rgitui_graph`, `rgitui_ai`, `rgitui_perf`,
`rgitui_test_support`, and any of their assets.

## Adaptation (the only edits to upstream source)

Upstream pins `gpui` / `gpui_platform` / `http_client` to a **Zed git revision**.
Cargo treats a git dependency as a different package identity from the published
`gpui-pre` / `gpui-component` family Lithe renders through, so:

1. The workspace root `Cargo.toml` re-points `gpui` at `gpui-pre` (its lib name is
   `gpui`) and drops the Zed git and `http_client` entries. Nothing in the member
   sources was changed for this.
2. The members' unused optional dependencies were dropped: `rgitui_perf`,
   `rgitui_test_support`, and the `perf` features that reached them. The leftover
   `perf = []` feature declarations keep the members' `#[cfg(feature = "perf")]`
   blocks known-but-off so the build stays warning-free.

`cargo check -p rgitui_diff` against `gpui-pre 0.3.6` reports **0 errors and
0 warnings**, i.e. the pinned gpui revision and `gpui-pre` are API-compatible for
this closure.

## Data ownership

The vendored crates are **presentation only**. Repository data keeps coming from
the shared `lithe-core` `git.*` contract that macOS and Windows already use;
Lithe adapts `git.diff`'s structured rows/hunks into `rgitui_git::FileDiff` and
hands it to `DiffViewer::set_diff`. `git2` is compiled because `rgitui_git`
needs it, but it never reads a repository for Lithe.

When updating the upstream revision, re-apply the three adaptations above and
re-run `cargo check -p rgitui_diff`.
