This directory contains read-only helpers bundled with Lithe.
build-windows-ide-mcp.mjs builds lithe-mcp.exe for the current Tauri target before
development and packaging. Generated executables are not committed or reused
across worktrees. Runtime connection files belong in app_local_data_dir()/mcp.
