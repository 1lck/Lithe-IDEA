# Lithe – Windows Port (Electron + React + TypeScript)

This is the Windows version of [Lithe](https://github.com/1lck/Lithe-IDEA), an IDEA-shaped lightweight Java IDE.

## Prerequisites

- **Node.js** >= 18
- **pnpm** >= 8 (recommended) or npm
- **Git** in PATH
- **JDK** (optional, for Java run/debug features)

## Getting started

```bash
cd windows
pnpm install
pnpm dev
```

## Building for production

```bash
pnpm build:win
```

The installer will be generated in `windows/dist/`.

## Architecture

```
windows/
├── src/
│   ├── main/              # Electron main process
│   │   ├── index.ts       # Entry point
│   │   └── services/      # IPC handlers (file, project, git, java, terminal, search)
│   ├── preload/           # Context bridge
│   ├── renderer/          # React UI
│   │   └── src/
│   │       ├── App.tsx
│   │       ├── views/     # WorkbenchView, WelcomeView
│   │       ├── components/# MonacoEditor, ProjectSidebar, EditorTabs, TerminalPanel
│   │       └── theme/     # CSS variables matching LitheTheme.swift colors
│   └── common/            # Shared types and IPC channel names
├── electron-builder.yml   # Packaging config
└── electron.vite.config.ts
```

## Feature parity with macOS version

| Feature | Status |
|---------|--------|
| Project tree | Implemented |
| Code editor (Monaco) | Implemented |
| Multi-tab editing | Implemented |
| IDEA dark theme | Implemented |
| File watching | Implemented |
| Terminal (basic) | Implemented |
| Git status/log/diff/branch/commit | Implemented |
| Git graph | Planned |
| Search Everywhere | Implemented (backend) |
| Find in file | Via Monaco built-in |
| Project search/replace | Implemented (backend) |
| JDK discovery (Windows) | Implemented |
| Maven discovery | Implemented |
| Java run | Implemented |
| Maven run | Implemented |
| JDT LS (Java semantics) | Planned |
| Java Debug (DAP) | Planned |
| Local History | Implemented (backend) |
| Settings | Implemented (backend) |
| Auto-update | Planned |

## Contributing

This port lives in the `windows/` directory. The macOS SwiftUI code under `Sources/` remains untouched. Both can coexist in the same repository.
