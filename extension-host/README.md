# Lithe VS Code extension host (prototype, #737)

A Node process that runs unmodified VS Code extensions against Lithe services.
It reuses Theia's plugin-side implementation of the `vscode` API
(`@theia/plugin-ext` 1.75.0, unmodified, from npm) and replaces Theia's
workbench with Lithe's own `*Main` implementations in `src/main-side/`, all in
one process. Lithe talks to it only through the JSON protocol in
[`shared/contracts/vscode-extension-host.md`](../shared/contracts/vscode-extension-host.md).

The decision record is
[`.agents/notes/proposed/architecture/2026-09-19-vscode-extension-host.md`](../.agents/notes/proposed/architecture/2026-09-19-vscode-extension-host.md).

```text
unmodified extension ─ vscode.* ─> Theia plugin side (npm, unmodified)
                                        │ in-memory Theia RPC
                                   src/main-side/*  (Lithe *Main implementations)
                                        │ stdin/stdout JSON, shared/contracts
                                   Lithe supervisor (macOS / Windows)
```

## Commands

```bash
bun install          # own lockfile; not part of the root workspace
bun run typecheck
bun run build        # dist/main.js, Theia packages stay external
bun test test        # launches dist/main.js with `node` for every test
```

The host must run under Node (extensions rely on Node's module loader for
`require('vscode')`); Bun is only the package manager and test runner.

`scripts/audit-extensions.ts` loads real extensions into the host with a fake
Lithe and prints which APIs they reached that Lithe does not implement yet:

```bash
bun scripts/audit-extensions.ts --workspace <maven project> --open src/main/java/demo/App.java \
  --event workspaceContains:pom.xml \
  --config 'java.configuration.runtimes=[{"name":"JavaSE-21","path":"<jdk>","default":true}]' \
  --observe-seconds 90 <unpacked redhat.java>/extension <unpacked vscode-java-debug>/extension
```

## Licensing

Theia packages are `EPL-2.0 OR GPL-2.0-only WITH Classpath-exception-2.0` and
are consumed unmodified from npm. Extensions must come from Open VSX or another
source whose terms allow use outside VS Code; `redhat.java` is EPL-2.0. Do not
bundle Microsoft Marketplace downloads.
