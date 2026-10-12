# Plugin contract v1: declarative plugins

A declarative plugin describes language support as data. The host reads
`plugin.json`, validates it, verifies the package signature, and launches the
declared external processes itself. The host never loads plugin code into its
own process, so a package does not depend on the host's binary layout and does
not need to be rebuilt for each Lithe release.

This directory is the cross-platform source of truth:

| File | Purpose |
| --- | --- |
| `plugin-manifest.schema.json` | JSON shape of `plugin.json` |
| `fixtures/*.plugin.json` | Valid example manifests (PHP and Go shapes) |
| `fixtures/invalid-manifests.json` | Edits to a valid manifest and the rejection code every host must report |
| `fixtures/command-plans.json` | Golden run/test command expansions |

Validation and template expansion are implemented once in Rust Core
(`rust/lithe-core/src/plugins/declarative.rs`) and exposed through the
`plugins.declarative.*` commands in `../../rust-core-api.md`. Hosts must not
reimplement them.

## Package layout

```text
<plugin-id>/
├── plugin.json                    # this contract
├── lithe-plugin-signature.json    # publisher signature over every other file
└── …                              # resources referenced by plugin.json
```

Every path in `plugin.json` is relative to the package root, uses `/`, and may
not contain `..`, a leading `/`, a backslash, or NUL. Packages may not contain
symbolic links. A host treats an installed package as read-only.

## Manifest

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Always `2`. Schema `1` was the retired macOS native-bundle manifest; hosts refuse it with `plugin.schema.unsupported`. |
| `id` | Stable plugin ID: lowercase letters, digits, `.` and `-`. |
| `displayName` | Name shown in plugin management. |
| `version` | Plugin version, `major.minor.patch`. Independent of the Lithe version. |
| `pluginAPIVersion` | Declarative plugin API level the package needs. Hosts list the levels they support; Lithe's own version is never used for compatibility. This contract defines level `1`. |
| `vendor` | `id`, `displayName`, and `signatureRequirement` (see Trust). |
| `permissions` | Capabilities the plugin may ask the host to perform. |
| `activationEvents` | When the host may start each provider. |
| `languages` | Languages the plugin recognizes. |
| `languageServers` | At most one language server per declared language. |
| `executionProviders` | At most one run/test provider per declared language. |

Unknown fields are refused (`plugin.manifest.invalid`). A new field requires a
new `pluginAPIVersion` so older hosts reject the package instead of ignoring
part of it.

### Languages

`id` is lowercase (`[a-z0-9+_-]`). `fileExtensions`, `fileNames`, and
`projectFileNames` are matched case-insensitively; at least one must be
present. A leading dot is optional only in `fileExtensions` (`.php` equals
`php`). In complete file names, project markers, and management file names it
is part of the name, so `.toolrc` and `.env.example` stay hidden-file names. Optional `dependencies` lists `managementFileNames`,
`projectDependencyPaths`, and `projectBinaryPaths` relative to the project.

### Language servers

| Field | Meaning |
| --- | --- |
| `languageID` | A declared language. |
| `languageIdentifier` | LSP `languageId` for documents; defaults to `languageID`. |
| `launch` | `{"kind": "packaged", "path": …}` runs an executable inside the package. `{"kind": "systemCommand", "commands": [...]}` lists bare command names the host resolves with its tool discovery (PATH, project toolchains, user overrides). |
| `arguments` | Arguments passed to the server. |
| `validationArguments` | Probe that must exit with status 0 before a candidate is used; empty means the host trusts the candidate and lets the LSP handshake decide. |
| `runtimeDependencies` | Runtimes the host must discover and pass to the server. v1 tools are `node` and `go`. The host exports each path as `LITHE_<TOOL>_PATH` (`LITHE_NODE_PATH`, `LITHE_GO_PATH`; a user-set value takes precedence) and prepends its directory to the server's `PATH`, because servers such as gopls run the tool themselves and an app opened from the Dock does not inherit the shell `PATH`. A project-local copy is never chosen, since servers start automatically when a file opens. |

The host owns the language-server process lifecycle, the LSP session, and
stopping the process when the provider is disabled.

### Execution providers

`run` and `test` each name an `executable`: exactly one of a bare `command`
resolved on the host's tool path, or a host-owned project `toolchain` ID such
as `project-go`. The working directory is always the workspace root.

`test` also declares:

| Field | Meaning |
| --- | --- |
| `frameworkID` | Stable framework label such as `phpunit` or `go`. |
| `workspaceLabel` | Label of the "all tests" item and plan. |
| `projectMarkers` | File names, any one of which makes the workspace a test project. |
| `testFilePatterns` | Case-insensitive file-name patterns using only `*`. |
| `workspaceArguments`, `fileArguments`, `testCaseArguments` | Argument templates per scope. |

