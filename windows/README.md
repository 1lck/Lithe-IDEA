# Windows application

Windows is a React and Tauri application under [`tauri`](tauri/). It shares
deterministic product behavior with macOS through `rust/lithe-core`; it does
not import Swift code or maintain a second implementation of shared commands.

```text
React features and stores
        |
        v
src/platform/tauri-core.ts
        |
        +-- Tauri platform commands: terminal, watcher, credentials
        |
        `-- platform_invoke/core_execute -> lithe-core
```

The React workbench owns Windows presentation and UI state. Shared search,
Git, history, language, run-configuration, and file behavior belongs in
`lithe-core`. Native terminal, file-watcher, credential, dialog, WebView2,
process, and installer behavior belongs in `windows/tauri/src-tauri` or a
Tauri plugin.

## Development

Required tools are Bun 1.3.x, Rust, and the Windows WebView2/Tauri toolchain.

```powershell
cd windows/tauri
bun install --frozen-lockfile
bun run typecheck
bun run desktop:dev
```

Build the Windows executable through the repository script:

```powershell
./scripts/build-windows.ps1 -Configuration Release
```

The macOS host can run frontend type/build checks and Rust checks, but the
packaged application, WebView2, ConPTY, installer, signing, and full UI flows
must be verified on Windows.

## Migration boundary

Frontend modules import `@/platform/tauri-core`, not
`@tauri-apps/api/core` directly. The platform module keeps native commands
explicit and routes shared operations through one Rust dispatcher. New shared
behavior must add or update the contract and fixtures before both products
consume it.
