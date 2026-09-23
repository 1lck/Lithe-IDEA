# Windows and Linux application

Windows and Linux are React and Tauri applications under [`tauri`](tauri/).
They share deterministic product behavior with macOS through `rust/lithe-core`;
they do not import Swift code or maintain a second implementation of shared
commands.

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

The React workbench owns Windows and Linux presentation and UI state. Shared
search, Git, history, language, run-configuration, and file behavior belongs in
`lithe-core`. Native terminal, file-watcher, credential, dialog, WebView,
process, and installer behavior belongs in `windows/tauri/src-tauri` or a
Tauri plugin.

## Development

Required tools are Bun 1.3.x, Rust, and the platform WebView/Tauri toolchain
(WebView2 on Windows, WebKitGTK on Linux).

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

### Linux

Linux requires Rust, Bun, and the system packages that Tauri and its plugins
link against:

```bash
sudo apt-get install -y \
    libwebkit2gtk-4.1-dev \
    libgtk-3-dev \
    libayatana-appindicator3-dev \
    librsvg2-dev \
    libssl-dev \
    libxdo-dev \
    build-essential \
    patchelf
```

Install Bun if it is missing with `curl -fsSL https://bun.sh/install | bash`.

Build the Linux executable through the repository script:

```bash
./scripts/build-linux.sh --configuration Debug
./scripts/build-linux.sh --configuration Release
```

`--configuration` defaults to `Debug`; pass `--target <rust-triple>` to build for
an architecture other than the host. The script runs `bun install
--frozen-lockfile`, `bun run typecheck`, `bun run build`, and `tauri build`.

Run the development app from `windows/tauri`:

```bash
cd windows/tauri
bun run desktop:dev:linux
```

Linux uses `src-tauri/tauri.linux.conf.json`, the identifier `app.lithe.linux`,
the product name `lithe-linux`, and the `deb` and `appimage` bundle targets. The
bundled JDTLS and JDK resources come from `.artifacts/jdtls-linux` and
`.artifacts/jdk-linux`, which `scripts/prepare-jdtls-linux.sh` and
`scripts/prepare-jdk-linux.sh` stage from the manifests under `third_party/`.

The macOS host can run frontend type/build checks and Rust checks, but the
packaged application, WebView2/WebKitGTK, ConPTY/PTY, installer, signing, and
full UI flows must be verified on Windows or Linux respectively.

## Migration boundary

Frontend modules import `@/platform/tauri-core`, not
`@tauri-apps/api/core` directly. The platform module keeps native commands
explicit and routes shared operations through one Rust dispatcher. New shared
behavior must add or update the contract and fixtures before both products
consume it.