Argument templates are argv elements, never shell text. Each element is a
string or `{"value": …, "when": "fileSelected" | "noFileSelected"}`;
conditional elements are only allowed in `testCaseArguments`, where a file is
optional.

| Variable | Available in | Value |
| --- | --- | --- |
| `${file}` | run, file, test case | Workspace-relative file. A name starting with `-` becomes `./<name>`. |
| `${fileDirectory}` | run, file, test case | `./<directory>` of the file, or `.` at the workspace root. |
| `${testName}` | test case | Test identifier with surrounding whitespace removed. |
| `${testName:regex}` | test case | The identifier with regular-expression metacharacters escaped. |
| `${userArguments}` | run | The user's program arguments; must be a whole element and may expand to zero elements. |

In `testCaseArguments`, an element that uses `${file}` or `${fileDirectory}`
must be guarded with `"when": "fileSelected"`, and some element must use the
test name.

Discovery returns `{id: "<language>:workspace", kind: "workspace"}` followed by
`{id: "<language>:file:<path>", kind: "file", relativeFilePath}` for matching
files sorted by path, or an empty list when no project marker is present.

## Permissions and activation

| Permission | Required when |
| --- | --- |
| `languageServer.launch` | `languageServers` is not empty |
| `process.run` | any provider declares `run` |
| `process.test` | any provider declares `test` |

| Activation event | Meaning |
| --- | --- |
| `onLanguage:<id>` | Start the language server when a document of the language opens in a project. |
| `onRun:<id>` | Activate the run provider when the user runs a file of the language. |
| `onTest:<id>` | Activate the test provider when the user lists or runs tests. |

Each provider needs its event and each event needs a provider. Enabling a
plugin only permits activation; nothing starts until its event occurs.

## Trust

- `publisherPackage`: the package must carry a valid publisher signature
  (`lithe-plugin-signature.json`, Ed25519 over every file) from a key the host
  trusts. Development builds may install an unsigned package from disk as a
  local development package; release builds refuse it.
- `sameTeamAsHost`: only honored for a package shipped inside the host's own
  signed installation, whose code signature already seals it.

A host pins the signature requirement of its official plugin IDs so a package
cannot downgrade itself.

## Outcomes and error codes

`plugins.declarative.*` commands return `{"status": "ok", …}` or
`{"status": "rejected", "error": {"code", "message", "field"?}}`. A malformed
command payload is a Core `invalid_request` failure instead.

| Code | Reported by | Meaning |
| --- | --- | --- |
| `plugin.manifest.invalid` | Core | Malformed manifest, unknown field, or broken cross reference |
| `plugin.schema.unsupported` | Core | `schemaVersion` is not `2` |
| `plugin.api.unsupported` | Core | `pluginAPIVersion` is not supported by this host |
| `plugin.permission.unknown` | Core | Unknown permission |
| `plugin.permission.undeclared` | Core | A provider is declared without its permission |
| `plugin.activation.invalid` | Core | Missing or orphan activation event |
| `plugin.runtime.unsupported` | Core | Unknown runtime dependency |
| `plugin.template.invalid` | Core | Unknown, misplaced, or unguarded template variable |
| `plugin.path.invalid` | Core | A request path leaves the workspace |
| `plugin.test.invalidIdentifier` | Core | Empty or multi-line test identifier |
| `plugin.test.unsupportedProject` | Core | No project marker in the workspace |
| `plugin.execution.unavailable` | Core | The plugin has no run/test provider for the language |
| `plugin.signature.missing`, `plugin.signature.invalid`, `plugin.signature.untrusted` | Host | Package signature problems |
| `plugin.launch.missing` | Host | The packaged language server is missing or not executable |
| `plugin.runtime.missing` | Host | A declared runtime (for example Node.js) cannot be found when the server starts |
| `plugin.legacyNative.updateRequired` | Host | An installed schema-1 native package must be replaced by its declarative version |

Host-facing plugin states are `notInstalled`, `installed` (enabled or
disabled), `running`, `restartRequired`, `updateRequired`, and `failed`.

## Windows mapping

The Windows extension manifest (`Plugins/win/Official/*/plugin.json`) predates
this contract. Its adapter maps `languages[].extensions` to
`languages[].fileExtensions`, `lsp.server`/`lsp.args` to `languageServers[]`,
`lsp.requiredExecutables: ["node"]` to `runtimeDependencies`, and
`runActions.manifestFiles` to `test.projectMarkers`. Composer script discovery
is Windows-only behavior outside v1.
