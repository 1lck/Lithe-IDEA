# Windows implementation status

Windows is an independent Qt Widgets/C++ implementation. Shared application
behavior is provided by `rust/lithe-core` through its C ABI and JSON command
protocol; the macOS SwiftUI/AppKit application is not a Windows dependency.

Match macOS product behavior through the Rust API, contracts, and fixtures in
[`shared`](../shared/README.md). Keep Windows-specific file watching,
PTY/ConPTY, terminal, runtime discovery, installer, update, and native UI logic
in this directory.

Before continuing the implementation, read the [Windows handoff record](../docs/architecture/windows-handoff.md).
It records the current implementation boundary, known risks, and the next tasks;
the development plan remains the long-term roadmap.

The current implementation has four layers:

- [`core`](core/): `CoreClient` owns the UTF-8 response returned by the Rust C
  ABI and exposes `CoreResult<T> = std::expected<T, CoreError>` plus the shared
  JSON envelope to C++. ABI failures, malformed envelopes, and Rust error
  envelopes stay typed through the coordinator and feature models.
  `CoreWorkerPool` keeps each call on one fixed worker so Rust cancellation
  scopes remain observable.
- [`adapters`](adapters/): platform-neutral ports and Win32 implementations for
  file access, watching, processes, runtime discovery, terminal transport,
  secure storage, file storage, and persistence. Process stdout/stderr,
  directory change kinds, and adapter failures have separate channels.
- [`app`](app/): feature models, persistence, runtime selection, and a Maven
  request builder that stays independent of Qt and Win32 details.
- [`qt`](qt/): a workspace workbench with project selection, tree browsing,
  file read/write, recent-project welcome/clone flow, editor find and Markdown
  preview, search/search-everywhere, refresh, Git status/diff/history/graph,
  hunk overview, cross-column diff connections, commit file/line review, and
  local history, Maven phase execution/output, Java run/debug controls,
  debugger variables/threads/stack views, Java diagnostic double-click
  navigation, and watcher refresh. Search Everywhere supports fuzzy subsequence
  matching and Windows double-Shift activation. The Qt window consumes
  feature-model state rather than parsing Core envelopes or assembling JSON
  requests. Java navigation also normalizes `jdt://` locations, reads JDK
  `src.zip` through the Windows `tar.exe` adapter, and falls back to JDT
  decompilation with a read-only cached-source preview.

Windows-only services also cover jdb-based Java debugging, AI commit-message
generation through Responses/Chat Completions/Anthropic APIs, GitHub release
checks with mandatory SHA-256 and Authenticode verification, a post-exit update
helper, WinHTTP GET/POST, and NSIS packaging. The platform-independent
regression suite currently has twelve CTest targets.

This worktree is being developed from macOS. Do not run the Windows/Qt build or
platform-specific tests locally; use the Windows CI workflow or a Windows Qt
environment for those checks.

The following is the CI/Windows-environment reference command, not a local Mac
verification step:

```sh
cmake -S windows -B windows/build
cmake --build windows/build
ctest --test-dir windows/build --output-on-failure
```

The Qt target is optional and requires Qt 6. A Windows toolchain must also
provide the Rust library through `LITHE_RUST_CORE_LIBRARY` before packaging.
The Windows CI path uses `scripts/build-windows.ps1` to cross-build the Rust
static library and adds a real `core.ping` smoke test. Real Windows execution
of ConPTY, Job Objects, registry discovery, DPAPI, installer/update behavior,
and full macOS feature parity remain incomplete locally. Run
`scripts/verify-windows-boundaries.sh` or the PowerShell equivalent when
changing the Windows boundaries.
