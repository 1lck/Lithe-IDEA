# Windows React/Tauri development plan

Windows uses the React/Tauri product in `windows/tauri`. The former Qt/C++
implementation has been retired. macOS remains SwiftUI/AppKit and both
products consume the same `rust/lithe-core` commands and shared fixtures.

## Completed migration foundation

- The React workbench, Monaco editor, terminal UI, settings, Git surfaces,
  search, extensions, viewers, and workspace state live under
  `windows/tauri/src`.
- The Tauri host links `lithe-core` as a Rust dependency rather than using a
  second C++ C-ABI client.
- `core_execute` and `core_cancel` expose the complete shared JSON protocol.
- `src/platform/tauri-core.ts` is the only frontend invoke boundary.
- Terminal, file watching, credentials, dialogs, filesystem access, and other
  Windows-owned capabilities remain platform adapters.
- Windows CI and release packaging build Tauri; Qt is not installed or built.

## Command migration rules

Existing React feature APIs may use older command names while they are being
aligned with the shared contract. Those names must be translated in
`src-tauri/src/platform.rs`; do not add one Tauri command per shared Core
operation. A translated command returns the successful Core `data` value and
turns a Core error envelope into a rejected invoke call.

Commands without a shared implementation must fail explicitly. Do not add
mock success values to desktop builds. Future AI, SSH, database, collaboration,
and extension-host behavior should be added through their owning shared or
platform contract and enabled in the UI only when the capability exists.

## Remaining product work

1. Align each Git feature API with the stable `git.*` command DTOs.
2. Route workspace search, Local History, remaining non-Java LSP, Java/Maven,
   and run configurations through the same dispatcher. Built-in Java LSP now
   starts through the Windows host (`jdtls` + JDK discovery) and
   `lsp.startServer` with `providerId: "java"`. Spring configuration, `@Value`,
   and bean-injection navigation uses `spring.index` before falling back to LSP.
3. Implement Windows-owned process, debug, update, and secure-storage flows in
   Rust where the current UI exposes them.
4. Hide or capability-gate future feature surfaces until their shared backend
   is available.
5. Run the complete Windows UI, WebView2, ConPTY, installer, signing, and
   upgrade regression suite on a Windows machine.

## Completion requirements

- `bun run typecheck` and `bun run build` pass in `windows/tauri`.
- The Windows Tauri crate formats, builds, and tests.
- `scripts/verify-windows-boundaries.sh` and its PowerShell counterpart pass.
- Windows CI builds a real executable and tests both `lithe-core` and the
  Tauri host.
- Product workflows expose errors, cancellation, timeout, and stale-result
  handling required by `shared/contracts/application-boundary.md`.
