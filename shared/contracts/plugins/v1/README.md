# Plugin contract v1: declarative plugins

A declarative plugin currently describes language support or first-stage UI contributions as data. The host reads
`plugin.json`, validates it, checks the applicable signature or community approval, and launches the
declared external processes itself. The host never loads plugin code into its
own process, so a package does not depend on the host's binary layout and does
not need to be rebuilt for each Lithe release.

This directory is the cross-platform source of truth:

| File | Purpose |
| --- | --- |
| `plugin-manifest.schema.json` | JSON shape of `plugin.json` |
| `fixtures/*.plugin.json` | Valid example manifests, named after the capability they exercise rather than a published plugin: `language-*` (packaged, system-command, and host-integration language servers; `node-runtime` for a discovered runtime), `hello-lithe` and `web-panel` (UI), `settings-v2`, and `build-*` (level 3 build systems and the two forms of a build provider) |
| `fixtures/tool-definition.plugin.json`, `fixtures/toolchain-provider.plugin.json` | Production-shape Core fixtures for tool definitions and a packaged toolchain provider; require explicit new host capabilities, not yet supplied by native products |
| `fixtures/invalid-manifests.json` | Edits to a valid manifest and the rejection code every host must report |
| `fixtures/command-plans.json` | Golden run/test command expansions and language-server launch plans |
| `fixtures/runtime-versions.json` | Golden outcomes of the launch runtime version check |
| `fixtures/build-plans.json` | Golden build-system plans and decoded outputs |
| `fixtures/function-protocol.json` | Golden plugin-function negotiation, registration, invocation, outcome, progress, and refusal cases |
| `fixtures/project-generator.plugin.json`, `fixtures/project-generator-templates/` | Project generators: template files, a scaffolding command, and an archive download |
| `fixtures/project-plans.json` | Golden `project.*` form evaluations, generation plans, and name checks |
| `plugin-index.schema.json` | JSON shape of a marketplace source index |
| `fixtures/marketplace/*.json` | Marketplace index, availability, source URL, and install review golden cases |
| `toolchains.md` | Implemented Core foundation: plugin definitions/provider declarations, verified-origin registry, reply validation, directory pins, snapshot resolution, version matching and discovery plans; native hosts are not connected |
| `proposals/toolchains/` | Broader design draft, including unimplemented query transport, native lifecycle/persistence, consumer migration, settings UI and manager plugins; examples are review projections, not installable manifests |

Validation and template expansion are implemented once in Rust Core
(`rust/lithe-core/src/plugins/`, with build systems in
`rust/lithe-core/src/build/`) and exposed through the
`plugins.declarative.*` commands in [`shared/contracts/rust-core-api.md`](https://github.com/1lck/Lithe-IDEA/blob/preview/shared/contracts/rust-core-api.md). Hosts must not
reimplement them.

Plugin authors do not need this repository. The public
[`Lithe-IDEA/lithe-plugin-docs`](https://github.com/Lithe-IDEA/lithe-plugin-docs)
repository holds the developer guide and a byte-identical copy of this whole
directory under `contract/v1/`, pinned to a revision of this repository; each
schema's `$id` is its URL there. Contract changes land here first and must then
be synced to that repository, so links in this file that leave this directory
are absolute. `plugin.json` may not carry a `$schema` key, because unknown
fields are rejected; editors associate the schema by file name instead.

## Plugin-owned toolchains (Core foundation)

The [toolchains draft](proposals/toolchains/README.md) records the replacement
design discussed in [PR #1581](https://github.com/1lck/Lithe-IDEA/pull/1581#issuecomment-6541366112).
All tool definitions belong to enabled plugins; the host supplies only generic
query, validation, resolution, persistence, and presentation mechanisms. It
does not add a built-in tool-definition table or interpret version-manager
configuration formats.

The [implemented Core contract](toolchains.md) now accepts `toolDefinitions: 1`
and `toolchainProviders: 1` declarations and provides six `toolchains.*` commands.
`executableResolution: 2` applies to tool-definition candidates only; it does not
admit new sources into existing Build candidate sets. Definitions are entirely
plugin-owned, with reserved short IDs checked against host-verified official
provenance when constructing the registry.

Neither native host advertises or integrates this foundation yet. Core consumes
captured host facts; it does not start a provider, run a probe, watch files, scan
the system, persist pins, or change current Java/Maven selection. The broader
proposal remains unsupported where it exceeds this implemented slice. In
particular, `toolchainConsumers`, generic runtime launches, settings pages, mise
and SDKMAN providers, and live backend activation are not implemented here.
Proposal envelopes remain separate from production manifests.

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
| `pluginAPIVersion` | Declarative plugin API level of the manifest format. Hosts list the levels they support; Lithe's own version is never used for compatibility. This contract defines levels `1`, `2`, and `3`; see [API levels](#api-levels). |
| `requires` | Level 3 only, and required there: every capability the manifest uses, with the version of that capability's contract it was written against; see [Capability versions](#capability-versions-level-3). |
| `vendor` | `id`, `displayName`, and `signatureRequirement` (see Trust). |
| `permissions` | Capabilities the plugin may ask the host to perform. |
| `activationEvents` | When the host may start each provider. |
| `languages` | Languages the plugin recognizes. |
| `languageServers` | At most one language server per declared language. |
| `executionProviders` | At most one run/test provider per declared language. |
| `settings` | User-adjustable plugin options (level 2 and later). |
| `ui` | Host-rendered tool windows and commands (level 2 and later). |
| `buildSystems` | Project-level build tools (level 3). |
| `toolDefinitions` | Plugin-owned tool policy ([Core foundation](toolchains.md)); requires `toolDefinitions: 1` and `executableResolution: 2`; native adapters are not connected. |
| `toolchainProviders` | Backend fact-provider declarations ([Core foundation](toolchains.md)); requires `toolchainProviders: 1`, backend/server-process capabilities and `toolchains.provide`. |

Unknown fields are refused (`plugin.manifest.invalid`) so an older host
rejects a package instead of ignoring part of it. At levels 1 and 2 a new
field needs a new `pluginAPIVersion`. From level 3 on it needs a new version
of the one capability that owns it, and only plugins that use the field
declare that version.

### Languages

`id` is lowercase (`[a-z0-9+_-]`). `fileExtensions`, `fileNames`, and
`projectFileNames` are matched case-insensitively; at least one must be
present. A leading dot is optional only in `fileExtensions` (`.php` equals
`php`). In complete file names, project markers, and management file names it
is part of the name, so `.toolrc` and `.env.example` stay hidden-file names. Optional `dependencies` lists `managementFileNames`,
`projectDependencyPaths`, and `projectBinaryPaths` relative to the project.

#### Grammars and editor configuration (`languages` 2)

`languages` 2 adds two optional fields to a language. Both are data: the host
reads them from the package and the editor applies them without starting any
process, so a language with a grammar needs no language server, backend, or
activation event, and a plugin may consist of grammars alone.

```json
{
  "id": "http",
  "displayName": "HTTP Request",
  "fileExtensions": ["http", "rest"],
  "grammar": { "kind": "monarch", "path": "grammars/http.monarch.json" },
  "configuration": {
    "lineComment": "#",
    "blockComment": ["/*", "*/"],
    "brackets": [["{", "}"], ["[", "]"]],
    "autoClosingPairs": [["{", "}"], ["\"", "\""]]
  }
}
```

- `grammar.kind` names the highlighting engine. Version 2 defines only
  `monarch`; another engine is added as a new kind in a later version, so a
  plugin can move between engines without changing anything else.
- This is a static package contribution: `languages[]` belongs to the manifest
  and `grammar.path` references a package JSON file. No public host method accepts
  inline grammar JSON to dynamically register, replace, or dispose a highlighting
  provider. Live installation/update/withdrawal of eligible static packages does
  not imply such an API or automatic reload after arbitrary file changes;
  installed packages remain read-only.
- Adding another language or grammar using the supported structure needs only
  plugin data; changing its rules does not itself raise the API version. A new
  engine or capability kind still needs an implemented host adapter and an
  explicit contract; an arbitrary new `kind` string cannot supply one.
- This contribution does not register completion, hover, definition, symbol,
  formatting, rename, or Code Action providers backed by ordinary plugin
  functions. Those independent provider bindings are not implemented; existing
  LSP support and `editor/registerActions` are separate capabilities, not a
  substitute for them.
- `grammar.path` is a package-relative file that stays inside the package.
  Hosts read it read-only from the installed package, pass its text to
  `plugins.declarative.decodeGrammar`, and hand the returned object to the
  editor as validated source text, never through a reconstructed JSON object:
  Monarch `cases` are evaluated in source order. The worker parses that text and
  defaults `start` to `root` when absent. A grammar Core refuses is `plugin.grammar.invalid` with the
  failing field (such as `grammar.tokenizer.root[3][1].log`); the language then
  opens as plain text and the rest of the plugin keeps working.
- A Monarch grammar is the JSON form of a
  [Monaco Monarch](https://microsoft.github.io/monaco-editor/monarch.html)
  definition: rule regexes are strings, and attribute values are strings or
  string lists. Core accepts at most 256 KiB, 256 states, 4096 rules, regexes
  of 2048 bytes, attribute lists of 4096 entries, 64 `cases` guards, 32
  brackets, and actions nested 8 deep. It refuses `log` actions, `next`,
  `switchTo`, and `include` targets that are not states of the grammar
  (`@a.b` resolves to the longest declared prefix, as in Monarch), `cases`
  guards naming an undeclared attribute, and `nextEmbedded` values other
  than `@pop` or a language ID. The fixture
  [`fixtures/grammars/http.monarch.json`](fixtures/grammars/http.monarch.json)
  is a complete example.
- `configuration` sets `lineComment`, `blockComment` (open and close),
  `brackets`, and `autoClosingPairs`. Each delimiter is 1 to 16 bytes without
  control characters; each list has at most 32 pairs.
- Grammar compilation and matching run only in a terminable worker. No plugin
  regex runs on the editor UI thread. Include cycles and expanded rule counts
  over 4096 are refused; a stalled worker is terminated after its local deadline.
  Buffers over 128 Ki UTF-16 units or 10,000 lines remain plain/editable. Embedded
  languages are plain text in this first worker adapter.
- Declaring `languages: 2` without using either field is
  `plugin.manifest.invalid`; using them under `languages: 1` is too.

### Language servers

| Field | Meaning |
| --- | --- |
| `languageID` | A declared language. |
| `languageIdentifier` | LSP `languageId` for documents; defaults to `languageID`. |
| `launch` | `{"kind": "packaged", "path": …}` runs an executable inside the package. `{"kind": "systemCommand", "commands": [...]}` lists bare command names the host resolves with its tool discovery (PATH, project toolchains, user overrides). API 2 adds `{"kind": "runtime", …}`; see Runtime launch. |
| `arguments` | Arguments passed to the server. Literal text at API 1; launch templates at API 2. |
| `validationArguments` | Probe that must exit with status 0 before a candidate is used; empty means the host trusts the candidate and lets the LSP handshake decide. |
| `runtimeDependencies` | Runtimes the host must discover and pass to the server. API 1 tools are `node` and `go`; API 2 adds `java`. The host exports each path as `LITHE_<TOOL>_PATH` (`LITHE_NODE_PATH`, `LITHE_GO_PATH`; a user-set value takes precedence) and prepends its directory to the server's `PATH`, because servers such as gopls run the tool themselves and an app opened from the Dock does not inherit the shell `PATH`. A project-local copy is never chosen, since servers start automatically when a file opens. |

| `initializationOptions` | API 2. A JSON object sent as the LSP `initializationOptions`. Every string value inside it is a launch template. |
| `hostIntegration` | API 2, official plugins only. A named integration implemented in the host, with the package resources it reads; see Host integrations. |

The host owns the language-server process lifecycle, the LSP session, and
stopping the process when the provider is disabled. An API 3 build provider is
the same kind of process: it declares `launch`, `arguments`,
`validationArguments`, `runtimeDependencies`, and `initializationOptions` with
the same meaning and validation; see [Build providers](#build-providers).

#### Runtime launch (API 2)

`{"kind": "runtime", "tool", "packagedRuntime"?, "minimumVersion"?,
"runtimeArguments"?, "entry"}` starts a file inside the package with a
runtime, so the package needs no launcher script. The runtime is either
shipped by the plugin (`packagedRuntime`) or discovered by the host.

| Field | Meaning |
| --- | --- |
| `tool` | `java` or `node`. It decides how the entry is passed to the runtime. |
| `packagedRuntime` | Package-relative path of the runtime executable the plugin ships, for example `runtime/${arch}/bin/java`; `${arch}` is the only variable it may use. The host starts exactly this file: it never looks the tool up on the machine, and no user override or other plugin can replace it. A plugin that needs a specific runtime owns it this way, so the host carries no knowledge of where that runtime lives. It excludes `minimumVersion`. |
| `minimumVersion` | Lowest acceptable runtime version: one to three dot-separated numbers such as `21` or `18.17`, for a runtime the host discovers. Only the components it names are compared, so `21` accepts every 21.x. A runtime whose version cannot be read does not qualify. |
| `runtimeArguments` | Launch templates placed before the entry, such as JVM options. |
| `entry` | Package-relative entry file. The command line is `<java> <runtimeArguments> -jar <entry> <arguments>` for `java` and `<node> <runtimeArguments> <entry> <arguments>` for `node`. |

The launch tool is already a requirement and must not be repeated in
`runtimeDependencies`. A runtime launch declares no `validationArguments`:
the host's probe of the runtime is its version check. The launch plan carries
the probe's `versionArguments`; the host runs the candidate with them and
passes the output to `plugins.declarative.checkRuntimeVersion`, which returns
`{satisfied, version?}`. A candidate that does not satisfy the requirement is
not used, the same as a candidate that fails a validation probe. The probe
is `-version` for `java`, which every JDK including Java 8 accepts and which
prints to stderr (hosts capture it together with stdout), and `--version` for
`node`. Java 8 and older report `1.<major>`, which is read as `<major>`.
The reported version is the first dotted number in the probe output, ignoring
lines that start with `Picked up ` (a JVM announcing `JAVA_TOOL_OPTIONS`
before its version); see `fixtures/runtime-versions.json`.

#### Host integrations (API 2)

Most of a language server is described by its launch. A few servers also need
behavior that data cannot express: a project model computed from build files,
virtual documents, test and debug wiring. That behavior is code in the host,
called a host integration. A server opts into one by name and tells it where
the files it needs are inside the plugin's own package:

```json
"hostIntegration": {
  "id": "jdt",
  "capabilities": ["debug", "run", "testing"],
  "resources": { "configuration": "language-server/configuration/${arch}", "lombokAgent": "…" }
}
```

The plugin owns the files; the host owns the behavior. The host enables an
integration only for the server that declares it and never matches on a
language ID or looks for the files anywhere else, so removing the plugin
removes the integration's inputs with it. Because an integration runs trusted
host code, only plugins in the `dev.lithe` namespace may declare one; any
other package, or an ID the host does not implement, is refused with
`plugin.integration.unsupported`.

Each resource is a package-relative path, or a list of them, that may vary
only by `${arch}`. An integration defines which names it reads; a missing
required name, an unknown name, or the wrong shape is `plugin.manifest.invalid`.

A plugin that declares a language owns its process-backed features: the host
stops running its built-in tools for that language, so a missing or disabled
plugin never falls back to them. `capabilities` is how the plugin hands a
feature back. It lists the features of the server's language that the host's
own implementation provides through the integration: `run`, `testing`, and
`debug`. A feature that is neither listed here nor supplied by one of the
plugin's `executionProviders` is unavailable for the language. Omitting the
list claims nothing.

Each integration defines the capabilities it provides and the resources each
one reads. A capability the integration does not provide, a capability whose
resource is not declared, and `run` or `testing` listed for a language whose
execution provider already supplies it are all `plugin.manifest.invalid`. The
normalized manifest lists capabilities sorted and without duplicates.

| Integration | Requires | Capabilities | Resources |
| --- | --- | --- | --- |
| `jdt` | A `runtime` launch with the `java` tool | `run`. `debug`: needs `extensionBundleDirectories`, which must contain the Java Debug Server bundle. `testing`: needs `extensionBundleDirectories` with the Java Test bundles, and `testRunner`. | `configuration` (required): the Equinox configuration directory, of which the host gives each launch a writable copy. `lombokAgent` (required): the Lombok agent JAR. `extensionBundleDirectories` (list): directories whose JAR files are loaded as JDT LS extension bundles, in declared order and then by file name. `testRunner`: the standalone Java test runner JAR. |

The launch plan returns `hostIntegration` as `{id, resources}` with every
path expanded, and lists the paths in `requiredPackagePaths`.

#### Launch templates (API 2)

`arguments`, `validationArguments`, `runtimeArguments`, and the string values
of `initializationOptions` may use these variables. A package therefore never
contains a machine path, and the host decides where state lives.

| Variable | Value |
| --- | --- |
| `${pluginDir}` | Root of the installed, read-only package. It must be used at most once per value and be followed by a `/`-rooted path inside the package; that path may vary only by `${arch}`. |
| `${stateDir}` | Writable directory the host keeps for this plugin's server and removes when the plugin is uninstalled. Not available in `validationArguments`. |
| `${workspaceStateDir}` | Writable directory for the server's state of the current workspace. Not available in `validationArguments`, nor in a [plugin backend](#plugin-backend), which belongs to no workspace. |
| `${arch}` | Host CPU architecture: `arm64` or `x86_64`. |
| `${setting:<id>}` | Current value of a declared [plugin setting](#plugin-settings-api-2). Not available in `validationArguments`, and never inside a package path. |

`plugins.declarative.languageServerLaunchPlan` expands a server's launch. The
host selects the process with exactly one of `languageID` (a language server),
`buildSystemID` (a build provider), `vcsProviderID` (a VCS provider), and
`backend: true` (the [plugin backend](#plugin-backend)), passes `{pluginDirectory,
stateDirectory, workspaceStateDirectory?, architecture, settings?}`, and
receives. `workspaceStateDirectory` may be omitted only when the selected
process does not use `${workspaceStateDir}`; otherwise the request is
`plugin.launch.invalidRequest`.

| Field | Meaning |
| --- | --- |
| `launch` | `{kind: "packaged", path}`, `{kind: "systemCommand", commands}`, or `{kind: "runtime", tool, entry, packagedRuntime?, minimumVersion?, versionArguments?}`: what the host resolves to an executable. `packagedRuntime` is the expanded package-relative path of a shipped runtime. `minimumVersion` and `versionArguments` appear together when a discovered runtime must meet a minimum version. |
| `arguments` | Complete argument list after the executable, including `-jar` and the entry of a runtime launch. |
| `validationArguments` | Expanded probe arguments. |
| `runtimeRequirements` | `{tool, minimumVersion?}` for every runtime the host must discover, a discovered launch tool included, sorted by tool. A packaged runtime is not listed. Only the launch tool can carry a minimum version. |
| `initializationOptions` | Expanded options; absent when the server declares none. |
| `requiredDirectories` | `state` and/or `workspaceState`: the directories the host must create before starting the server. |
| `requiredPackagePaths` | Sorted package-relative paths the launch points at. The host verifies each is inside the package and not a symbolic link before starting the server. |
| `settings` | Effective value of every declared setting that produced this plan; absent when the plugin declares none. |
| `buildProvider` | Present only for a `buildSystemID` selection: `{buildSystemID, executesProjectCode, mayUseNetwork, languageServer?}`. `languageServer` names the language whose server is the provider; the rest of the plan is then that server's plan, and the host reuses its running session instead of starting a second process. |
| `vcsProvider` | Present only for a `vcsProviderID` selection: the [provider descriptor](https://github.com/1lck/Lithe-IDEA/blob/preview/shared/contracts/vcs-provider-v1.md#provider-descriptor) the host keeps for the session. |
| `backend` | Present only for a `backend` selection: `{hostServices}`, the sorted [host services](#host-services-protocol-version-2) the plugin's permissions grant, plus `version: 2` for a [`backend` 2](#backend-2-workspace-contexts) process. The host passes `hostServices` to `lsp.startServer.hostServices` unchanged. |

A language without a server, an undeclared build system, a build system
without a provider, an undeclared VCS provider, and a plugin without a
backend are `plugin.launch.unavailable`. Core never creates or
reads any of these paths. The command also serves API 1
manifests, whose arguments are returned unchanged.

#### Plugin settings (API 2)

A plugin may declare options the user can change, one set per plugin and
shared by every workspace. The host shows them on the plugin's page, stores
the values, and passes the stored values as `settings` (setting ID to JSON
value) with each launch plan request. Hosts restart the plugin's language
servers when a value changes.

```json
"settings": [
  { "id": "heapMB", "type": "integer", "title": "Maximum memory",
    "default": 2048, "minimum": 512, "maximum": 8192, "unit": "MB" },
  { "id": "logLevel", "type": "enum", "title": "Log level", "default": "info",
    "options": [{ "value": "info", "title": "Information" }, { "value": "debug", "title": "Debug" }] },
  { "id": "telemetry", "type": "boolean", "title": "Send usage data", "default": false }
]
```

| Field | Meaning |
| --- | --- |
| `id` | Starts with a lowercase letter, then letters and digits. Unique within the plugin. |
| `type` | `integer` (requires `minimum` and `maximum`, optional `unit`), `enum` (requires one to sixteen `options`, each `{value, title}`; values contain only letters, digits, `.`, `_`, `-`), or `boolean`. |
| `title`, `description` | Text the host shows; the host localizes only its own chrome. |
| `default` | Value used until the user changes it. Its JSON type follows `type`, and it must be accepted by the declaration. |

Because every value is a number, a boolean, or one of the declared option
values, a setting can never inject extra arguments or change which package
file runs. A stored value the declaration no longer accepts (for example after
an update narrowed a range) is replaced by the default; a launch never fails
for it. Values for undeclared IDs are ignored. A template that is exactly one
`${setting:<id>}` keeps the setting's JSON type, so an `initializationOptions`
value can be a number or boolean; inside longer text the value is substituted
as text. Declaring settings, or referring to an undeclared one, is refused
with `plugin.manifest.invalid` or `plugin.template.invalid`. The settings
declaration is not part of an install review's program list, because no value
can change what runs beyond what the templates already show.

#### Settings v2: placement, scope, effect, and page buttons

Version 2 of the `settings` capability (`requires.settings: 2`, level 3) lets
a plugin place its options anywhere in the host's settings without the host
knowing the plugin. Hosts keep only generic registration points: a page per
language and per build system, sections, one control per setting type, a
project/global layer switch, and buttons. What appears there comes from the
manifest. Fixture: `fixtures/settings-v2.plugin.json`.

```json
"settings": [
  { "id": "dialyzer", "type": "boolean", "title": "Dialyzer", "default": true,
    "scope": "project", "effect": "immediate", "page": { "languageID": "elixir" } },
  { "id": "mixEnv", "type": "text", "title": "MIX_ENV", "default": "dev", "pattern": "[a-z]+",
    "scope": "project", "page": { "languageID": "elixir" }, "section": "Server" }
],
"settingActions": [
  { "id": "rebuildPlt", "title": "Rebuild PLT", "function": "dialyzer.rebuild",
    "page": { "languageID": "elixir" }, "confirm": true }
]
```

| Field | Meaning |
| --- | --- |
| `type` | Adds `multiSelect` (one to 32 `options`; the value is an array of distinct option values), `text` (requires `pattern`, matched against the whole value; optional `maxLength`, default 256 and at most 1024 Unicode scalars; optional `placeholder`), `file` and `directory` (an absolute path of at most 1024 Unicode scalars, or empty for "not set"; optional `placeholder`). Text and paths never start with `-` and contain no control characters. |
| `scope` | `global` (default): one value for every project. `project`: the open project may override it. |
| `effect` | When a change takes effect. `restart` (default): the next start of the plugin's processes. `immediate`: pushed to the running language server through `workspaceConfiguration`. `reload`: the next build-model reload; hosts reload the plugin's build models. `nextRun`: the next run or build command. |
| `page` | `{ "languageID": … }` or `{ "buildSystemID": … }`: the settings page that shows the setting besides the plugin's own page. Any plugin may add to a page; the host shows the page while an enabled plugin contributes to it. |
| `section` | Heading the setting is grouped under on its page. |

`settingActions` (at most 16, sorted by unique `id`) are buttons the host
draws on the plugin's page and on their `page`. Each invokes the plugin
function `function` of the same plugin with empty params, served by the
plugin's own provider process for the open project (see
[plugin functions](#plugin-functions)). `confirm: true` makes the host ask
first. The host owns the button and knows nothing about what the function
does. Declaring actions counts as using `settings` and needs version 2.

Placement and use rules, checked by Core at validation:

- An `immediate` setting may appear only in a language server's
  `workspaceConfiguration`; it never reaches a command line or
  `initializationOptions`, so a change never needs a new process.
- A `text`, `file`, or `directory` setting is a whole template value or the
  value of one `name=` argument, never part of a longer argument.
- Any v2 field or type, or any action, with `requires.settings` below 2 is
  refused with `plugin.manifest.invalid`.

**Layers.** Hosts store a global value per plugin and setting, and a project
value in the project's `.lithe/plugin-settings.json`
(`{pluginID: {settingID: value}}`, meant to be shared through version
control). They send both as `settings` and `projectSettings`; Core merges
them as project (for `scope: "project"` only), then global, then default,
skipping a stored value the declaration no longer accepts.
`plugins.declarative.resolveSettings` returns each effective value with
its `source` (`project`, `global`, or `default`).

#### Workspace configuration (`languageServers` 2)

A language server may declare `workspaceConfiguration`, an object whose
string leaves may be `${setting:<id>}` templates. With
`requires.languageServers: 2`, Core expands it with the merged settings
(`plugins.declarative.workspaceConfiguration`, and the launch plan's
`workspaceConfiguration`), answers the server's `workspace/configuration`
requests by section path from it, and sends
`workspace/didChangeConfiguration` after `initialized`. Hosts send a new
value with `lsp.updateWorkspaceConfiguration` when an `immediate` setting
changes; the running server receives it without a restart.

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

## API levels

| Level | Adds |
| --- | --- |
| `1` | Languages, `packaged` and `systemCommand` language servers, `node` and `go` runtime dependencies, run and test providers. |
| `2` | `runtime` launches with a packaged or discovered runtime, host integrations, the `java` runtime, launch templates, `initializationOptions`, and plugin settings. |
| `3` | Capability versions (`requires`), `buildSystems`: declarative build tools with detection, options, a project model, tasks, run entries, tests, diagnostics, dependencies, and sync, and [`vcsProviders`](#api-level-3-vcs-providers). |
| `4` | [`debugAdapters`](#api-level-4-debug-adapters) and `serverProcess` 2 (`runSelectedRuntime`). |

A level 2 feature in a level 1 manifest is refused with
`plugin.manifest.invalid` (`plugin.runtime.unsupported` for the `java` tool),
so a package cannot use a feature that hosts of its declared level would
reject for a different reason. Level 1 language-server arguments stay literal
at every host level.

### Capability versions (level 3)

Levels 1 and 2 version the whole manifest: a change to one section raised the
level of every plugin, and hid plugins that never use that section from older
hosts. Level 3 versions each section on its own. A level 3 manifest lists in
`requires` exactly the capabilities it uses:

```json
"pluginAPIVersion": 3,
"requires": { "buildProviders": 1, "buildSystems": 1, "languageServers": 1, "languages": 1, "serverProcess": 1 }
```

| Capability | Covers | Versions |
| --- | --- | --- |
| `languages` | `languages[]` | `1`, `2` (adds [`grammar` and `configuration`](#grammars-and-editor-configuration-languages-2)) |
| `packageTrust` | `vendor.bundledSignatureRequirement`: origin-scoped trust for a host-sealed bundled copy of a publisher-signed plugin | `1` |
| `languageServers` | `languageServers[]` apart from their launch fields | `1`, `2` (adds [`workspaceConfiguration`](#workspace-configuration-languageservers-2)) |
| `serverProcess` | The launch fields of language servers, of build providers with a process of their own, of VCS providers, and of the plugin backend: `launch`, `arguments`, `validationArguments`, `runtimeDependencies`, `initializationOptions` | `1` |
| `executionProviders` | `executionProviders[]` | `1` |
| `settings` | `settings[]` and `settingActions[]` | `1`, `2` (adds [placement, scope, effect, page buttons](#settings-v2-placement-scope-effect-and-page-buttons)) |
| `ui` | `ui` | `1`, `2` (web content), `3` (native controls), `4` ([backend-only commands](#backend-only-commands-ui-4)) |
| `buildSystems` | Declarative build detection, models, and command plans | `1` |
| `buildProviders` | `buildSystems[].provider`, including own-process and shared language-server providers; v2 tasks, v3 tests, v4 run, v5 native debug preparation, v6 read-only model inputs | `1`, `2`, `3`, `4`, `5`, `6` |
| `buildModelInputs` | Optional public model sharing between enabled workspace plugins | `1` |
| `vcsProviders` | `vcsProviders[]` | `1` |
| `debugAdapters` | [`debugAdapters[]`](#api-level-4-debug-adapters); v2 adds target arguments/environment | `1`, `2` |
| `projectGenerators` | [`projectGenerators[]`](#project-generators): entries of the New Project window | `1` |
| `backend` | [`backend`](#plugin-backend): the plugin's own long-lived process | `1`, `2` (adds [start without a page and workspace contexts](#backend-2-workspace-contexts)) |
| `toolDefinitions` | [Tool identities, layouts, discovery and four-layer candidates](toolchains.md) | `1` (Core only) |
| `toolchainProviders` | [Provider declarations and permission-bound answer validation](toolchains.md) | `1` (Core only) |
| `executableResolution` | [Shared executable candidates](#shared-executable-candidates-executableresolution-1); v2 adds tool-definition candidates without changing existing Build candidate sets | `1`, `2` (v2 Core only) |

Version 1 of every capability means what its section means at level 2
(runtime launches, launch templates, `initializationOptions`, and so on), so
moving a level 2 manifest to level 3 only adds `requires`.

- `requires` is required at level 3 and refused below it
  (`plugin.manifest.invalid`). IDs are lowerCamelCase identifiers of at most
  64 characters; versions are positive integers.
- Core reads `requires` before it decodes any section. A capability or
  version this Core build does not support is `plugin.api.unsupported` with
  `field: "requires.<capability>"`, even when the manifest also holds a
  section Core does not know, so the user learns which capability needs a
  newer Lithe instead of seeing an unknown field.
- `requires` lists exactly the capabilities the manifest uses. Leaving out a
  used one, or listing an unused one, is `plugin.manifest.invalid`. Every
  language server, and every build provider with its own process, uses
  `serverProcess`; a shared build provider does not add another process. Any
  `buildSystems[].provider` requires `buildProviders: 1`, whether it starts its
  own process or shares a language server. A template-only build plugin must
  omit `buildProviders`. Launch support alone does not implement Provider
  negotiation, requests, and lifecycle. Every VCS provider starts its own
  process, so `vcsProviders` always comes with `serverProcess`, and so does
  `backend`.
- The base fields (`schemaVersion`, `id`, `displayName`, `version`, `vendor`,
  `permissions`, `activationEvents`, and `requires` itself) change only with a
  new `pluginAPIVersion`.

Validating a capability is not running it. Core validates every capability it
supports on every platform, but each host implements only some of them, so a
host states what it runs as `hostCapabilities: { "<capability>": [versions] }`
in `plugins.declarative.validate`, `plugins.marketplace.validateIndex`, and
`plugins.marketplace.installReview`:

- `validate` and `installReview` refuse a level 3 manifest whose `requires`
  names a version missing from `hostCapabilities` with
  `plugin.api.unsupported` and `field: "requires.<capability>"`. Without
  `hostCapabilities` they check only what Core supports.
- `validateIndex` offers a level 3 version only when the host and this Core
  build both support every entry of its `requires`; without
  `hostCapabilities` it offers none. A plugin that uses no build systems is
  therefore offered on a host that cannot run them.
- `hostCapabilities` has no effect on levels 1 and 2.

The macOS host sends its capability table with validation, marketplace filtering
and install review. It advertises `buildSystems: [1, 2]` and
`buildProviders: [1, 2, 3, 4, 5, 6]`; native Provider models, dependencies, tasks, tests and launch preparation
share workspace-owned sessions. Backend and VCS support use their own entries
in the same table. Core validates supported versions without a host table,
but admission must use the actual host table. Windows does not yet advertise
Build Provider orchestration; Core protocol support alone does not enable it.

Rules for publishing across levels and capability versions:

- Levels and capability versions only add. A released version never changes
  meaning, and hosts keep supporting older versions.
- A plugin declares the lowest level, and for each capability the lowest
  version, it needs. Raising one without using what it adds only cuts off
  older hosts.
- A new capability version is added only for a change an older host must not
  ignore. Plugins that do not use the change keep the older version and stay
  installable wherever they were.
- Raising a plugin's level or a capability version requires a new plugin
  version, and its index entry keeps the last version with the previous
  requirements so older hosts still have a version to install. Published
  packages are signed and are never rewritten.
- A host release that supports a level or capability version ships before any
  plugin version that declares it.
- The manifest holds only what a host must know before it starts a process:
  what to start, with which permissions, for which files and projects. What a
  running process can answer is negotiated over its own protocol (see
  [Build providers](#build-providers)), never declared in the manifest.

## Permissions and activation

| Permission | Required when |
| --- | --- |
| `languageServer.launch` | `languageServers` or `vcsProviders` is not empty, or a build provider starts its own process |
| `process.run` | any provider declares `run` |
| `process.test` | any provider declares `test` |
| `process.build` | `buildSystems` is not empty |
| `process.vcs` | `vcsProviders` is not empty |
| `debug.launch` | `debugAdapters` is not empty |
| `debug.attach` | an adapter lists `attach` in `requests` (and only then); it also covers attaching to a remote host and port |
| `project.generate` | `projectGenerators` is not empty |
| `ui.contribute` | `ui` is declared |
| `ui.web` | a tool window shows [web content](#web-content-ui-2) |
| `backend.launch` | `backend` is declared |
| `credentials.store` | the backend uses the [credentials host service](#host-services-protocol-version-2); refused without a `backend` |
| `workspace.metadata` | the backend uses the [workspace host service](#workspace-contexts-and-capability-discovery-protocol-version-3); refused without `backend` 2 |
| `editor.actions` | the backend registers independent editor actions; requires `backend` 2 and `documents.read`, grants only `editor/registerActions`, not document edits or domain execution |

| Activation event | Meaning |
| --- | --- |
| `onLanguage:<id>` | Start the language server when a document of the language opens in a project. |
| `onRun:<id>` | Activate the run provider when the user runs a file of the language. |
| `onTest:<id>` | Activate the test provider when the user lists or runs tests. |
| `onBuildSystem:<id>` | Activate the build system before its first plan, model, or decode. |
| `onVcsRoot:<id>` | Start the VCS provider once a root of its VCS is detected in the workspace. |
| `onDebug:<id>` | Start the debug adapter when a debug session needs it (API level 4). |
| `onWorkspaceOpen` | Start the [`backend` 2](#backend-2-workspace-contexts) process once a workspace is open. Optional, names no ID, refused without `backend` 2. |

Each provider needs its event and each event needs a provider; the only
optional event is `onWorkspaceOpen`. There is no event that starts a plugin
on every launch (`onStartupFinished`, `*`): it is
`plugin.activation.invalid`. Enabling a
plugin only permits activation; nothing starts until its event occurs.

## Trust

- `publisherPackage`: the package must carry a valid publisher signature
  (`lithe-plugin-signature.json`, Ed25519 over every file) from a key the host
  trusts. Development builds may install an unsigned package from disk as a
  local development package; release builds refuse it.
- `sameTeamAsHost`: only honored for a package shipped inside the host's own
  signed installation, whose code signature already seals it.
- `none`: a community package without a required Lithe signature. A host may
  install it from a third-party marketplace source after matching the archive
  against the index checksum, or from a user-selected local ZIP or unpacked
  directory after taking a private snapshot. Both paths require the user to
  confirm the install review. IDs in the official namespace (`dev.lithe`,
  `dev.lithe.*`) may not use it (`plugin.manifest.invalid`). Hosts that predate
  this value refuse such packages as invalid manifests, which is intended.
  A signature document, when present, must still be verified; community trust
  cannot silently ignore an invalid signature.

API level 3 packages can declare `requires.packageTrust: 1` and
`vendor.bundledSignatureRequirement: "sameTeamAsHost"`, together with
`vendor.signatureRequirement: "publisherPackage"`. Only official-namespace IDs
may use this declaration. Both the primary and bundled policies must match the
host's pinned official catalog. Only a package whose actual resolved path is
inside the host's sealed installation and whose origin is `bundled` may omit
the publisher signature. Every independently installed, imported or rolled-back
copy still needs the publisher signature. A present signature is always checked,
even inside the host seal. The optional declaration alone grants no trust.
Hosts without `packageTrust: 1` filter this version before download and reject
its manifest; no new application-version field is needed. An older manifest
without the declaration keeps its existing policy. The valid example is
`fixtures/publisher-bundled.plugin.json`.

A host pins the signature requirement of its official plugin IDs so a package
cannot downgrade itself. Selecting a file from disk never overrides that pin,
namespace restrictions, publisher-key checks, or the installation seal required
by `sameTeamAsHost`. On macOS only DEBUG permits an unsigned publisher package
as `localDevelopment`; release builds refuse that origin. Community `none`
packages use their own approval path in both build configurations and must not
be reclassified as development packages.

## Marketplace

A marketplace source is a JSON index (`plugin-index.schema.json`) that lists
plugins and their release archives. Hosts fetch, cache, and download; Rust
Core decides validity and availability through `plugins.marketplace.*` so
every product shows the same catalog and the same install review.

### Sources

- The host ships one **official** source: the index at
  `Plugins/marketplace/index.json` in the Lithe repository. A copy is bundled
  read-only with the application so the catalog works offline; refreshing
  fetches the same file from
  `https://raw.githubusercontent.com/Lithe-IDEA/Lithe-IDEA/HEAD/Plugins/marketplace/index.json`.
- Hosts also preset one **community** source, Lithe Store
  (`https://github.com/Lithe-IDEA/Lithe-store`, index
  `https://raw.githubusercontent.com/Lithe-IDEA/Lithe-store/HEAD/lithe-plugin-index.json`).
  It is a third-party source in every respect (community trust, `dev.lithe`
  IDs refused), enabled by default, and removable; a host remembers the
  removal instead of adding it back.
- Users may add **third-party** sources. `plugins.marketplace.resolveSource`
  turns what the user pasted into the index URL to fetch: an https index URL
  is used as is (fragment removed); `https://github.com/<owner>/<repo>`
  resolves to `lithe-plugin-index.json` at the repository root on its default
  branch (`HEAD`); a `…/blob/<ref>/<path>` page resolves to its raw file.
  Plain http, embedded credentials, and other GitHub pages are refused with
  `plugin.source.invalid`.
- Hosts cache fetched indexes in platform cache or application-support
  storage, never inside the installation.

### Index entries

| Field | Meaning |
| --- | --- |
| `id` | Plugin ID; must equal the package's `plugin.json` `id`. |
| `name`, `author`, `description`, `license` | Display metadata; must not be empty. |
| `localizedDescriptions` | Optional translations of `description`, keyed by language tag such as `zh-Hans`. Hosts show the entry matching the interface language and fall back to `description`. |
| `repository` | `https://github.com/<owner>/<repo>` that owns the plugin's releases and issue tracker. |
| `homepage` | Optional https URL. |
| `tags` | Optional single words, lowercased and sorted by Core. |
| `icon` | Optional `raw.githubusercontent.com` file of the same repository. |
| `versions[]` | `version`, required `pluginAPIVersion`, `requires` (level 3 only, and required there: the package manifest's `requires`; capability IDs this contract does not define are allowed and make the version unavailable), `releaseDate` (`YYYY-MM-DD`), and `downloads[]`. |
| `downloads[]` | `platforms` (for example `darwin-arm64`, `darwin-x64`, `windows-x64`, `windows-arm64`), `downloadURL`, and the archive's lowercase hex `sha256`. A platform may appear in at most one download of a version. |

A `downloadURL` must be a `.zip` GitHub Release asset of the entry's own
repository (`https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>.zip`,
owner and repository compared case-insensitively), so an index cannot point a
plugin at another project's release.

### Validation and availability

`plugins.marketplace.validateIndex` accepts
`{ "index": object, "sourceKind": "official" | "thirdParty", "platform": string, "hostCapabilities"?: object }`.
A malformed index root or an unsupported `schemaVersion` rejects the whole
index. Otherwise it returns `{ "status": "ok", "index": { "plugins", "rejected" } }`:

- `rejected` lists refused entries in index order with their `error`.
  A third-party source listing an official-namespace ID is refused with
  `plugin.index.officialNamespace`; a repeated ID keeps the first listing and
  refuses later ones with `plugin.index.duplicate`.
- `plugins` is sorted by ID. Each accepted entry is normalized, lists
  `versions` newest first (each with its `requires` at level 3), reports
  `platforms`, `latestVersion`, and `latestReleaseDate` of the newest
  version, and an `availability`:
  - `{status: "available", version, pluginAPIVersion, releaseDate, downloadURL, sha256}`
    for the newest version with this platform's archive that the host can
    run: level 1, level 2 on a platform with the level 2 UI host (macOS), or
    level 3 with every capability of its `requires` hosted (see
    [Capability versions](#capability-versions-level-3));
  - `{status: "unsupported", code: "plugin.index.apiUnsupported", platform, message}`
    when the platform is listed only by versions needing a newer plugin API
    or a capability the host does not run;
  - `{status: "unsupported", code: "plugin.index.platformUnsupported", platform, message}`
    when no version lists the platform. Hosts show "not supported on
    <platform>" instead of an install action.

### Trust and install review

- **Official**: an entry is official only when it comes from the official
  source and its package passes the Lithe publisher signature.
- **Community marketplace**: entries from third-party sources. Hosts install
  in this order: verify the archive SHA-256 against the index
  (`plugin.archive.checksumMismatch`), validate the declaration and package,
  run `plugins.marketplace.installReview`, show the review, and install only
  after the user confirms. The index checksum proves a match to that index's
  bytes, not an authenticated publisher identity.
- **Community local disk**: a user-selected ZIP or unpacked directory has no
  marketplace index or authenticated repository. The host first copies a
  private snapshot, then validates and reviews that snapshot with the same
  Core command. A local checksum must never be shown as a repository match.

`plugins.marketplace.installReview` accepts
`{ "manifest": object, "expectedID"?, "expectedVersion"?, "approvedPrograms"?: [object], "hostCapabilities"?: object }`
and returns `{ "status": "ok", "review": { id, version, permissions, programs, newPrograms } }`.
A package whose ID or version differs from the index entry is refused with
`plugin.package.mismatch`, and a level 3 package that requires a capability
missing from `hostCapabilities` with `plugin.api.unsupported`. `programs` lists everything the host may start for
the plugin, sorted by `kind`, language, and tool:

| `kind` | Fields | Meaning |
| --- | --- | --- |
| `packagedLanguageServer` | `languageID`, `path`, `arguments`, `validationArguments` | Executable inside the package, with its launch arguments and validation probe |
| `systemLanguageServer` | `languageID`, `commands`, `arguments`, `validationArguments` | Command resolved by host tool discovery |
| `runtimeLanguageServer` | `languageID`, `tool`, `packagedRuntime`, `entry`, `runtimeArguments`, `arguments`, `validationArguments` | Package entry started by a runtime; `packagedRuntime` is `null` for a discovered runtime |
| `buildSystem` | `buildSystemID`, `invocation`, `options`, `tasks`, `run`, `test`, `model`, `dependencies`, `hostIntegration`?, `provider`? | Every command line the build system can plan; `provider` is the shared form, which sends build requests to a language server |
| `packagedBuildProvider`, `systemBuildProvider`, `runtimeBuildProvider` | the matching language-server fields with `buildSystemID`, `executesProjectCode`, `mayUseNetwork` instead of `languageID` | A build provider with a process of its own |
| `packagedVcsProvider`, `systemVcsProvider`, `runtimeVcsProvider` | the matching language-server fields with `vcs`, `vcsTool`, `mayUseNetwork` instead of `languageID` | A VCS provider process; `vcsTool` is the declared VCS client or `null` |
| `runtime` | `tool`, `minimumVersion`? | Runtime the host discovers and passes to a language server, build provider, or VCS provider |
| `run` | `languageID`, `executable`, `arguments` | Run command and its argument template |
| `test` | `languageID`, `executable`, `workspaceArguments`, `fileArguments`, `testCaseArguments` | Test command and its argument templates |
| `projectGenerator` | `generatorID`, `command`, `arguments`, `environment`, `collect`, `mayUseNetwork`, `timeoutSeconds`, `when` | A `command` step of a [project generator](#project-generators); `files` and `archive` steps start no program |

Each entry carries everything that decides what actually runs, so an update
that keeps the same executable but changes its arguments, argument templates,
or validation probe is a new program; language-server and build-provider
entries also carry `initializationOptions` when declared. Hosts show all
`permissions` and the complete `programs`, and persist each approved program
as canonical JSON without dropping fields. A display may use readable labels
but must retain all canonical content, including a full JSON fallback for
program kinds it cannot describe completely. On macOS, recognized kinds keep
their readable summary and offer a native “Full Program Declaration” disclosure
with the complete canonical JSON; unknown kinds already render that JSON and
do not need a duplicate disclosure.

Local disk community installation requires explicit confirmation on every first
install, update, reinstall, and same-version replacement, including unchanged
programs and permissions. An empty `newPrograms` never waives disk confirmation.
Marketplace installation retains its existing policy: first install, missing
previous approval, or nonempty `newPrograms` requires confirmation; a marketplace
update with no new programs may reuse its recorded approval. A host may pass
previous `approvedPrograms` to highlight differences, but a confirmation always
shows the complete current review. Core's review remains a pure description and
comparison, not an approval grant.
When several marketplace sources list the same ID, the user chooses the source
at install time and later updates come only from that source. Local disk
provenance is never a marketplace source or an automatic update subscription.

### Local disk snapshots and installation provenance (macOS)

The macOS disk entry accepts a ZIP or an unpacked package directory. It does
not run code from the selection. `MacPluginDiskPackageImporter` copies into a
fresh private directory (mode `0700`) before declaration validation, trust
checks, review, or installation. It refuses aliases, symbolic links, special
files, ambiguous manifests, and detected source changes during copying, and
applies archive/extracted-size and entry-count limits to the snapshot. Directory
copy depth is limited to 64, and its temporary root must stay outside the
selected source. Before extraction, ZIP preflight checks central and local
header paths/types and rejects duplicate or colliding paths.

`MacServiceContainer` injects `fileStorage.temporaryDirectory()`. Within that
platform-owned writable root the importer creates
`lithe-plugin-disk-<UUID>/archive.zip` for a ZIP and `package/` for copied or
extracted files. `archiveSHA256` is computed from the copied ZIP, not by reading
the original after review; an unpacked directory has no archive and this field
is absent/`nil`. The content digest covers the package files. Neither digest
authenticates a publisher or remote repository.

Disk digesting, Rust review, and candidate validation run on a native worker,
with a worker-owned Store decoder and immutable validation policy. The UI actor
remains available to close the page or cancel. Cancellation is checked between
review stages and before publishing the prepared candidate; snapshot cleanup
waits for the worker to finish reading it.

`PluginDiskProvenance` is host-owned local installation data, separate from
`PluginMarketplaceProvenance`; it is not a new field in `plugin.json` or the
marketplace index schema. A disk record contains the selected `fileName`,
optional `archiveSHA256`, `contentDigest`, and complete canonical
`approvedPrograms`. Marketplace provenance instead retains its source ID/name,
repository, index archive checksum, content digest, and approved programs.
Each community version must have exactly one of these provenance records;
missing or conflicting provenance is rejected.

The store rechecks the content digest of the installation staging copy before
publishing it, on every installed-package scan, and before rollback. Changed,
added, or removed package files reject that candidate or version. Active and
previous versions retain their own origin and provenance (`disk` /
`previousDisk`, `marketplace` / `previousMarketplace`); rollback verifies the
restored version against its own approval. Replacing the active version with
the same version retains the existing previous-version history; it does not
create a second rollback slot for the overwritten same-version bytes. A
marketplace entry with the same ID must not automatically offer updates or
reinstall a disk-managed installation.

The importer owns partial-copy cleanup on failure or cancellation. After
preparation the service owns the snapshot until review cancellation or install
success/failure and discards it in all these cases. Closing the plugin page
cancels its disk import and ends the installation session: pending snapshots
are discarded immediately and late prepared results are discarded rather than
installed. The package store owns its separate Application Support staging,
version directories, and installation records. None of these snapshots, staging files, installed versions, or approval
records are reusable worktree build resources: a content hash does not transfer
user consent or provide a version/platform/architecture/toolchain identity stamp.
They are excluded as `plugin-disk-install-state`. No runtime write targets the
signed app bundle or Windows installation resources, so these paths do not
change code signatures or Sparkle differential-update baselines.

Windows currently shares the schemas and Rust validation only; it has no
implementation of this declarative ZIP/directory snapshot and approval flow.
Its existing worker-package import is a separate format. The feature matrix
therefore keeps Windows `partial` and macOS runtime verification `pending`;
static checks and Node resource tests alone do not verify the UI confirmation,
complete program rendering, cleanup, or bundle hashes in a real workflow.

## API level 3: build systems

`buildSystems` describes a project-level build tool (Cargo, Go, Gradle,
Maven, …) as data. Every build tool gets the same model and the same
commands: Core validates the declaration, detects instances, decodes the
model, and expands every command line; the host only runs the processes Core
planned and passes their output back. A community plugin therefore needs no
host change to add a build tool, and no host code branches on a build-system
ID. One complete fixture covers each model source: `build-static-file` reads
a project file, `build-command-stdout` decodes a command's standard output,
`build-command-output-file` decodes a file the command writes, and
`build-host-integration` hands the model to a host integration. They use
Cargo, Go, Gradle, and Maven as realistic inputs; they are not those
plugins. `build-provider` and `build-provider-language-server` show the two
forms of a build provider, and `fixtures/build-plans.json` is the golden list
of plans and decoded outputs every host gets from them.

A build system needs `pluginAPIVersion` 3 with `buildSystems` in `requires`,
the `process.build` permission,
and the activation event `onBuildSystem:<id>`. IDs of build systems, tasks,
and run entries start with a lowercase letter and use lowercase letters,
digits, and hyphens. Option IDs are camelCase like setting IDs. Paths in a
declaration are relative, use `/`, and stay inside their base directory
(`plugin.path.invalid` otherwise).

| Field | Meaning |
| --- | --- |
| `detection` | `markers` are file names; a directory holding one is a candidate root. `nesting: "outermost"` folds deeper candidates into the outer instance (Gradle builds, Maven reactors); `"separate"` (default) keeps each (Cargo packages). `priority` (0–100, default 50) decides between plugins declaring the same ID; ties go to the smaller plugin ID. |
| `invocation` | `executables` in preference order: `projectFile` (a wrapper inside the root, with `requires` files; always runs project code), `environment` (a path below a variable listed in `environmentInputs`), `command` (a bare name found on `PATH`), `runtime` (a declared runtime dependency itself). `platforms` limits a candidate. `globalArguments` precede every command. `version` probes the executable with literal `arguments` and a `pattern` whose first group is the version; `minimumVersion` needs a probe. |
| `runtimeDependencies` | `java`, `node`, and `go` are host-managed: only `id` and `minimumVersion`, discovered with the user's runtime settings; `build.invocationPlan` returns the probe arguments Core reads their version with, so hosts keep no per-runtime probe. Any other ID describes its own `executables` and `version` probe, so the runtime list is open. |
| `options` | Build dimensions the user chooses: `boolean`, `singleSelect`, `multiSelect`, `text`, `file`, `directory`. Each contributes `arguments` and `environment` (with `${value}`) when it has a value. Choices are declared, come from the model (`choicesFromModel`), or are free (`allowCustom`). |
| `provider` | The process that answers model and dependency requests when no command prints them; see [Build providers](#build-providers). |
| `model` | `static` (a `toml` file read during detection, no process), `command` (a command whose output Core decodes; it states `executesProjectCode` and `mayUseNetwork`), `provider`, or `hostIntegration`. |
| `tasks` | The task catalog. `scopes` say what a task runs on (`workspace`, `project`, `target`); `targetTags` restrict targets; `requiresUserArguments` makes the host ask for arguments. A `fromModel` task is the template for tasks the model lists. |
| `run` | Run entries from model targets (`fromTargets.tags`, with `arguments`) or model tasks (`fromTasks`, reusing the template task's arguments). |
| `test` | How tests run: `scopes`, `targetTags`, the `filters` (`suite`, `case`) it can select, and `results` (`junitXml` or `litheTestResults` report globs relative to the project, or `hostIntegration`). A workspace run reads the globs under the root and every model project. A requested filter must reach the command line through a template whose conditions hold; a `case` guarded by `suiteSelected` therefore needs its suite. |
| `diagnostics` | `lineMatcher` patterns with capture-group numbers, or `litheDiagnostics` lines. |
| `dependencies` | A command (with `scopes`) whose output Core decodes, as a flat list through a `map` or as a tree from `litheDependencies`; `provider` (with `scopes`, `workspace` and `project` only); or `hostIntegration`. |
| `sync` | Files whose change makes the model stale, relative to the root and to each project. |
| `layout` | `excluded` directories relative to each project, added to every project as `excluded` content roots. |
| `languageImport` | The project import Lithe's Java language server performs for this build system: `kind` `maven` or `gradle`, and `options` mapping its settings to the plugin's own option IDs. `maven` has `profiles` (`multiSelect`), `settingsFile` (`file`) and `localRepository` (`directory`); `gradle` has `offline` (`boolean`) and `gradleUserHome` (`directory`). `build.languageImport` turns the user's values into the `mavenContext` or `javaGradle` input of `lsp.startServer`; settings without an option keep the language server's defaults. |

### Presentation

Each enabled build system gets a tool window of its own, titled with its
`displayName`; `icon` (a [UI icon](#ui-icons-macos-host)) is its activity-bar
icon. As for every tool window, the host owns the shell: dock, order,
visibility, layout, and lifecycle. The host draws the window body from the
model, and three optional fields tell it where an entry goes. None of them
changes a plan.

- `options[].presentation: "toolbar"` puts a boolean option on the window's
  toolbar as a toggle, for offline mode or skipping tests; it needs an
  `icon`. `"tree"` shows a multiSelect option as a checklist node at the top
  of the tree (Maven profiles). Without `presentation` the option appears only
  in the option list. An icon on an option that is not `toolbar` is
  `plugin.manifest.invalid`.
- `tasks[].category` lists 1–4 headings, outermost first, that file the task
  in its project (`["Lifecycle"]`). Without it the host files the task by
  `group`. On a `fromModel` template it is the default for the tasks the
  model lists.
- A model task in a `litheBuildModel` document can carry its own `category`,
  an array of strings. Core trims the headings. A category that is deeper
  than four headings or has an empty heading falls back to the template's, so
  a tool that reports a bad heading still has its task filed.

The macOS host gives each detected build system its own tool window and uses
these presentation fields. The host-drawn windows share Build Output, docking,
layout restoration, activation, and lifecycle with other workbench contributions.
Windows has not integrated build-system windows yet.

### Templates

Arguments are template strings, or `{ "value": …, "when": condition }` with
one condition or a list that must all hold: `projectSelected`,
`nestedProjectSelected` (a project other than the root one), `targetSelected`,
`suiteSelected`, `caseSelected`, and their `no…` opposites.

| Variable | Available in |
| --- | --- |
| `${root}` | every list |
| `${project.name}`, `${project.path}` (relative to the root), `${project.property:<key>}` | lists with a project scope; guard with `projectSelected` when the project may be absent |
| `${target.name}`, `${target.property:<key>}` | target-scoped tasks, tests, and target run entries; guard with `targetSelected` when the target may be absent |
| `${task.name}`, `${task.property:<key>}` | `fromModel` tasks |
| `${test.suite}`, `${test.case}`, `${test.case:regex}` (regex-escaped) | `test.arguments`, guarded by `suiteSelected` / `caseSelected` |
| `${optionArguments}`, `${optionArguments:<id>}` | every command list; a whole argument that expands to all options, or one option |
| `${userArguments}` | tasks and tests; a whole argument. A task with `requiresUserArguments` must pass it |
| `${pluginDir}`, `${workspaceStateDir}`, `${outputFile}` | model and dependency commands; `${outputFile}` exactly when `output` is `outputFile` |
| `${value}` | option `arguments` and `environment` |

Each option's arguments are emitted once per command line: reference them
either in `globalArguments` or in the command's list, and only once within a
list, except under opposite conditions. An option that no list references
contributes nothing. Unknown, misplaced, unguarded, or repeated variables are
`plugin.template.invalid`.

### Model and outputs

A model or dependency command prints to `stdout` (default) or to the
host-allocated `${outputFile}`. Its decoder is `jsonStream`
(whitespace-separated JSON values such as NDJSON or `go list -json`, decoded
as an array; a single document becomes a one-element array) or a canonical
format that needs no `map`. A static model file is `toml`.

A `map` only selects values. A model map turns a decoded document into
projects, each with its targets and content roots, and into option values; a
dependency map turns it into a flat list. Rules select elements with `each`,
filter them with `where` predicates (`{ "pointer", "equals" | "exists" }`),
apply only as a `fallback` or `whenFile` a file exists, and read fields with
selectors: `""` (the element), `@key` (its key), `/a/b` (relative to the
element), `$/a/b` (from the document root), `*` (each item). A field is a
selector, `{ "from", "transform": "lastSegment" }`, or a literal
`{ "value": "src" }`. Target `tags` are a literal list, and a project's
parent is the deepest project containing it. Paths are relative to the root
or absolute inside the workspace; anything else is dropped. A target `fallback` is
skipped only when a non-fallback target rule with an overlapping tag already
produced a target, so an explicit binary suppresses an implicit `src/main.rs`
target while explicit test or example targets do not.

Whatever a map cannot express is the plugin's own work: other file formats,
tasks read from the tool, explicit parent links, tags computed from values,
and dependency trees. The plugin's command (a script under `${pluginDir}`,
or the tool itself with a plugin-supplied init script, as Gradle does) prints
`litheBuildModel` or `litheDependencies`, or a
[build provider](#build-providers) answers. Unlike a static file, a command
runs only when the host starts it on request. The map does not grow into a
transformation language: a later `buildSystems` version adds a rule only when
real plugins need it and it cannot reasonably live in the plugin.

Canonical formats let a plugin's own script print the shape Core expects:

| Format | Shape |
| --- | --- |
| `litheBuildModel` | `{ "format": "litheBuildModel", "version": 1, "projects", "targets", "tasks", "contentRoots", "optionValues" }` with the model's field names; `tasks[].category` is an array of headings |
| `litheTestResults` | `{ "format": "litheTestResults", "version": 1, "tests": [{ "suite", "case", "status", "message"?, "durationMillis"?, "path"?, "line"? }] }` |
| `litheDependencies` | `{ "format": "litheDependencies", "version": 1, "dependencies": [{ "name", "group"?, "version"?, "scope"?, "properties"?, "children" }] }` |
| `litheDiagnostics` | output lines `{ "lithe": "diagnostic", "path", "line", "column"?, "severity"?, "message" }` |

Unknown fields in canonical documents are ignored so newer scripts work with
older hosts. Output that does not fit its decoder is `plugin.build.invalidOutput`.

### Provider task execution (buildProviders 2)

A task with `source: "provider"` requires `requires.buildProviders: 2` or newer.
It keeps the ordinary task ID, scopes, target tags and model selection, but
`arguments` must be `[]` and `execution` must be `task`. Application/service
launch and test discovery are separate capabilities. Provider model-task
templates cannot be referenced by `run[].fromTasks`; they need a typed Run
capability rather than an empty command plan. A provider task never
falls back to a host command or a plugin-private function. Command tasks
retain their current shape and omit `source`.

`build.taskPlan` returns a `provider` request instead of argv for this source.
`lithe/build/execute` receives the effective `buildSystemID`, workspace-relative
`root`, `options`, `optionArguments`, option `environment`, `task` declaration ID,
bounded `userArguments`, and optional `project`, `target`, `modelTask` selections
(`name`, workspace-relative `path`, `tags`, `properties`). Scope/path validation
is identical to command tasks. The provider owns build semantics; options
are not a second host-generated command. As with model/dependency requests,
the host may add `tool: { executable: <resolved absolute path> }` from the
same invocation resolver; explicit invalid tool/runtime selection is a failure,
never permission for independent discovery. It must reject stale project facts
rather than guess a target.

The host offers `litheBuild.versions: [6, 5, 4, 3, 2, 1]`. Version 2 adds task execution
and its progress notification to the two version 1 methods. A process that
chooses version 1 cannot receive execution; unsupported negotiation fails
explicitly. A plugin that needs this behavior declares capability version 2
so unsupported hosts refuse installation. The two version numbers serve
different purposes: installation admission and per-process negotiation.

Core sets `params.operationID` to the unique JSON-RPC request ID (as a string);
callers cannot choose it. `lithe/build/progress` notifications echo that ID and
may include `message` (up to 4 KiB UTF-8), integer `percentage` (0–100), and
`output` (up to 64 KiB UTF-8 per notification). Malformed reports and reports
for ended, cancelled, timed-out or other requests are dropped. Core maps the
wire ID back to the host operation ID; reused host IDs cannot accept old
progress. No plugin-function negotiation is needed.

The reply is `{ "exitCode": <signed 32-bit integer>, "output": <string> }`.
`output` is the complete bounded diagnostic text (at most 32 MiB UTF-8),
including text streamed in progress; the host displays progress output and
uses final output for the existing diagnostic decoder without duplicating it
in the console. Nonzero exit codes are completed tool failures, not protocol
errors. Malformed replies end with `plugin.build.invalidResult`; JSON-RPC
errors end with `plugin.build.failed`. Timeout and cancellation use the
existing request codes and `$/cancelRequest`. Request completion occurs once;
late replies/progress do not revive it.

The host binds each call to the plugin package, build-system/workspace
session, current run, effective option fingerprint and watched configuration revision.
Settings, package replacement, disable, workspace close/reopen, cancellation
and backend failure invalidate or stop the owning operation. The existing
Provider session owns children and writable workspace state; no page,
additional runtime, directory or cross-plugin private cache is required.
Only public typed results may cross domain boundaries.

Canonical examples: `fixtures/build-provider-execution.plugin.json` and
`fixtures/build-execution-protocol.json`. Protocol v2 is a construction
primitive for #1495; it does not by itself migrate Maven or Java consumers.

### Provider test execution (buildProviders 3)

A build system's `test` may declare `source: "provider"` with
`requires.buildProviders: 3`. It retains the existing scopes, target tags and
supported filters, but `arguments` must be `[]`. It requires a plugin-owned
Provider process; `results` may be omitted or use `junitXml`/`litheTestResults`
reports. `hostIntegration` is refused: the plugin owns test execution and
report production, and the host reuses the existing report decoder.

`build.testPlan` returns `provider: { method: "lithe/build/test", params }`
and the usual `results` metadata instead of argv. The effective
`buildSystemID`, `root`, `options`, `optionArguments`, `environment`, bounded
`userArguments`, optional `project`/`target`, and optional `suite`/`case` are
typed fields. A case filter does not require a suite when the provider
supports it; providers must reject selectors they cannot honor rather than
widening the test run. Paths, scopes and declared filters are validated before
the request is sent. The host's report project list only resolves report globs;
it is not a second backend project model.

Only a process choosing protocol version 3 or 4 receives `lithe/build/test`.
Versions 1 and 2 explicitly refuse tests. Version 3 retains every version 2
task behavior. Tests use the same Core-assigned operation identity,
`lithe/build/progress`, tool hint, bounded `{ exitCode, output }` result,
timeout, cancellation and late-result rules as task execution. Reports are
read after execution using the existing freshness, path and size checks.
Workspace-wide reports still require a current project model when the build
system has one. Configuration validity is retained through diagnostic and
report decoding; late results cannot update a changed workspace/configuration.

Java/Maven migration remains separate. No new resource/cache location is introduced.
Canonical examples: `fixtures/build-provider-tests.plugin.json` and
`fixtures/build-test-protocol.json`.

#### Test discovery

Provider tests may additionally declare `discovery: true`. This requires both
`suite` and `case` filters: every discovered selector must be exactly runnable.
`build.testDiscoveryPlan` accepts the common plan fields and optional `refresh`
and `tool`, returning a request for the whole instance:
`lithe/build/discoverTests` with its effective options. Project/output-file
selection is refused. This method also requires protocol version 3 or 4 and uses
the existing bounded request/cancellation lifecycle, without execution progress.

The provider returns `{ "format": "litheTestDiscovery", "version": 1,
"tests": [{ "suite", "case", "project"?, "target"? }] }`. Project and target
are the usual typed selections with workspace-relative paths. There may be at
most 10,000 items and 32 MiB UTF-8 JSON. Unknown document/item fields are
ignored; malformed selectors, invalid paths/scopes, unsupported versions and
oversized lists reject the entire result with `plugin.build.invalidOutput`.
An empty array is a successful discovery with no tests.

The host passes the reply and original plan configuration to
`build.decodeTestDiscovery`. Core validates every selector through the same
test-plan rules, deterministically orders the list, collapses exact duplicates,
and derives an opaque `id` including project/target identity. Equal suite/case
names in sibling modules therefore remain distinct. The returned `discovery`
contains `tests: [{ id, suite, case, project?, target? }]`. No source parsing,
framework detection, or second project graph occurs in the host/Core.

Native discovery starts only on a user action, reuses the workspace Provider,
and is independent of plugin pages. Source edits, configuration changes,
package changes and workspace teardown revoke the cached list and in-flight
discovery. A native action must revalidate the selected ID against the current
list before submitting its exact selectors to `lithe/build/test`; stale
toolbar selections cannot run. The backend must reject a selector whose facts
have become stale externally. Canonical example: `fixtures/build-test-discovery.json`.

### Provider run preparation (buildProviders 4)

A run declaration may use `source: "provider"` with
`requires.buildProviders: 4`. This increment supports application targets only:
`fromTargets.tags` is required; `fromTasks`, service execution, nonempty
`arguments`, and extension templates are refused. The optional `name` is a
literal display name. `workingDirectory` is supplied by the prepared result;
the declaration's command-source default has no effect. These declarations
never generate empty command-based persisted Run entries.

`build.prepareRunPlan` validates a selected `run` declaration ID, required
`project` and `target` selections, effective options, and bounded
`userArguments`. It returns a provider request for `lithe/build/prepareRun`,
with the common instance fields, options/option arguments/environment,
`run`, `project`, `target`, and `userArguments`. An output file is refused.
The host may add the resolved build tool hint. The provider owns upstream
synchronization, build, classpath and launch facts; Core does not reconstruct
those facts from source files or build configuration.

Protocol versions 4 and 5 accept this method. Version 4 retains task and test
support. Preparation shares the Core-assigned wire `operationID`, progress,
timeout, cancellation and stale-result handling of execution. It ends when
preparation finishes; the application is a separate host-owned process.
A JSON-RPC error aborts preparation and cannot launch an application. It retains
the common LSP `serverError` category; it is not an execution exit-code result
and does not forward a private-function `pluginErrorCode`.

The successful result is a portable launch plan:

```json
{
  "executable": { "kind": "toolchain", "value": "project-jdk" },
  "arguments": ["-cp", "classes", "example.Main"],
  "workingDirectory": "app",
  "environment": {}
}
```

The executable is either a host toolchain identifier (`toolchain`) or a bare
command resolved by the host (`command`); absolute paths and shell command
strings are refused. Arguments are separate strings, at most 1,024 entries
and 64 KiB UTF-8 each, without NUL. The environment has at most 64 entries;
keys match `[A-Za-z_][A-Za-z0-9_]*` with at most 128 bytes, values are strings
of at most 64 KiB without NUL. The complete JSON is bounded at 32 MiB.
`workingDirectory` must be an existing workspace-relative directory inside
the selected instance, including after resolving filesystem aliases.
Unknown fields are ignored. The host calls `build.decodeRunPreparation`
with its workspace root, instance root and raw result; any malformed plan
fails as `plugin.build.invalidOutput` before executable resolution.

#### Native debug preparation (version 5)

A provider run may additionally declare `debug: {"adapter":"native"}` with
`requires.buildProviders: 5` and `requires.debugAdapters: 2`. `adapter` is a
local ID declared by this plugin; qualified cross-package references are refused.
The adapter must serve launch of executable targets, with bindings `program` ←
`target.path`, `cwd` ← `target.workingDirectory`, `args` ← `target.arguments`,
and `env` ← `target.environment`. These fields cannot be overridden by adapter
default arguments. This first increment covers native executable launch only;
it does not accept attach endpoints, backend-selected adapters or arbitrary DAP JSON.

`build.prepareDebugPlan` validates the same selected run/project/target and
arguments as run preparation and returns `lithe/build/prepareDebug`. Only wire
version 5 accepts it. Progress, cancellation, timeouts, tool hints, workspace
ownership and JSON-RPC failure handling follow run preparation. A successful result
contains exactly these four fields:

```json
{"program":"app/bin/sample","arguments":["a b","x#y"],"workingDirectory":"app","environment":{}}
```

The provider owns synchronization/build before returning. `program` is an existing
workspace-relative regular file contained in the selected instance, including
canonical symlink resolution. Arguments, environment and directory retain run
preparation's size and containment limits. Unknown fields are refused here; there
is no adapter process, socket, shell, private function or DAP argument channel.
`build.decodeDebugPreparation` takes the selected `run` separately and returns
`preparation` with its validated `root`, declaration-owned `adapter`, and these
four fields. Missing, malformed and escaping targets fail before adapter startup.

The native host saves documents before preparation, retains model/configuration/
source/plugin identity through decode, and drops stale results. It checks executable
permissions and canonical containment again at handoff. `debug.adapters.startArguments`
binds the validated target facts; the existing Registry launches the adapter using
its own permissions and package process declaration. The launch configuration retains
`pluginID/adapterID` for routing and retry. Stopping preparation cancels only its
operation; the Debug host owns launched sessions and plugin withdrawal cleanup.
Saved Run configurations keep their existing selectors and prepare again for Debug.

Fixtures: [native declaration](fixtures/build-provider-debug-preparation.plugin.json)
and [native result](fixtures/build-debug-preparation.json). This does not provide
Java/JDT preparation, long-running services or cross-plugin collaboration.


The native Build tree re-resolves model IDs before preparation. Source/model,
option, settings, package and workspace changes revoke a pending preparation.
After validation the existing Run host resolves the executable and owns output,
stop, exit status, and argument-resource cleanup. Workspace teardown and plugin
disable stop the application by its exact host operation ID; an old owner
cannot stop a replacement process. The Run host can explicitly save a selector to the existing local Run v2 layer
as `provider: "build.provider"` with `extensions.build`. The reference contains
`pluginID`, `buildSystemID`, instance `root`, `run`, `projectID`, `targetID`, and
raw `userArguments`, never an executable, environment, or cached classpath.
Every restart re-resolves the enabled instance/model and sends a fresh preparation.
Missing plugins/targets/models fail explicitly; there is no command fallback.
Saving and running work before detector-generated Run configurations exist.
Service coordination, debug target registration and Java/Maven migration remain
separate. See `fixtures/build-provider-run-preparation.plugin.json`
and `fixtures/build-run-preparation.json`.

### Optional read-only model inputs (buildModelInputs 1)

A producer opts into `buildSystems[].modelSharing: { options: [<optionID>] }`.
Only normalized `projects`, `targets` and `contentRoots`, including their
ordinary public metadata, are published. Tasks, run entries, settings,
`optionValues`, process handles and private functions are excluded. The
options list names existing ordinary build options whose **effective values**
may be shared; omitted options stay private. A configuration fingerprint
identifies all effective options without publishing their values.

A consumer declares `modelInputs: [{ pluginID, buildSystemID }]`, requires
`buildModelInputs: 1` and `buildProviders: 6`, and owns a provider and model.
Slots are exact optional identities; Core sorts them by plugin ID and build
system ID and rejects duplicates. Version 1 producers cannot also consume
inputs, so consumers cannot recursively re-export a model.

The native host calls `build.resolveModelInputs` with the consumer manifest
and `{revision, sources: [{manifest, instances: [{buildSystemID, root, state,
model?, options?}]}]}`. Sources are enabled installed packages in the current
workspace activation, never identities supplied by another backend.
Input states are `ready`, `loading`, `stale`, or `failed`; only ready
instances include a complete normalized model. A truncated model becomes stale.
Core revalidates source manifests, ownership, shape and path containment and
returns `modelInputs: {version: 1, revision, inputs}`, where each input is:

```json
{
  "pluginID": "dev.example.source",
  "buildSystemID": "source",
  "state": "available",
  "instances": [{
    "root": "app",
    "state": "ready",
    "model": {"projects": [], "targets": [], "contentRoots": []},
    "configurationFingerprint": "<64 lowercase hex characters>",
    "options": {}
  }]
}
```

A missing, disabled, non-public or mismatched producer gives
`state: "unavailable", instances: []`. An installed public producer with no
detected instance is available with an empty list. A non-ready instance has
only `root` and `state`; no old model or options travel with it. Roots and
model paths remain workspace-relative, and instances are deterministically
ordered. There are at most 8 slots, 64 instances per source, 2,000 projects and
10,000 targets/content roots per instance, and 8 MiB of resolved JSON. The
revision is a nonnegative integer no larger than 9,007,199,254,740,991.

The host supplies this snapshot as the common plan request's optional
`modelInputs`. It is required exactly for a consumer with declared slots.
Every Provider plan copies it unchanged into `params.modelInputs`; Core
revalidates the snapshot and rejects extra fields or mismatched slots.
The running backend must negotiate `litheBuild` version 6 independently of
manifest admission. Older versions reject an input-bearing request even for
an existing method such as `lithe/build/model`.

A revision belongs to one workspace activation. The host revokes consumer
model/dependency loads, discovery and in-flight execution/preparation when a
producer's model, options, watched configuration or package availability
changes. Revisions also detect changing an option away and back before a reply
arrives. Guard the result after decoding as well as after the RPC; do not
publish an old reply merely because cancellation was ignored. Already launched
applications retain their existing native ownership.

This facility never installs or activates a producer, invokes its private
functions, grants permissions, leases a process or resolves a package version.
There is no general plugin-dependency/export API. Backend authors must handle
unavailable and non-ready slots explicitly. Language integration and existing
Java/Maven business migration remain separate work. Shared fixtures:
`fixtures/build-model-producer.plugin.json` and
`fixtures/build-model-consumer.plugin.json`.

### Build providers

Some tools expose their model only through their own API (the Gradle Tooling
API, Mix inside the BEAM). Their plugin declares `provider`: a long-lived LSP
base-protocol process of the same kind as a language server, which answers
`lithe/build/model` and `lithe/build/dependencies`. It has one of two forms,
told apart by the `languageServer` key; mixing them is
`plugin.manifest.invalid`.

| Form | Fields |
| --- | --- |
| Shared | `{ "languageServer": "<languageID>", "executesProjectCode", "mayUseNetwork" }`. The named language must have a language server in the same plugin; the host sends the requests to that session. |
| Own process | The language-server process fields (`launch`, `arguments`, `validationArguments`, `runtimeDependencies`, `initializationOptions`) plus `executesProjectCode` and `mayUseNetwork`. Validation, launch templates, settings, and the install review are those of a language server, so it needs the `languageServer.launch` permission and is listed as a `packagedBuildProvider`, `systemBuildProvider`, or `runtimeBuildProvider` program with its `buildSystemID` and flags. |

`model.source: "provider"` and `dependencies.source: "provider"` use it. A
provider no source uses, or a provider source without a provider, is
`plugin.manifest.invalid`. Detection never starts a provider: its instances
report `modelSource: "provider"` without a model.

The host starts the process from `plugins.declarative.languageServerLaunchPlan`
with `buildSystemID`. For a provider source, `build.modelPlan` and
`build.dependencyPlan` return `provider: { method, params }` instead of
`arguments`, with the request's `decoder` (`litheBuildModel` or
`litheDependencies`) and the declared `executesProjectCode` and
`mayUseNetwork`:

| Param | Meaning |
| --- | --- |
| `buildSystemID`, `root` | The instance. A model request always covers the whole instance. |
| `options` | Effective option values by option ID. |
| `optionArguments`, `environment` | What the options contribute, for a provider that runs the tool. |
| `project` | Dependencies only: `{ name, path }` of the selected project, or `null` for the workspace. |
| `refresh` | Optional; `true` when the user asked to reload (Reload, Retry, a page's `build.refresh`) or the host reloads after a `sync` file changed. The provider must then recompute instead of answering from a cache or snapshot of its own. Absent or `false` for a first load, which a provider may answer from a snapshot it still trusts. |
| `tool` | Optional; `{ executable }`, the absolute path of the build tool the host resolved from the build system's `invocation` the same way a task run does (project wrapper, environment variable, `PATH`, the user's override), so the provider need not repeat the lookup. Absent when the host could not resolve it; the provider then looks the tool up itself. It is never a reason to fail the request. |

The host passes `refresh` and `tool` in the `build.modelPlan` and
`build.dependencyPlan` requests; Core validates `tool.executable` as an
absolute path (`plugin.build.invalidSelection` otherwise) and copies both into
`params` only when they are set, so a request without them is the same as
before they existed. Command sources ignore both. Both are optional data
within protocol version 1.

The host passes the JSON result of the request as `result` to
`build.decodeModel` or `build.decodeDependencies`, which decode it like the
canonical format of a command; a missing result is
`plugin.build.invalidSelection`, and a result over the output limit or of
another format is `plugin.build.invalidOutput`.

The manifest only says how to start the provider and which sources use it.
Everything else is negotiated in the LSP `initialize` exchange, so a provider
can add optional data within a negotiated protocol version:

- The host sends `capabilities.experimental.litheBuild: { "versions": [6, 5, 4, 3, 2, 1] }`,
  the build-provider protocol versions it speaks. Version 1 is the two
  requests above with the params and result formats of this section;
  version 2 adds typed task execution; version 3 adds typed test execution
  and discovery; version 4 adds application run preparation; version 5 adds native debug preparation;
  version 6 accepts the host's explicitly declared read-only model inputs.
- The provider answers `capabilities.experimental.litheBuild: { "version": 1 }`
  with the version it chose from that list. A provider that answers no
  version, or one the host did not offer, is not used for build requests; a
  shared provider still serves its language.
- Both sides ignore fields they do not know in these objects and in request
  params and results, so either side can add optional data within a version.
  A change the other side must not ignore needs a new protocol version.

A host that declares `buildProviders` keeps providers apart:

- One process per plugin, build system, and workspace. Two plugins never
  share a process, and the host never relays messages between processes; each
  speaks JSON-RPC only with the host, over its own stdio.
- The shared form reuses a language server session of the same plugin only.
- A provider starts on the first build request, which only a user action
  sends, and stops when its workspace closes, its plugin is disabled, or
  before its package is replaced, rolled back, or uninstalled. A change of
  the plugin's settings restarts it on the next request, so its launch
  arguments always reflect the current values. A provider that exits is
  started again by the next request.
- Installation refuses a package whose provider launch points at a missing
  file, a path outside the package or through a symbolic link, or a packaged
  executable or runtime that is not a regular executable file.
- Its writable state lives in the plugin's state directory for that build
  system, never in the plugin package or the host's installation.

### Host integrations

`hostIntegration` names host code that owns one concern while a built-in tool
migrates onto this model. Only official plugins may name one, and only
`maven` exists; a model, test-result, or dependency source of
`hostIntegration` needs it. Anything else is
`plugin.integration.unsupported`. New build systems use the declarative
contract or a canonical format instead.

### Commands

The `build.*` Core commands (see `shared/contracts/rust-core-api.md`) take the
manifest, the build-system ID, and a request, and revalidate the manifest
every time. `build.detect` walks the workspace once for all enabled plugins
and returns instances, with the model of `static` and `hostIntegration`
sources. `build.invocationPlan` and `build.checkToolVersion` resolve the
executable; `build.resolveOptions` checks stored option values and returns
the configuration fingerprint; `build.modelPlan`, `build.taskPlan`,
`build.testPlan`, and `build.dependencyPlan` return argv plans, or provider
requests for a provider source;
`build.decodeModel`, `build.decodeTestResults`, `build.decodeDiagnostics`,
and `build.decodeDependencies` normalize output or a provider result; `build.syncFingerprint`
digests the watched files. A selection the declaration does not allow is
`plugin.build.invalidSelection`; an operation it does not declare is
`plugin.build.unavailable`.

## API level 3: VCS providers

`vcsProviders[]` declares version control systems the plugin implements, each
through its own LSP base-protocol process: the VCS ID, the static markers that
identify a root, metadata paths the host watches, the VCS client the provider
drives, and the shared [`serverProcess`](#capability-versions-level-3) launch
fields. The ID `git` is reserved for the built-in support
(`plugin.vcs.reserved`). Capabilities belong to the running process and are
negotiated in `initialize` under `experimental.litheVcs`, never declared in
the manifest.

Detection never starts a process: `vcs.detectRoots` finds roots from the
markers, and the host starts a provider only after a root of its VCS is
found. The install review lists the provider as a `…VcsProvider` program with
its VCS client (`vcsTool`) and `mayUseNetwork`. Requests go through
`lsp.vcsRequest` by operation name and replies are normalized by
`vcs.decodeReply`. The fields, operations, reply shapes, and error codes are
defined in [the VCS provider contract](https://github.com/1lck/Lithe-IDEA/blob/preview/shared/contracts/vcs-provider-v1.md).

## API level 4: debug adapters

`debugAdapters[]` declares debug adapters the plugin implements. Each one is a
DAP process the host starts and talks to over stdio or a loopback TCP port, or
a debug server hosted by the plugin's own language server.
The declaration is data only: there is no resolver, workflow, host integration,
or `initializationOptions`, and any such field is refused. Requires
`requires.debugAdapters` 1, `debug.launch` (plus `debug.attach` when an
adapter serves `attach`), and one `onDebug:<id>` activation event per adapter.
A manifest below level 4 may not declare `debugAdapters`, and a level 3 manifest may not require `debugAdapters` or `serverProcess` 2.

| Field | Meaning |
| --- | --- |
| `id`, `displayName` | Plugin-local ID (unique in the plugin) and its title. |
| `adapterID` | DAP `initialize.adapterID`; defaults to `id`. |
| `requests` | `launch` (default) and/or `attach`. |
| `selectors[]` | Optional automatic matching by `targetKinds` and `languageIDs`; absent means explicit selection only. |
| `configurationTypes` | Imported `launch.json` `type` values the adapter answers to. |
| `configurations.launch/attach` | Default DAP `arguments`, a packaged `parametersSchema`, and `targetBindings` (`program` ← `target.path`, `processId` ← `target.processID`, `cwd` ← `target.workingDirectory`, and for `attach` only `connection` ← `target.host`, `target.port`, `target.pathMappings`; version 2 also supports bounded `args` ← `target.arguments` and `env` ← `target.environment`; see [Remote attach](#remote-attach)). A configuration for an undeclared request is refused. |
| `configurations.launch.executable` | For a target that is a source file the adapter cannot debug directly (C, C++, Swift): `setting` names a `file` setting of the plugin, `candidates[]` (up to 8) are the paths a host looks for when the user chose nothing. Each candidate starts with `${workspaceFolder}/` or `${fileDirectory}/`, may use `${fileBasenameNoExtension}`, and has no `..`. Declare it together with `targetBindings.program: "target.executable"` and neither without the other; a launch fills `program` with the path the host settled on. The user's setting always wins: a chosen path that is not a runnable file is an error, not a reason to try the candidates. The host shows the path it found in that setting, and the setting's `description` is where the plugin teaches how to produce the program. |
| `capabilities.disabled` | Standard DAP `supports*` names or `exceptionBreakpointFilters` the host treats as absent. |
| `console.commandPrefix` | Text (1–8 characters, no spaces; for lldb-dap a backtick) the adapter's console reads as "what follows is a debugger command". The host puts it before the typed line only when it asks the adapter to complete, and moves the adapter's answer back, so the user never sees it. An adapter that treats a bare word as an expression (lldb-dap) otherwise mixes language keywords such as `long` into the first word's completions; the prefix limits them to commands. Declare at least this or `console.commands[]` when `console` is present. |
| `console.commands[]` | Debugger commands (`name`, optional one-line `description`) the Debug Console offers as completions. An adapter that answers the DAP `completions` request completes live, so list commands only for an adapter that does not (or whose live answers lack some commands); the host merges both. Names are inserted as written, unique, and not padded with spaces; descriptions are shown as written and not translated. |
| `launch.process` | The shared `serverProcess` launch fields without `initializationOptions`, or `{"launch": {"kind": "runSelectedRuntime", "tool": "python" \| "java" \| "node"}}`, which needs `serverProcess` 2 and is the only use of it. Required for every transport except `tcpLanguageServer`, which must not have it. |
| `launch.transport` | `stdio`, `tcpAnnounced` (`endpoint`: `stream`, one-line `prefix`, `value` = `port` or `hostPort`), `tcpPort` (`endpoint.port`), or `tcpLanguageServer` (`endpoint`: `languageID`, `command`). TCP endpoints are loopback only. |
| `launch.endpoint` for `tcpLanguageServer` | For an adapter that lives inside a language server and has no process of its own (the Java Debug Server runs in JDT LS). `languageID` names a `languageServers[]` entry of the same plugin; `command` (1–128 characters of letters, digits, `.`, `_`, `:`, `-`) is the `workspace/executeCommand` the host sends to that server for each session. The server answers with the loopback port to connect to, as an integer or a numeric string from 1 to 65535. The host starts the language server for the workspace first, as it does for editing. The command is part of what the user reviews at install and update, and changing it asks again. |

### Remote attach

An adapter that attaches to a debuggee on another machine (a JVM started with
`-agentlib:jdwp`, a Node inspector, gdbserver) is an
ordinary `attach` adapter whose `targetBindings` carry a `connection`. The
adapter itself still runs on this machine, stdio or loopback as before; only
the debuggee is remote. This is the adapter-to-debuggee endpoint, not the
IDE-to-adapter DAP endpoint. By default, debugpy `--listen` starts a DAP adapter
on the target machine: the IDE must connect to that adapter, not start another
local adapter and merely pass it `connect.host` and `connect.port`.

`connection` does not declare an external DAP endpoint or remote adapter
execution (for example `ssh host gdb -i=dap`). These require separate host
integration; this contract and its validation do not establish that support.
The current transport scope is ordinary TCP connection and lifecycle, reusing
the existing socket implementation and retaining stdio. It does not add proxy,
tunnel, port-forwarding or SSH execution settings, or relax the loopback rule
for language-server-provided DAP endpoints. Adapter-native source mapping should
be reused where applicable, without translating the same path pair again in Core.

The following illustrates nested argument binding and mapping shape, not a
complete debugpy `--listen` connection configuration:

```json
"configurations": {
  "attach": {
    "arguments": { "timeout": 5000 },
    "targetBindings": {
      "connection": {
        "host": "connect.host",
        "port": "connect.port",
        "pathMappings": { "shape": "objects", "argument": "pathMappings",
                          "localKey": "localRoot", "remoteKey": "remoteRoot" }
      }
    }
  }
}
```

- The values of `connection` are paths into the adapter's `arguments`, because
  adapters name and nest them differently: java-debug takes `hostName` and
  `port`, nested arguments may use `connect.host` and `connect.port`, js-debug
  `address` and `port`, gdb one `host:port` string. A path is 1–4 dot-separated names of
  letters, digits, `_`, and `-` (up to 64 characters each) and Core creates the
  intermediate objects.
- `host` and `port` are declared together. `address` takes the endpoint as one
  `host:port` string, with an IPv6 host in brackets (`[2001:db8::1]:2345`); it
  stands in for `host` and `port`, or is a further destination beside them.
  At least one of the two forms is required.
- `pathMappings` is optional and has four shapes, one per way adapters take
  source roots:
  - `objects` fills a list of objects, one per mapping: `argument` names the
    list, `localKey` and `remoteKey` the keys of each object
    (`[{ "localRoot": …, "remoteRoot": … }]`).
  - `first` is for an adapter with a single pair of roots and fills `local`
    and `remote` from the one mapping. It takes exactly one: a target with
    more is refused rather than truncated.
  - `dictionary` fills an object at `argument` whose keys are the roots of one
    side and whose values are the other (`"keyedBy": "remote"` gives
    `{ "<remote>": "<local>" }`). A target with the same root twice on the
    keyed side is refused, since an object holds one value per key.
  - `pairs` fills a list of two-element arrays at `argument`, in the order
    `"order": "remoteLocal"` (`[["<remote>", "<local>"]]`) or `"localRemote"`.
  An adapter whose mapping is none of these declares no `pathMappings`, and a
  start that sends mappings to it is refused.
- A destination may not equal, contain, or sit inside another destination, the
  `processId` or `cwd` argument a declared binding of the same configuration
  fills, or a name that the configuration's own `arguments` already sets. Defaults win over bindings, so without this rule
  the adapter would connect somewhere other than the endpoint the user
  confirmed. A manifest that does it is `plugin.manifest.invalid`.
- `connection` is allowed under `attach` only. `selectors[].targetKinds` may
  list `connection`, and only for an adapter that declares the binding.

The target of a start is `{ "kind": "connection", "host", "port",
"pathMappings"?: [{ "local", "remote" }] }`. `host` is a DNS name or an IP
literal of 1–253 characters, with labels of up to 63 letters, digits, and
hyphens, none leading or trailing: no scheme, port, brackets, whitespace, or
user. A dotted run of digits must be a valid IPv4 address, and IPv6 zone IDs and
internationalized names (use punycode) are not accepted. `port` is 1–65535.
There are at most 16 mappings; each root is 1–1024 characters without control
characters, and a `local` root must be an absolute path on the host's
platform.

`debug.adapters.startArguments` answers with the filled `arguments` and a
`connection: { host, port, remote }`. `remote` is `false` only for what
Core can prove local from the text: `localhost` (any case), `127.0.0.0/8`, and
`::1`. Every other host, including `0.0.0.0`, `::ffff:127.0.0.1`, and
`localhost.example.org`, is `remote: true`. A host asks the user to confirm each
`remote` endpoint it has not been told to trust, and does not remember the
answer by default. `debug.attach` covers remote attach; there is no separate
permission. `plan.debugAdapter.remoteAttach` in the launch plan is
`{ "pathMappings": boolean, "maxPathMappings": number }` for an adapter that
takes a connection (`maxPathMappings` is 0 without mappings, 1 for `first`, and
16 otherwise) and `null` otherwise, so a host knows whether to offer the
host-and-port form and the mapping list, and how many rows the list may hold.

The cases in `fixtures/debug-adapter-rejections.json` state the stable code and
field for each refusal and the layer that reports it: `schema`,
`coreManifest`, `corePlan` (one start: stale registration or runtime
selection, a target missing a fact a binding reads; the request defaults to
`launch` and `context.request` sets `attach`), and `coreInstall`
(a `parametersSchema` that is missing or links outside the package).
`fixtures/debug-adapter.plugin.json` is a valid example, and
`fixtures/debug-adapter-remote-attach.plugin.json` declares six adapters that
differ in how they take a connection.

## Plugin backend

A plugin with its own pages may need code that a page cannot run: database
drivers, network clients, file formats. `backend` declares one long-lived
process that serves only the plugin itself, independent of any build system,
language, or workspace:

```json
"pluginAPIVersion": 3,
"requires": { "backend": 1, "serverProcess": 1, "ui": 2 },
"permissions": ["backend.launch", "credentials.store", "ui.contribute", "ui.web"],
"backend": { "launch": { "kind": "packaged", "path": "bin/backend" }, "arguments": ["--state", "${stateDir}"] }
```

- `backend` holds exactly the [`serverProcess`](#capability-versions-level-3)
  launch fields, with the same templates and install review; the review lists
  it as `packagedBackend`, `systemCommandBackend`, or `runtimeBackend`. It
  needs `pluginAPIVersion` 3, `requires.backend: 1`, `requires.serverProcess:
  1`, and the `backend.launch` permission. `fixtures/backend.plugin.json` is
  the example; the backend cases of `fixtures/invalid-manifests.json` are the
  rejections.
- In `backend` 1 only the plugin's own [web pages](#web-content-ui-2) call it,
  so a backend without a web tool window is `plugin.manifest.invalid`.
- It belongs to no workspace: `${workspaceStateDir}` is refused, and its
  writable state is `${stateDir}`. The host starts it with `${stateDir}` as
  root and working directory.
- The host keeps at most one backend process per plugin, starts it on the
  first `functions.*` call from one of the plugin's pages, and ends it when
  the plugin is disabled, updated, or uninstalled, and when the host quits.
  Its consent is the install review: it needs no per-workspace prompt.
- The backend speaks the [plugin-function protocol](#plugin-functions) and,
  from version 2, may ask the host for the
  [host services](#host-services-protocol-version-2) its permissions grant.
  It owns no domain contract: it never answers `lithe/build/*` or VCS
  requests.
- A plugin publishes one archive per platform, so its packaged path does not
  vary by `${arch}`; a macOS archive may carry a universal binary.

### Backend 2: workspace contexts

`requires.backend: 2` keeps every rule of version 1 and changes when the
process starts and what it learns about workspaces.
`fixtures/backend-workspace.plugin.json` is the example.

- It may start without a page. It needs at least one way to start: a web
  tool window (first page call, as in version 1), a `ui.commands[]` entry
  (its `onCommand:<id>` also starts the backend), or the `onWorkspaceOpen`
  event. A backend 2 with none of them is `plugin.manifest.invalid`.
- It is still one process per plugin, shared by every open workspace and
  window, on the machine that runs Lithe, also for remote workspaces. No
  workspace is process state: each call names its workspace explicitly
  (a context, below), so `${workspaceStateDir}` stays refused.
- Starting on `onWorkspaceOpen` never delays opening the workspace. The host
  starts such backends after the window is shown, one plugin at a time, and
  a backend that does not finish `initialize` within its initialize timeout
  is stopped and reported like any failed server start. A failed or
  disabled backend never blocks the workspace.
- The `workspace.metadata` permission grants the
  [`workspace` host service](#workspace-contexts-and-capability-discovery-protocol-version-3).
  It reveals the open workspaces' names, root folders and IDs, their
  authority, and the plugin's per-workspace state directory; it reads no
  file content.
- Activation is gated only by the plugin being installed, enabled, and
  reviewed. Lithe has no workspace trust state at the moment: an operation
  that runs or changes something asks the user per operation, as the host's
  own controls do.
- A host that offers only `backend: [1]` refuses the manifest with
  `plugin.api.unsupported` (`requires.backend`), so an older host never
  starts a process that expects contexts.

## Project generators

`projectGenerators` (requires `projectGenerators` 1 and the `project.generate`
permission) adds entries to the host's New Project window. The host owns the
window: the entry list and its search, the project name and location, the
"create Git repository" option, the empty project, and the Create button. A
generator declares only its own fields, the languages and build systems the
result needs, and the steps that produce it. No host code branches on a
generator ID.

```json
"projectGenerators": [{
  "id": "spring-boot",
  "displayName": "Spring Boot",
  "section": "generator",
  "icon": {"path": "icons/spring-boot.svg", "mode": "original"},
  "fields": [
    {"id": "groupId", "type": "text", "title": "Group", "default": "com.example", "pattern": "[a-z][a-z0-9.]*"},
    {"id": "packageName", "type": "text", "title": "Package name",
     "default": "${field.groupId}.${project.name|package}", "pattern": "[a-z][a-z0-9.]*"},
    {"id": "jdk", "type": "runtime", "title": "JDK", "runtime": "java", "minimumVersion": "17"}
  ],
  "requirements": [{"languageID": "java"}, {"buildSystemID": "maven"}],
  "steps": [{"kind": "archive", "url": "https://start.spring.io/starter.zip",
             "query": [{"name": "packageName", "value": "${field.packageName}"}]}]
}]
```

| Field | Meaning |
| --- | --- |
| `id` | Lowercase letters, digits, and hyphens; unique in the plugin. |
| `section` | `project` lists the entry under "New Project" (a plain project of a language); `generator` lists it under "Generators" (a framework or scaffolding tool). |
| `order` | 0–1000, default 100. Entries are sorted by section, `order`, then name. |
| `fields` | The generator's inputs, drawn and evaluated in order. A field may read only fields declared before it. |
| `requirements` | `languageID` or `buildSystemID` (optionally `when`) the created project needs. The catalog lists the installed plugins that provide each, with their enabled state, so the host can offer to enable one or open the marketplace. A requirement never blocks creation. |
| `steps` | Run in order in a staging directory that becomes the project root. |
| `openFiles` | Project-relative files the host opens after creating the project, optionally with `when`. |

### Fields

| `type` | Value | Properties |
| --- | --- | --- |
| `text` | A string | `default` (a template over `${project.name}` and earlier fields, re-evaluated until the user edits the field), `pattern` (matched as a whole), `maxLength` (default 256, at most 1024), `placeholder`, `optional`, `maximumVersion` |
| `enum` | One option | `options` (1–16 `{value, title}`), `default` (the first option otherwise), `presentation` (`segmented` or `menu`), `maximumVersion` |
| `boolean` | `true` or `false` | `default` |
| `multiSelect` | A list of options, kept in declaration order | `options` (1–128, each with an optional `group` heading), `default` |
| `runtime` | A host-discovered installation | `runtime` (`java`), `minimumVersion`, `optional`. The host chooses the initial value. |

`maximumVersion` is a template over earlier fields naming the highest version
the value may be, compared numerically by dotted components. A target Java
release that must not exceed the selected JDK declares
`"maximumVersion": "${field.jdk.major}"`; while the bound expands to an empty
string (no JDK chosen yet) nothing is checked.

Every field takes `id` (lowerCamelCase), `title`, `description` (shown behind
an info tip), `advanced` (listed under the collapsed "Advanced Settings"
group), and `visibleWhen`. A hidden field is not validated, and templates and
conditions read it as absent.

Text values never start with `-` and never contain control characters, so a
value cannot become an option or split a line. A project name is one
directory name: not empty, at most 128 characters, no `/`, `\`, `:`, or
control characters, not `.` or `..`, no leading `-`, and no surrounding
spaces.

### Conditions

`when` and `visibleWhen` take one condition or a list that must all hold:
`{"field": "<id>", "equals" | "notEquals": <value>}` or `{"field": "<id>",
"oneOf": [<value>, …]}`. Values are option values for `enum`, `true`/`false`
for `boolean`, and strings for `text` and `runtime` (`notEquals: ""` tests
that an optional field is filled). A condition on a hidden field is false.

### Templates

Strings in the manifest use `${…}`: `${project.name}`, `${field.<id>}` (a
text or option value, `true`/`false`, a comma-separated list, or a runtime's
home directory), `${field.<id>.version}`, and `${field.<id>.major}` (`21` for
`21.0.4`, `8` for `1.8.0_412`). Modifiers follow `|` and apply in order:
`path` turns dots into `/`, `package` makes a valid package name
(`com.Example.my-app` → `com.example.myapp`), and `lower` lowercases.

Template files use `{{ … }}` with the same variables, because POMs, Gradle
scripts, and properties files already contain `${…}` that must reach the
project unchanged. Only `{{` followed by `project.` or `field.` is a
variable; any other `{{` is copied as text. A file name may also contain
`${…}` variables, although a step's `target` is the portable place for them.
A path segment that starts with `dot-` becomes a dotfile (`dot-gitignore` →
`.gitignore`), because packages keep no hidden files. Hidden files in a
template directory are skipped; symbolic links are refused.

### Steps

| `kind` | Properties | The host… |
| --- | --- | --- |
| `files` | `source` (package-relative directory), `target` (project-relative directory template), `when` | writes the files of the plan, setting the executable bit where the template file has one. |
| `command` | `command` (a bare executable name), `arguments` (strings or `{value, when}`), `environment`, `collect`, `mayUseNetwork`, `timeoutSeconds` (default 600, at most 1800), `when` | resolves the executable like a build tool, runs it with the staging directory as the working directory, and, with `collect`, moves the contents of that subdirectory up into the project root. Arguments that expand to an empty string are left out. |
| `archive` | `url` (no query or fragment), `query` (`{name, value, when, omitEmpty}`), `when` | downloads the zip and calls `project.extractArchive` into the staging directory. |

Archive addresses must expand to HTTPS URLs (HTTP only for `localhost`,
`127.0.0.1`, or `[::1]`) without credentials. The URL may come from a field,
such as a configurable Spring Initializr server; the host shows the server
before creating. Template directories are limited to 1024 files, 1 MiB per
file, and 8 MiB in total; archives to 20,000 entries and 512 MiB extracted.

### Commands

| Command | Payload | Result |
| --- | --- | --- |
| `project.generatorCatalog` | `{plugins: [{manifest, enabled}], hostCapabilities?}` | `catalog: {generators: [{pluginID, pluginName, pluginEnabled, generator, requirements: [{languageID or buildSystemID, providers: [{pluginID, pluginName, enabled}]}], usesNetwork}], issues: [{pluginID, error}]}` |
| `project.generatorForm` | `{manifest, generatorID, form}` | `form: {projectName: {problem}, fields: [{id, visible, value, problem?}], activeRequirements, valid}` |
| `project.generationPlan` | `{manifest, generatorID, packagePath, form}` | `plan: {projectName, steps, openFiles, runtimes: [{field, runtime, home, version}], usesNetwork}` |
| `project.checkName` | `{projectName}` | `name: {problem}` |
| `project.extractArchive` | `{archivePath, destination}` | `extracted: {files}` |

`form` is `{projectName, values, edited, runtimes}`. `values` maps field IDs
to values; a text value counts only when its ID is in `edited`, so derived
defaults keep following the fields they read. `runtimes` maps runtime field
IDs to `{home, version}` of the user's selection. A field `problem` is one of
`required`, `tooLong`, `invalidFormat`, `unsupportedValue`, `runtimeTooOld`,
and `versionTooHigh`; hosts localize by code. Plan steps are `{kind:
"writeFiles", files: [{path, contents, executable}]}`, `{kind: "command",
command, arguments, environment, collect, mayUseNetwork, timeoutSeconds}`, and
`{kind: "archive", url, host, format: "zip"}`.

After the steps, the host moves the staging directory to its final location
(refusing an existing one), may record a `java` runtime as the project's JDK,
creates the Git repository when asked, and opens the project. A failure or
cancellation removes the staging directory and leaves nothing behind
(`plugin.project.generationFailed`).

## Plugin functions

A plugin backend (a language server, build provider, or
[plugin backend](#plugin-backend) process the plugin starts) can offer
**plugin functions**: plugin-private actions with
serializable params and results, which the host invokes on behalf of the same
plugin, for example from that plugin's own window. Functions complement the
typed domain protocols; they never replace them. Versions 1 and 2 of the protocol are
implemented in Rust Core (`rust/lithe-core/src/lsp/interface/plugin_function.rs`).
macOS starts every build provider process as a session of the plugin that
owns it and invokes its functions from that plugin's web pages (the
`functions.*` bridge methods below). A provider served by a shared language
server is started by the host for every plugin of its language, so it serves
no plugin's functions. Windows has no plugin backend host. The
[official SDKs](#official-backend-sdk) implement the backend side.

### Capability ownership

Every capability has one owner, who defines its contract, and one direction:

| Direction | Contract owner | Implemented by | Travels as | Examples |
| --- | --- | --- | --- | --- |
| Plugin provides a domain capability | Lithe: the typed domain contract | The plugin, declaratively or by its backend | A manifest `source`, Core plans and decodes, a typed `lithe/build/*` request | Build model, dependency tree; later task execution |
| Plugin provides a plugin function | The plugin: its own params and results | The plugin's backend | `lithe/function/invoke` | Refresh a private snapshot, a step behind a button of the plugin's own UI |
| Plugin calls a host capability | The host | The host | `lithe/host/*` requests, offered per protocol version | Run a process through the host's runner, write output, store state |

Two rules keep these directions from forming a loop:

- A backend never asks the host to dispatch a domain operation or a function.
  The host could route that request to the same backend, whose handler would
  then wait for itself. A backend request for `lithe/function/invoke` or any
  `lithe/build/*` method is refused with `plugin.function.recursiveCall`.
  A handler that needs, say, a Maven run asks for the host's process
  capability, never for the task that its own plugin implements.
- Host capabilities are primitive host services, never another entry into a
  domain registry. Each is added to a protocol version together with its
  params, permission, and the operation it must belong to. Version 1 offers
  none: every `lithe/host/*` request is refused with `plugin.host.unavailable`.
  Version 2 adds the [credentials](#host-services-protocol-version-2) service.

### Declarative or backend implementation

- A domain operation has exactly one implementation, chosen in the manifest
  (`source`: `static`, `command`, `hostIntegration`, or `provider`). Core plans
  only that one. There is no runtime fallback from a backend to a template or
  back: the two may differ in meaning, and a fallback would hide the failure.
- A backend implements a domain operation through its typed method and Core's
  plan and decode commands, never through a plugin function, so IDE
  workflows, presentation, and other hosts keep a single contract.
- Plugin functions need no manifest field. What a running process can answer
  is negotiated, as for [build providers](#build-providers); so declaring,
  adding, or removing functions changes neither `pluginAPIVersion` nor any
  `requires` version.
- A new kind of domain implementation, such as a provider for tasks, is a new
  version of the capability that owns it (`buildProviders`), so only plugins
  that use it are filtered from hosts that cannot run it.

### Negotiation

For a session owned by a plugin (`lsp.startServer.pluginId`), the host offers
`capabilities.experimental.litheFunctions: { "versions": [1, 2, 3] }` in
`initialize`, next to and independent of `litheBuild`. Host-owned sessions do
not offer or accept this protocol, retain no plugin-function registry, and
reject register/unregister with `-32601`. A plugin backend that offers
functions answers:

```json
"experimental": { "litheFunctions": { "version": 1, "functions": [{ "id": "snapshot.refresh" }] } }
```

`functions` is optional and defaults to none. An answer with a version the
host did not offer, or a malformed or duplicate function ID, does not
negotiate the protocol at all, so a session never starts with half a
registry. Unknown fields of the answer and of descriptors are ignored.
After a plugin-owned session successfully negotiates the protocol in
`initialize`, Core publishes its initial
registry as `functionsChanged { functions: [<sorted IDs>], removed: [] }`,
including when the negotiated registry is empty. Hosts can discover the
functions from events without issuing an invocation first.

### References and IDs

A function reference is `{ "pluginID", "functionID" }`. The host routes by
plugin first: only a session the plugin started (`lsp.startServer` with
`pluginId`) serves its functions, and a reference to another plugin is
`plugin.function.wrongPlugin`. Host-owned servers serve none.

A function ID is dot-separated lowerCamelCase segments
(`snapshot.refresh`), at most 128 bytes, unique within the session. A
session holds at most 256 functions.

### Registration and withdrawal

After `initialize` a backend may send:

| Request | Params | Effect |
| --- | --- | --- |
| `lithe/function/register` | `{ "functions": [{ "id" }] }`, nonempty | Adds the functions. |
| `lithe/function/unregister` | `{ "ids": ["…"] }`, nonempty | Removes them and revokes their running calls. |

Each request is all or nothing: a malformed ID, a function listed twice, an
already registered ID, an unregistered ID, or exceeding the limit refuses the
whole request with JSON-RPC error `-32602` and
`data.code: "plugin.function.invalidRegistration"`. A successful change
answers `null` and publishes `functionsChanged` with the sorted IDs. A
backend that did not negotiate the protocol gets `-32601` for both.

### Invocation

`lsp.functionRequest { sessionId, operationId?, function, params?,
timeoutMilliseconds?, context? }` (`context` from protocol version 3, see
[workspace contexts](#workspace-contexts-and-capability-discovery-protocol-version-3)) returns `{ operationId }` and sends:

```json
{ "method": "lithe/function/invoke", "params": { "functionID": "snapshot.refresh", "operationID": "…", "params": { … } } }
```

`params` must be a JSON object and defaults to `{}`. Core assigns every
backend invocation a unique, opaque `operationID`. The backend must echo it
unchanged in progress notifications; it must not derive it from the host's
`operationId`. The host continues to cancel and receive events using its own
`operationId`, which can be reused after a call ends. Core translates progress
back to that host ID, including `requestProgress.result.operationID`. This
prevents a late report for an earlier call from being attributed to a new call.
Core checks, in this order, and refuses without writing anything:

| Check | Core error | `details` |
| --- | --- | --- |
| Plugin or function ID malformed | `invalid_request` | `plugin.function.invalidReference` |
| `params` not an object | `invalid_request` | `plugin.function.invalidParams` |
| Session belongs to no plugin | `not_supported` | `plugin.function.unavailable` |
| Session belongs to another plugin | `permission_denied` | `plugin.function.wrongPlugin` |
| Protocol not negotiated | `not_supported` | `plugin.function.unavailable` |
| Function not registered | `not_supported` | `plugin.function.unknown` |

The call ends with exactly one `requestCompleted` event:

| Outcome | Event |
| --- | --- |
| Result | `result: { "value": <result> }`; `null` is a result. |
| Backend error | `error.code: "plugin.function.failed"`, the backend's `message` (at most 1024 bytes), and `error.pluginErrorCode` from `error.data.code` when it is an identifier of at most 64 bytes. The plugin code is for the plugin's own UI; Lithe never branches on it. |
| No `result`, or a result over 1 MiB serialized | `plugin.function.invalidResult` |
| Function withdrawn while running | `plugin.function.revoked`; the host also sends `$/cancelRequest` |
| Cancelled through `lsp.cancelOperation` | `requestCancelled`; the host sends `$/cancelRequest` |
| Deadline passed | `requestTimeout`; the host sends `$/cancelRequest`. `timeoutMilliseconds` is capped at one hour and defaults to the session's request timeout. |
| Process exited or the transport failed | The session's terminal error, as for every pending request |

After a call has ended, its late reply is ignored, and so is any progress
report for it. Every terminal path removes its function/request association;
withdrawing that function later cannot cancel a new operation reusing the
host ID, including a build request. A backend should stop work on
`$/cancelRequest`, but the host does not rely on it.

### Progress

A backend reports progress of a running call with the notification
`lithe/function/progress { operationID, message?, percentage? }`, where
`message` is cut to 1024 bytes and `percentage` is a whole number from 0 to
100. Core publishes it as `requestProgress` with the operation ID and the
normalized report. A malformed report, or one for an operation that is not
running on that session, is dropped.

### Host services (protocol version 2)

A backend that negotiated version 2 may send these requests to the host.
Each service is granted by one manifest permission; Core receives the
granted services as `lsp.startServer.hostServices` (from the launch plan's
`backend.hostServices`) and checks every request before the host sees it.

| Request | Params | Result | Permission |
| --- | --- | --- | --- |
| `lithe/host/credentials/get` | `{ key }` | `{ secret }`, `null` when nothing is stored | `credentials.store` |
| `lithe/host/credentials/set` | `{ key, secret }` | `null` | `credentials.store` |
| `lithe/host/credentials/delete` | `{ key }` | `null`, also when nothing was stored | `credentials.store` |

- A `key` is 1–128 ASCII letters, digits, `.`, `_`, `:`, or `-`; a `secret`
  is a string of at most 16 KiB. Unknown params are refused so a later
  version can add them.
- Credentials are private to the plugin ID: the host stores them in the
  platform's secret store (the Keychain on macOS) in a namespace of that ID,
  never in `${stateDir}` or the package. They survive disabling and updating
  the plugin and are deleted when it is uninstalled.
- Core refuses, without involving the host, in this order: a session that
  negotiated version 1 or a method version 2 does not define (`-32601`,
  `plugin.host.unavailable`), a service the plugin is not granted (`-32601`
  in version 2, `-32010` from version 3, `plugin.host.permissionDenied`),
  and malformed params (`-32602`, `plugin.host.invalidParams`; from
  version 3 a field the method does not define is `-32018`,
  `plugin.host.unsupportedOption`, see
  [Extending version 3](#extending-version-3)). The code is in
  `error.data.code`.
- An accepted request becomes the runtime event `hostRequest` with `method`
  and `result: { hostRequestID, service, params }`. The host answers it with
  `lsp.hostResponse { sessionId, hostRequestID, result? | error: { message } }`;
  Core sends `result` (or `null`) to the backend, or `-32603` with
  `plugin.host.failed` and the host's message cut to 1024 bytes. An unknown
  `hostRequestID`, including one already answered, is `invalid_request`.
- A session holds at most 16 unanswered host requests; a further one is
  refused with `plugin.host.failed`. Unanswered requests end with the session.
- `hostServices` needs `pluginId` and names only services this Core defines
  (`credentials`, `workspace`, or registered method-grant names); otherwise `lsp.startServer` is
  `invalid_request`.

### Workspace contexts and capability discovery (protocol version 3)

Version 3 keeps every rule of version 2 and adds capability discovery,
subscription disposal, workspace contexts, a context on each call, typed host
failures with details, cancellation of host requests, and host
notifications.

| Request | Params | Result | Granted by |
| --- | --- | --- | --- |
| `lithe/host/getCapabilities` | none or `{}` | `{ protocolVersion, backendAuthority, services, limits }` | every plugin-owned session |
| `lithe/host/subscriptions/dispose` | `{ subscriptionID }` | `null`, also for an unknown or already disposed ID | every plugin-owned session |
| `lithe/host/workspace/listContexts` | none or `{}` | `{ revision, contexts: [<context>] }` | `workspace.metadata` |
| `lithe/host/workspace/getContext` | `{ context: { contextID, generation } }` | `<context>` | `workspace.metadata` |
| `lithe/host/workspace/getFolders` | `{ context: { contextID, generation } }` | `{ folders: [<folder>] }` | `workspace.metadata` |

- Core answers `getCapabilities` itself. `services` maps each service the
  session may use (the implicit `host`, `subscriptions`, and `commands`, and
  the granted ones) to `{ methods, notifications }`: the requests it may
  send and the [host notifications](#host-notifications-protocol-version-3)
  it may receive. It lists nothing the session may not use, and a host
  grants only the services it has handlers for, so a listed method never
  fails for want of one. `backendAuthority` is `"local"`: the backend runs on
  the machine that runs Lithe. `limits` gives `pendingHostRequests`,
  `functionResultBytes`, `hostRequestBytes`, `hostResultBytes`, `errorMessageBytes` (the cut of a host failure's
  message), `errorDetailsBytes`, and `notificationBytes`. A backend must
  check `services` instead of assuming a method from the version.
- A context is one open workspace in one window:

  ```json
  {
    "contextID": "w-3f2a9c",
    "generation": 2,
    "name": "orders",
    "authority": { "kind": "local" },
    "folders": [{ "rootID": "r0c1d2e3f4a5b6c7d", "name": "orders", "path": "/Users/me/orders" }],
    "stateDirectory": "/Users/me/Library/Application Support/Lithe/PluginState/<plugin>/backend/workspaces/<digest>"
  }
  ```

  `contextID` uses the key alphabet and lives as long as the window shows
  that workspace: a window that switches to another workspace closes the
  context and opens one with a new `contextID`, so state a backend keyed by
  the ID never carries over to a different workspace. `generation` starts at
  1 and grows every time the same workspace's folders or authority change; a
  request naming an older generation, or a closed context, is
  `plugin.host.contextExpired`, and the backend asks again. `revision` of
  `listContexts` grows whenever a context opens, closes, or changes.
- `rootID` identifies one root folder stably for the same location, across
  restarts, without revealing the path. It is keyed per plugin with a host
  secret, so two plugins see different IDs for the same folder and an ID
  cannot be computed from a guessed path. `path` is present only for a
  `local` authority.
- `authority.kind` is `local` or `remote` (a remote workspace, which also
  has `authority.id`, an opaque connection ID). For a `remote` context the
  folders carry no `path`: the local directory the host keeps for a remote
  workspace is an empty placeholder, not the workspace. File, search, and
  process services answer a request for a context whose authority they do
  not implement with `plugin.host.authorityUnsupported`; they never read the
  placeholder or run the operation locally instead.
- `stateDirectory` is private to the plugin and the workspace, outside the
  plugin package and the application bundle. Only `getContext` returns it,
  and creates it then; `listContexts` entries carry every other field and
  create nothing, so listing many windows leaves no directories behind.
  `${stateDir}` is the plugin-wide state. Both survive disabling and
  updating the plugin and are deleted when it is uninstalled.
- A page call may name its context: `lsp.functionRequest.context`
  (`{ contextID, generation }`) reaches a version 3 backend as
  `params.context` of `lithe/function/invoke`. A malformed reference is
  `plugin.function.invalidParams`; a backend that negotiated version 1 or 2
  receives the call without it. The host fills it from the page's window.
- A host failure may carry a code and details:
  `lsp.hostResponse.error: { message, code?, details? }`. Core passes these
  codes to a version 3 backend, each with its own JSON-RPC error code so a
  backend can branch on the number alone; any other code, no code, or a
  version 2 backend gets `plugin.host.failed`. `details` is an object of at
  most 4 KiB serialized (for example `{ currentVersion }` with
  `versionConflict`, or `{ retryAfterMilliseconds }` with `rateLimited`);
  it reaches a version 3 backend as `error.data.details` and is dropped
  otherwise. Details that are not an object, or larger, are dropped too;
  the failure itself still reaches the backend. `fixtures/function-protocol.json` (`hostFailures`)
  lists the mapping.

  | Code | JSON-RPC | Meaning |
  | --- | --- | --- |
  | `plugin.host.unavailable` | `-32601` | The host offers no such service or method |
  | `plugin.host.invalidParams` | `-32602` | Params malformed or out of range |
  | `plugin.host.failed` | `-32603` | Any other failure |
  | `plugin.host.cancelled` | `-32800` | The request was cancelled |
  | `plugin.host.permissionDenied` | `-32010` | Permission not declared, or the user withheld consent |
  | `plugin.host.contextExpired` | `-32011` | The context is closed or its generation replaced |
  | `plugin.host.authorityUnsupported` | `-32012` | The service does not support the workspace authority |
  | `plugin.host.versionConflict` | `-32013` | A document or resource version differs from the expected one |
  | `plugin.host.limitExceeded` | `-32014` | A host limit was exceeded |
  | `plugin.host.timeout` | `-32015` | The host's deadline passed |
  | `plugin.host.notFound` | `-32016` | The named resource does not exist |
  | `plugin.host.readOnly` | `-32017` | The resource or workspace cannot be written |
  | `plugin.host.unsupportedOption` | `-32018` | The host does not implement a requested option; `details.option` names the field |
  | `plugin.host.preconditionFailed` | `-32019` | A state the request requires does not hold, such as a missing user confirmation |
  | `plugin.host.busy` | `-32020` | The resource is in use; retry later |
  | `plugin.host.rateLimited` | `-32021` | Too many requests in a period; retry after `details.retryAfterMilliseconds` when given |

  JSON-RPC reserves `-32768` to `-32000` for the protocol and lets
  implementations define `-32099` to `-32000` as server errors. `-32000`
  to `-32009` stay free for backends' own failures, which many JSON-RPC
  libraries already use from `-32000`, so host codes start at `-32010` and
  grow by one; a code is never reused for another meaning. Versions 1 and
  2 keep their numbers.
- A backend may cancel its own pending host request with `$/cancelRequest`.
  Core answers it at once with `-32800` and `plugin.host.cancelled`, frees
  the slot, and publishes `hostRequestCancelled { hostRequestID }` so the host
  stops the work; a later `lsp.hostResponse` for that ID is
  `invalid_request`. The 17th pending request of a version 3 session is
  `plugin.host.limitExceeded`.
- A service that creates a subscription returns a `subscriptionID` of the key
  alphabet; its notifications name it. Ending the session, disabling the
  plugin, or closing the subscription's context disposes it.
- A backend still cannot ask the host to call a function or a domain
  operation (`plugin.function.recursiveCall`), so a page call never waits on
  itself through the host.

### Host notifications (protocol version 3)

The host tells a version 3 backend about changes with JSON-RPC
notifications; the backend answers none of them. The host sends them through
Core with `lsp.hostNotify { sessionId, method, params }`, which returns
`{ delivered }`: `false` when the session negotiated an older version, which
then never sees them.

| Notification | Params | Granted by |
| --- | --- | --- |
| `lithe/host/workspace/didChangeContexts` | `{ revision }` | `workspace.metadata` |
| `lithe/host/subscriptions/notify` | `{ subscriptionID, sequence, event }` | every plugin-owned session |
| `lithe/host/commands/didRun` | `{ commandID, context? }` | every plugin-owned session |

- `didChangeContexts` follows every change `revision` of `listContexts`
  counts; the backend calls `listContexts` for the contexts. A backend that
  starts later reads them itself.
- `subscriptions/notify` carries one `event` object of the named
  subscription. `sequence` starts at 1 and grows by one per subscription, so
  a backend can detect a gap; nothing follows a disposal.
- `commands/didRun` reaches the plugin's backend when the user runs one of
  the plugin's commands. `commandID` is the command's ID; `context`
  (`{ contextID, generation }`) is the window's context when it has one. A
  running backend receives it in order with the other notifications; a
  stopped one is started for it only when it declares
  `onCommand:<commandID>`, and receives it once ready.
- `revision` and `sequence` are positive integers, `event` is an object,
  and serialized params are at most `limits.notificationBytes`. Core refuses
  any other method, a service the session is not granted, malformed params,
  a session that is not plugin-owned, or one that is not ready, with
  `invalid_request`. `fixtures/function-protocol.json`
  (`hostNotifications`) holds the cases.

### Extending version 3

From version 3, host capabilities are added within the version, and a
backend discovers them with `getCapabilities` instead of a version number. A later host adds, without a
new version:

- a service with its methods and notifications, granted by a new manifest
  permission, or a method or notification of an existing service;
- an optional field of request params (an *option*) whose absence keeps the
  earlier behavior, or a field of a result, a notification, `details`, or
  `limits`;
- a failure code, which takes the next unused JSON-RPC number after
  `-32021`; a number never changes meaning.

A new protocol version is needed only for a change an existing backend
would misread: removing or renaming a method, notification, or field,
changing a field's meaning or type, making an option required, changing a
code's number, or weakening an ordering or lifecycle guarantee above.

So that a version 3 backend works with every host of version 3:

- It calls a method only when `getCapabilities.services` lists it; another
  is `-32601`, `plugin.host.unavailable`.
- It ignores result, notification, `details`, and `limits` fields it does
  not know, and any `lithe/host/*` notification it does not know.
- Core refuses a field the method does not define with `-32018`,
  `plugin.host.unsupportedOption`, and `details: { option }` naming it, before
  the host sees the request; the backend may retry without that option. A
  service whose params Core does not type answers the same way itself.
- It treats a JSON-RPC number it does not know as a host failure, and
  branches on `error.data.code` when it knows that code.
- A package whose backend needs a new service declares the new permission.
  A host that does not know the permission refuses the package at install
  (`plugin.permission.unknown`), so a permission is never granted or
  ignored silently.

`fixtures/function-protocol.json` (`hostRequests`) holds the
unsupported-option cases.

### Public document, file and window methods (protocol version 3)

These methods are implemented by the macOS host. Windows does not advertise
`backend` support. `getCapabilities` lists only the intersection of the plugin's
permission-derived grants and this host's registered method handlers.

New grants in `lsp.startServer.hostServices` use **full method names**, not service
names. The legacy `workspace` grant still admits only `listContexts`, `getContext`
and `getFolders`; it never grants file reads. The legacy `credentials` grant is
unchanged. Registering another handler cannot replace a method already registered.

All methods below require `context: {contextID, generation}`. Resource arguments
use `{rootID, path}` from that plugin's `getFolders` response; paths use `/` and
are relative to the root. A root ID is not a lifetime or an authorization token.
Opening the same folder in two windows creates independent context-owned leases;
closing one does not invalidate the other, and reopening works with generation 1
in its new context. Remote contexts are explicitly refused by this first set of
methods. Unknown options fail before side effects with `unsupportedOption`.

| Methods (prefix `lithe/host/`) | Permission | Params in addition to `context` | Result |
| --- | --- | --- | --- |
| `documents/list` | `documents.read` | none | `{documents:[<summary>]}` |
| `documents/getSnapshot` | `documents.read` | `documentID` | `{document:<summary>, text}` from the dirty live buffer |
| `editor/registerActions` | `editor.actions` (+ `documents.read`) | `id,function,selector` | `{subscriptionID}`; independent editor actions, see below |
| `editor/getActive` | `documents.read` | none | summary of the foreground text tab, or `null` |
| `editor/getSelections` | `documents.read` | `documentID` | `{documentID,version,selections:[{anchor,active}],primaryIndex}` |
| `editor/applyEdits` | `editor.edit` | `documentID,expectedVersion,edits:[{range,text}]` | `{documentID,version,applied}` |
| `editor/replaceSelections` | `editor.edit` | `documentID,expectedVersion,selections:[{anchor,active}],replacements:[string]` | same; one replacement for all selections or one per selection |
| `editor/insertText` | `editor.edit` | `documentID,expectedVersion,at,text` | same |
| `workspace/readDirectory` | `workspace.files.read` | `resource,cursor?,limit?` | `{entries:[{name,resource,kind}],nextCursor}` |
| `workspace/stat` | `workspace.files.read` | `resource` | `{resource,kind,size,modifiedMilliseconds}` |
| `workspace/readFile` | `workspace.files.read` | `resource,maximumBytes?` | `{resource,source:"disk",byteCount,isTruncated,identity,text?,encoding?,base64?}` |
| `workspace/watch` | `workspace.files.watch` | `resource,recursive?` (default false) | `{subscriptionID}`; events contain `{rootID,changedPaths,requiresRescan}` |
| `workspace/findFiles` | `workspace.search` | `resource` naming the root (`path:""`), `query,fileMask?,cursor?,limit?` | `{matches:[<resource>],nextCursor,isTruncated,source:"disk"}` |
| `workspace/findText` | `workspace.search` | root `resource,pattern,fileMask?,caseSensitive?,wholeWords?,regularExpression?,cursor?,limit?` | same envelope, matches `{resource,line,preview,range:null}`; the upstream search owner currently reports lines, not exact match spans |
| `editor/open`, `editor/reveal` | `editor.open` | `resource,activation?` (`select` or `background`), `range?,tab?` (`regular` only) | document identity/version and state, `wasAlreadyOpen,windowIsForeground,appliedSelection` |
| `preview/openHTML` | `preview.open` | HTML `resource,presentation?` (`editorAndPreview` or `previewOnly`), `range?` | open result plus `usesLiveBuffer:true,presentation`; explicitly changes the existing tab's presentation |
| `browser/openExternal` | `browser.open` | exactly one of HTTP(S) `url` or HTML `resource`; `unsaved?` (`openSavedFile` or `requireSaved`) for a resource | `{opened:true,source:"web"|"disk",hasUnsavedChanges?}` |
| `window/showInformation`, `window/showWarning`, `window/showError` | `window.messages` | `text,actions?` | `{selectedIndex}`; zero-based, or `null` on dismissal |

A document summary has `documentID,version,path,languageID,isReadOnly,isDirty,
encoding,lineEnding`. `path` is workspace-relative or null for a document outside
the root; `languageID` may be null. Positions `{line,column}` are one-based UTF-16;
ranges `{start,end}` are half-open and cannot split a surrogate pair. Selections
keep anchor/active direction. Batches are atomic and one Monaco undo step. Stale
versions, read-only buffers, pending editor synchronization and IME composition
are refused. Background documents without a mounted editor can be listed/read,
but edits/selections may return `busy`; opening a foreground tab does not imply
that its web editor is already ready. Retry reads after readiness, not edits
blindly. `editor.open/reveal` currently applies a range's start as a caret and
reports `{kind:"caret",line,column}`, not a fabricated full selection.

Limits: snapshots and file reads expose at most 128 KiB of source text/bytes per
call; oversized snapshots return `limitExceeded`, file reads report truncation.
This leaves room for worst-case JSON escaping under the 1 MiB serialized host
request/result budget. Batches contain at most 1,000 edits/selections. Directory
pages default to 200 and cap at 1,000; search pages default to 100 and cap at 200,
with the search owner's overall 200-result cap. Explicit file reads use
component-wise `O_NOFOLLOW`; listings omit symlinks. Hidden-file rules affect
listing/search/watch, not authorization for explicit reads. Open/browser paths
retain the existing canonical containment checks and their documented
check-to-open race; native backends are not OS-sandboxed.

Machine host requests have a 30-second host deadline. User-choice messages wait
until the user answers, the request is cancelled, or the context/session closes.
Messages retain the per-plugin/window rate and queue limits (5/10 seconds,
3 pending per plugin, 10 per window, 2,000 text characters, 3 actions of 40
characters). Session exit revokes grants and cancels requests/subscriptions;
old session callbacks cannot affect a replacement. Closing a context cancels its
requests with `contextExpired`. Notifications have a 128-entry per-session queue;
context revisions coalesce to the latest, and overflow ends the session instead
of allowing unbounded memory or silently losing commands. Notification/response
writes share the process write watchdog and stop cleanup with function requests.

Cancellation or timeout **does not promise rollback**: an edit or external open
may already have committed. The SDK must not replay a mutation on these failures.
On `versionConflict`, reread and recompute; on `contextExpired`, resolve the
original target again, never substitute the focused window. `busy`/`rateLimited`
may be retried with bounds; `permissionDenied`/`readOnly` need user intervention.

### Backend-only commands (`ui` 4)

`requires.ui:4` permits `ui.commands` without `toolWindowID` and allows an empty
or omitted `toolWindows` array. Such a command requires `backend:2`, the existing
`ui.contribute` and `backend.launch` permissions, and its `onCommand:<id>` event.
Versions 1-3 retain their window-required behavior. An old host rejects ui 4 at
installation, rather than accepting a command it cannot execute. See
`fixtures/command-backend.plugin.json`.

The command appears through the ordinary workbench command contributions and
sends `commands/didRun` without opening a dummy tool window. Commands arriving
while initialize is pending wait until ready; a crashed backend can start again
on its declared command event. Background workspace activation has two concurrent
start slots; explicit command activation does not wait for unrelated background
plugins. `didRun` remains an event, not an acknowledgement that the command's
business action succeeded; a future result-bearing execute API must use the
existing request lifecycle rather than infer success from notification delivery.

### Independent editor actions (protocol version 3)

Editor actions are a host presentation capability of an ordinary tool backend,
not an LSP, Build, Run, Test or Debug provider. A play icon is presentation, not
an execution kind. The host understands the bounded range/title/icon/invocation
shape; HTTP/SQL parsing and execution remain private to the plugin. Native domain
workflows still use their own typed contracts, never a private-function substitute.

A backend declares `backend: 2`, `documents.read` and `editor.actions`, discovers
`lithe/host/editor/registerActions` with `getCapabilities`, then registers per
workspace context:

```json
{
  "context": {"contextID": "w1", "generation": 1},
  "id": "requestActions",
  "function": "requests.collectActions",
  "selector": {"fileExtensions": ["http", "rest"], "fileNames": []}
}
```

- Registration returns `{subscriptionID}`. Dispose with the existing subscription
  API. It only records the binding and never calls the backend while answering;
  collection runs later. The function must already be registered on that session.
- No manifest `runMarkers` section or capability, no special command notification,
  and no language-server/Run declaration is added. The first implementation starts
  through existing `onWorkspaceOpen` (or an existing explicit entry); registration
  cannot discover a backend that has not started. Backend installation still needs
  restart. Standalone backends have an application-scoped enablement module,
  without a fake UI or language provider; safe mode/quarantine/disable still veto
  their startup. Example package: `fixtures/editor-actions.plugin.json`.
- A selector has 1 to 32 literal names/extensions; extensions accept an optional
  leading dot. Matching is case-insensitive. At most 32 bindings per plugin across
  contexts; duplicate registration IDs in a context are refused.
- The host invokes the collection function via existing `lithe/function/invoke`
  with workspace context and `{document:{documentID,version,path},text}`. Version
  is the same public buffer version as `documents/getSnapshot`, not a WebView
  revision. Source is the dirty live buffer, capped at 128 KiB. Remote workspaces
  and read-only preview surfaces are not served by this first implementation.
- Collection is read-only by contract: no network request or business execution.
  Edits invalidate the old actions immediately and cancel older collection work;
  the host debounces fresh collection and rejects stale or withdrawn results.
  macOS bounds the whole collection batch to eight seconds, not eight seconds per
  binding. Refresh acknowledges scheduling without waiting for collectors; a slow
  or failed collector must not fail editing or the save synchronization barrier.
- Return `{actions:[{id,range:{start:{line,column},end:{line,column}},title,icon,
  invoke:{functionID,params?}}]}`. Positions are one-based UTF-16, half-open and
  cannot split surrogate pairs. Each range stays in the exact input document.
  `id` is 1 to 128 bytes without controls, unique per answer; `title` is 1 to 200
  characters on one line. `icon` is `run` or `run-all`, a host-owned presentation
  token. At most 1000 actions and 1 MiB serialized; malformed answers are refused
  whole. Same-line actions share a menu rather than silently replacing each other.
- Each invocation target is a currently registered function of the same plugin;
  `params` is a plugin-private JSON object. The host stores it behind an opaque
  per-batch action key, never accepts invocation payloads from the web editor, and
  validates document/context/session/registration again on click. It calls the
  function with `{documentID,expectedVersion,actionID,data:<params>}` through the
  ordinary invocation lifecycle. The plugin validates/re-reads the live document
  before side effects. Click executions are not cancelled by unrelated re-parsing;
  withdrawing the binding, ending its session/context or tearing down the owning
  editor cancels them. The host never retries side effects automatically.
- Registration/collection validation is shared Core command
  `plugins.editorActions.decode`; public host failures retain protocol 3's existing
  distinct codes (`invalidParams`, `permissionDenied`, `versionConflict`, etc.).
  No tool-private error or result is interpreted as a build/test result.
- Existing `commands/didRun {commandID,context?}` is unchanged. A command-palette
  entry can read the document/selection and call the same plugin implementation.
- This is an additive host method within protocol 3, not a protocol-version bump.
  Old hosts do not advertise it. A plugin can retain its existing command/window
  entry point; a package requiring `editor.actions` is deliberately refused by an
  older host that does not recognize that permission, rather than silently granted.
  Grammar capability admission is separate. SDK/contract mirrors still need sync.

### Compatibility

- Packages of every API level are unchanged: functions add no manifest field.
- A backend written before this protocol does not answer `litheFunctions`.
  It keeps serving its language and its `litheBuild` requests, receives no
  function calls, and its function requests are answered with `-32601`.
- Up to version 3, every protocol version added host capabilities. From
  version 3 a new host capability or optional field is added within the
  version ([Extending version 3](#extending-version-3)); only a change an
  existing backend would misread needs a new protocol version, offered next
  to the old one.
- A backend that answers `version: 1` keeps working unchanged: version 2
  only adds host services. A backend that answers `version: 2` keeps
  working unchanged: version 3 only adds methods, notifications, the call
  context, and failure codes and details, all of which it never sees.
- `requires.backend: 1` packages keep their meaning; a new behavior of the
  backend capability is `backend` 2, never a silent change of version 1.
- `fixtures/function-protocol.json` holds the golden cases, including the
  host requests (`hostRequests`), call contexts (`invocationContexts`), host
  failure codes (`hostFailures`), and host notifications
  (`hostNotifications`). Rust Core tests run them, and a scripted backend covers routing, result, failure, cancellation,
  deadline, late reply, revocation, and compatibility with a build-only
  backend.

### Official backend SDK

The official SDKs live in
[lithe-plugin-docs](https://github.com/Lithe-IDEA/lithe-plugin-docs), which
also releases them; they implement this contract and never define protocol.

[`sdk/node`](https://github.com/Lithe-IDEA/lithe-plugin-docs/blob/main/sdk/node/README.md) is the official SDK for backends
started through a `node` runtime launch. It implements this protocol and
`litheBuild` 1, so a plugin author writes only handlers. It is released
(`sdk-node-v<version>`) as a `.tgz` with its SHA-256 for plugins to vendor
into their package. It enforces the rules above on the backend side: `lithe/*` methods are never sent, stdout
carries only protocol frames, `PluginError` is the only way to set a
`pluginErrorCode`, processes started for a call end with it, and its state
store refuses the plugin package.

[`sdk/java`](https://github.com/Lithe-IDEA/lithe-plugin-docs/blob/main/sdk/java/README.md) is the Java twin for backends
started through a `java` runtime launch. It needs Java 8 or newer, has no
runtime dependencies, and is released as a JAR with its SHA-256 for plugins
to shade into their backend. It enforces the same rules with the same error
mapping, with one difference: on Java 8 it stops only a cancelled tool's
direct child, and the host's process scope ends the rest.

[`sdk/rust`](https://github.com/Lithe-IDEA/lithe-plugin-docs/blob/main/sdk/rust/README.md) is the SDK for
[plugin backends](#plugin-backend), which ship as packaged executables. It
implements plugin-function protocol versions 1 and 2, including the
`credentials` host service, but neither build nor VCS providers. It needs
Rust 1.87 or newer, depends only on `serde_json`, and is released
(`sdk-rust-v<version>`) as a `.crate` archive with its SHA-256, or used as a
Git dependency pinned by the tag. It enforces the same rules: on Unix it
points stdout at stderr so only protocol frames reach the host, and a panic
ends only its call, reported like any unexpected failure.

The Node.js and Java SDKs each have a sample build provider
(`sdk/*/examples/sample-build`) that answers one end-to-end scenario driven
through a real Core session; the Rust SDK's sample backend
(`sdk/rust/examples/sample-backend`) answers a plugin backend scenario in which
the test plays the host and serves the credential requests. That repository
runs them against the Lithe commit its contract copy pins, and weekly against
the latest `preview`, the branch Lithe changes merge into.

No SDK adds a wire field: a backend written without one is equally valid.

## Outcomes and error codes

`plugins.declarative.*`, `plugins.marketplace.*`, `build.*`, `vcs.*`, and `project.*` commands return `{"status": "ok", …}` or
`{"status": "rejected", "error": {"code", "message", "field"?}}`. A malformed
command payload is a Core `invalid_request` failure instead.

| Code | Reported by | Meaning |
| --- | --- | --- |
| `plugin.manifest.invalid` | Core | Malformed manifest, unknown field, or broken cross reference |
| `plugin.schema.unsupported` | Core | `schemaVersion` is not `2` |
| `plugin.api.unsupported` | Core | `pluginAPIVersion`, or a capability version in `requires`, is not supported by this Core build or, when the host sent `hostCapabilities`, by the host |
| `plugin.permission.unknown` | Core | Unknown permission |
| `plugin.permission.undeclared` | Core | A provider or build system is declared without its permission |
| `plugin.activation.invalid` | Core | Missing or orphan activation event |
| `plugin.runtime.unsupported` | Core | Unknown runtime dependency, or a launch runtime that cannot start an entry file |
| `plugin.template.invalid` | Core | Unknown, misplaced, or unguarded template variable |
| `plugin.path.invalid` | Core | A request path leaves the workspace, or a declared path leaves its base directory |
| `plugin.test.invalidIdentifier` | Core | Empty or multi-line test identifier |
| `plugin.test.unsupportedProject` | Core | No project marker in the workspace |
| `plugin.execution.unavailable` | Core | The plugin has no run/test provider for the language |
| `plugin.integration.unsupported` | Core | A host integration the host does not implement, or one requested by a plugin outside the official namespace |
| `plugin.launch.unavailable` | Core | The plugin has no language server for the language, no provider process for the build system, or no such VCS provider |
| `plugin.build.unavailable` | Core | The plugin declares no such build system, or the build system does not declare the requested operation |
| `plugin.build.invalidSelection` | Core | A build request selects a scope, target, filter, or argument the declaration does not allow, or misses a required path |
| `plugin.build.invalidOutput` | Core | Build-tool output or a report does not fit its decoder |
| `plugin.launch.invalidRequest` | Core | A launch plan request has an unusable directory or an unknown architecture |
| `plugin.grammar.invalid` | Core | A language's grammar file is not a Monarch grammar Core accepts; `field` names the failing part |
| `plugin.grammar.unavailable` | Core | The plugin declares no grammar for the language |
| `plugin.vcs.reserved` | Core | A VCS provider claims the ID of the built-in Git support |
| `plugin.vcs.invalidOutput` | Core | A VCS provider's reply does not fit the [VCS provider contract](https://github.com/1lck/Lithe-IDEA/blob/preview/shared/contracts/vcs-provider-v1.md) |
| `plugin.index.invalid` | Core | Malformed index root or entry, or an invalid URL, checksum, platform, version, or date |
| `plugin.index.schemaUnsupported` | Core | The index `schemaVersion` is not `1` |
| `plugin.index.officialNamespace` | Core | A third-party source lists a `dev.lithe` ID |
| `plugin.index.duplicate` | Core | An index lists the same plugin ID more than once |
| `plugin.index.platformUnsupported` | Core | No version has an archive for this platform (availability, not a rejection) |
| `plugin.index.apiUnsupported` | Core | Only versions needing a newer plugin API, or a capability the host does not run, list this platform (availability, not a rejection) |
| `plugin.source.invalid` | Core | A marketplace source URL cannot be used |
| `plugin.package.mismatch` | Core | A downloaded package's ID or version differs from its index entry |
| `plugin.archive.checksumMismatch` | Host | A downloaded archive does not match the index SHA-256 |
| `plugin.download.failed` | Host | An index or archive could not be downloaded |
| `plugin.signature.missing`, `plugin.signature.invalid`, `plugin.signature.untrusted` | Host | Package signature problems |
| `plugin.launch.missing` | Host | The packaged language server is missing or not executable |
| `plugin.runtime.missing` | Host | A declared runtime (for example Node.js) cannot be found, or is older than its `minimumVersion`, when the server starts |
| `plugin.legacyNative.updateRequired` | Host | An installed schema-1 native package must be replaced by its declarative version |
| `plugin.web.unknownMethod` | Host | A plugin page called a bridge method the host does not implement |
| `plugin.web.invalidRequest` | Host | A bridge call has malformed parameters |
| `plugin.web.forbidden` | Host | A bridge call names an instance, run, or path outside the page's plugin or workspace, or the page is closed |
| `plugin.function.invalidReference`, `plugin.function.invalidParams`, `plugin.function.unavailable`, `plugin.function.wrongPlugin`, `plugin.function.unknown` | Core | A [plugin-function](#plugin-functions) call is refused before it reaches the backend |
| `plugin.function.failed`, `plugin.function.invalidResult`, `plugin.function.revoked` | Core | A plugin-function call ended without a usable result |
| `plugin.function.invalidRegistration` | Core | A backend's register or unregister request was refused as a whole |
| `plugin.project.unavailable` | Core | The plugin declares no such project generator |
| `plugin.project.invalidInput` | Core | The project name or a field value is not accepted; `field` is `projectName` or `values.<id>`, or a step whose expanded path leaves the project |
| `plugin.project.templateInvalid` | Core | A template directory is missing, too large, contains a symbolic link or non-UTF-8 file, or uses an unknown variable |
| `plugin.project.invalidURL` | Core | An archive address does not expand to an HTTPS URL (HTTP only for loopback hosts) without credentials, query, or fragment |
| `plugin.project.archiveInvalid` | Core | A downloaded archive is not a zip, has an entry outside the destination, a symbolic link, a file that already exists, or expands beyond the size limit |
| `plugin.project.generationFailed` | Host | A command step failed or timed out, a download failed, or the project could not be moved into place |
| `plugin.function.recursiveCall` | Core | A backend asked the host to dispatch a domain operation or function |
| `plugin.host.unavailable` | Core | A backend asked for a host capability the negotiated protocol does not offer |
| `plugin.host.permissionDenied` | Core | A backend asked for a [host service](#host-services-protocol-version-2) its plugin's permissions do not grant |
| `plugin.host.invalidParams` | Core | A host-service request has malformed params, or (before version 3) unknown ones |
| `plugin.host.unsupportedOption` | Core, Host | From version 3, a host-service request names a field the host does not implement; `details.option` names it |
| `plugin.host.failed` | Core | The host could not complete a host-service request, or (before version 3) too many were unanswered |
| `plugin.host.contextExpired` | Host | The request names a workspace context that closed or has a newer generation |
| `plugin.host.authorityUnsupported` | Host | The context's authority (for example a remote workspace) does not implement the operation |
| `plugin.host.versionConflict` | Host | A versioned write names an older version than the current one |
| `plugin.host.limitExceeded` | Core, Host | A host limit on size, count, or rate was exceeded |
| `plugin.host.cancelled` | Core, Host | The backend cancelled the host request, or the host stopped it |
| `plugin.host.timeout` | Host | The host's own deadline for the operation passed |
| `plugin.host.notFound` | Host | The named resource does not exist |
| `plugin.host.readOnly` | Host | The resource or workspace cannot be written |
| `plugin.host.preconditionFailed` | Host | A state the request requires does not hold |
| `plugin.host.busy` | Host | The resource is in use; retry later |
| `plugin.host.rateLimited` | Host | Too many requests in a period |
| `plugin.backend.exited` | Host | A page's call, or a host operation for the backend, ended because the backend process exited |

Host-facing plugin states are `notInstalled`, `installed` (enabled or
disabled), `running`, `restartRequired`, `updateRequired`, and `failed`.

## Windows mapping

The Windows extension manifest (`Plugins/win/Official/*/plugin.json`) predates
this contract. Its adapter maps `languages[].extensions` to
`languages[].fileExtensions`, `lsp.server`/`lsp.args` to `languageServers[]`,
`lsp.requiredExecutables: ["node"]` to `runtimeDependencies`, and
`runActions.manifestFiles` to `test.projectMarkers`. Composer script discovery
is Windows-only behavior outside v1.

## API level 2: first-stage host-owned workbench UI

`pluginAPIVersion: 2` adds optional `ui` contributions and the `ui.contribute`
permission. API level 1 language packages continue to work. UI-only packages may
omit `languages`; every package must still declare a language provider or a
nonempty UI catalog. See `fixtures/hello-lithe.plugin.json` and the UI cases in
`fixtures/invalid-manifests.json`.

- `ui.toolWindows`: 1–64 entries with stable `id`, `title`, initial `placement`
  (`left`, `bottom` or `right`), integer `order` (default 0), and plain `text`.
- `ui.commands`: up to 128 entries with stable `id`, `title`, `toolWindowID`,
  integer `order` (default 0), and nonempty `placements` (`commandPalette`,
  `toolbar`, `menu`). A command opens one of the same plugin's tool windows.
- IDs use the plugin ID followed by a dot and a suffix. Duplicate or foreign
  identities, invalid references, unsupported placements and executable UI
  fields are rejected with `plugin.manifest.invalid`.
- Titles are at most 256 UTF-8 bytes and window text at most 65536 UTF-8 bytes.
  Text is displayed literally; it is never evaluated as HTML or a script.
  A window shows exactly one of `text` and, from `ui` 2 on,
  [`web`](#web-content-ui-2).
- Declare `onView:<window-id>` and `onCommand:<command-id>` for every window and
  command, plus `ui.contribute`. The existing permission and activation error
  codes apply. IDs and presentation order are normalized deterministically.
- The host exposes metadata without instantiating the module. Opening an
  entry activates the plugin's UI module on demand; a disabled, quarantined
  or safe-mode-suppressed module has no executable UI entries. Disabling it
  removes the entries and closes its visible content.
- The host owns header controls, widgets, menus, theme, ordering and layout.
  Saved workspace preferences override a declaration's initial placement and
  order. Moving or hiding content does not create a new module or session.
  Unknown and temporarily absent contributions never execute an action;
  placement/order preferences remain available if the plugin returns.

API level 2 is the first UI Contribution infrastructure stage. Its static text
windows and open-own-window commands are a supported subset, not the final public
extension API. The required window/text/command-target fields and rejection of
packages without language or UI contributions remain unchanged for v2 compatibility.
The macOS host supports mouse docking through the existing shared dock state;
that presentation behavior does not grant additional plugin execution capabilities.

### Web content (`ui` 2)

A plugin does not have to bring a UI: build systems get a host-drawn window
(see [Presentation](#presentation)), and text windows need no code. A plugin
that wants its own UI can show its own page in a tool window instead of
`text`:

```json
"requires": { "ui": 2 },
"permissions": ["ui.contribute", "ui.web"],
"ui": { "toolWindows": [{ "id": "…", "title": "…", "placement": "right", "web": { "entry": "ui/index.html" } }] }
```

- `web` needs `pluginAPIVersion` 3, `requires.ui: 2`, and the `ui.web`
  permission, which the install review lists like every permission.
  `requires.ui: 2` without a web window is `plugin.manifest.invalid`, so a
  text-only plugin stays installable on hosts that run only `ui` 1.
- `entry` is a package-relative `.html` path. `fixtures/web-panel.plugin.json`
  is the example; the web cases of `fixtures/invalid-manifests.json` are the
  rejections.

The window shell stays the host's: dock, title, activity-bar entry, order,
visibility, layout, and lifecycle are declared or managed exactly as for a
text window. The page fills the body only and cannot open, place, size, or
title a window.

Hosts load a page under these rules:

- Only files of the installed package are served, read-only, from an origin
  private to the plugin. The host's content security policy refuses network
  connections, remote resources, frames, inline scripts, and `eval`.
  Navigation away from the package, popups, and downloads are blocked.
- Web storage is not persistent. A page keeps its state through the bridge.
- The host creates the page when the window is first shown. It may destroy
  the page whenever the window is hidden, and does destroy it when the plugin
  is disabled, updated, or uninstalled. A page restores itself from its
  state.
- The root element carries `data-theme` (`light` or `dark`) and the host's
  `--lithe-*` CSS colour and font variables, updated with the theme.

Before the page's scripts run, the host defines `window.lithe`:
`lithe.version`, the bridge version (2 on current macOS hosts; version 2
adds the file dialogs to version 1, so a page checks it before offering
them), `lithe.context` (`pluginID`, `windowID`, `platform`, `locale`,
`theme`), `lithe.request(method, params)`, which returns a promise of the
result or rejects with `{ code, message }`, and `lithe.on(event, listener)`,
which returns an unsubscribe function. A page reaches only its own plugin's
build systems and the open workspace. Requests that run anything ask for the
same per-operation consent as the host's own controls (Lithe has no workspace
trust state at the moment), and
their output appears in the host's Build output window.

| Method | Parameters | Result |
| --- | --- | --- |
| `build.instances` | none | `{ instances: [{ id, buildSystemID, root, state, model?, options, error? }] }`: this plugin's detected instances, `model` as `build.decodeModel` returns it, `options` the stored values |
| `build.refresh` | `{ instance }` | `{}`; reloads the model |
| `build.runTask` | `{ instance, task, project?, target?, modelTask?, userArguments? }`, the selection of `build.taskPlan` | `{ run }` |
| `build.runTests` | `{ instance, project?, target?, suite?, case? }`, the selection of `build.testPlan` | `{ run }` |
| `build.cancel` | `{ run }` | `{}` |
| `build.dependencies` | `{ instance, project? }` | the tree `build.decodeDependencies` returns |
| `build.setOptions` | `{ instance, values }` | `{ options }`, checked by `build.resolveOptions` and stored like values set in the host's option list |
| `workspace.openFile` | `{ path, line?, column? }`, a path inside the workspace | `{}` |
| `ui.getState`, `ui.setState` | none, `{ state }` | `{ state }`, `{}`; JSON of at most 64 KiB per window and workspace |
| `functions.list` | `{ instance? }` | `{ functions }`: sorted IDs of the functions the instance's provider, or without `instance` the plugin's [backend](#plugin-backend), currently offers; starts that process |
| `functions.invoke` | `{ instance?, function, params?, call? }`, without `instance` a call to the plugin's backend; `params` an object, `call` a page-chosen ID of at most 128 characters that the page never used before | `{ value }`, the function's result |
| `functions.cancel` | `{ call }` | `{}`; a call still awaiting consent never starts, a call waiting for its provider to start ends at once while the start goes on, and a call that already ended is ignored |
| `dialog.openFile` (bridge 2) | `{ title?, extensions? }` | `{ path }`: the absolute path of the file the user chose, or `null` when the dialog was cancelled |
| `dialog.saveFile` (bridge 2) | `{ title?, suggestedName?, extensions? }` | `{ path }` as for `dialog.openFile`; the host has asked before replacing an existing file, and nothing is written |

| Event | Payload |
| --- | --- |
| `build.instancesChanged` | `{ instances }`, as `build.instances` returns them |
| `build.runChanged` | `{ run, instance, state, exitCode? }`, `state` one of `running`, `succeeded`, `failed`, `cancelled` |
| `functions.progress` | `{ call, instance?, function, message?, percentage? }`, only for a call made with `call`; `instance` absent for a backend call |
| `ui.themeChanged` | `{ theme }` |

The file dialogs are the host's: they name the plugin that asks, a page
has at most one open at a time, and the page learns only the path the user
chose. `extensions` are up to 16 file name extensions without the dot;
`suggestedName` is a file name, not a path. A page passes the path to its
backend, which reads or writes the file; the page itself still reaches no
file.

Bridge errors are `plugin.web.unknownMethod`, `plugin.web.invalidRequest`,
and `plugin.web.forbidden`. Build requests also report the `build.*` codes.
Function requests report Core's codes unchanged (`plugin.function.*`,
`requestCancelled`, `requestTimeout`); a failure the plugin reported also
carries its own `pluginErrorCode`, which the host never interprets. A call
Core could not deliver, such as a write to a backend that exited, keeps
Core's transport code (`processFailed`) and carries the OS diagnostic only in
its message. A backend that stops reading its input is ended when a write to
it stays blocked past the call's timeout, or briefly after the call was
cancelled or the provider stopped. A page
has at most 16 function calls accepted at once, counting calls still awaiting
consent, and closing it cancels them. Reusing a `call` ID is
`plugin.web.invalidRequest`, also after that call ended.
`functions.list` and `functions.invoke` with an `instance` ask for the same
consent as the host's provider requests: once given for a plugin and
workspace, it holds until the project is closed. Calls to the plugin's
backend ask for none; the install review covered it.
macOS implements web content with WKWebView and advertises `ui: [1, 2, 3]`
(including the native controls described below).
Windows implements web content with WebView2 under a plugin-private
`lithe-plugin://` origin and also advertises `ui: [1, 2]`; its bridge v0
answers `ui.getState`, `ui.setState`, and `workspace.openFile`, and returns
`plugin.web.unknownMethod` for `build.*` and `functions.*` until the Windows
build-system capability lands. Windows does not advertise `ui` 3.

### Future public extension direction (not implemented in API level 2)

- Plugins may bring their own UI as [web content](#web-content-ui-2) inside
  host-owned windows. Native trees/lists and panel actions now use the separately versioned
  [native schema](#host-rendered-native-content-ui-3-native-schema-1).
  Forms and broader component composition remain follow-up work. Built-in or trusted native modules may
  register Native View/Renderer Factories under the same host window
  management. This does not restore arbitrary dynamic third-party Swift
  Bundle loading; ABI, signing and isolation need separate design.
- Actions declare handlers and availability/context conditions independently of
  Tool Windows. Commands, menus/context menus, toolbars, status bars and settings
  contributions must not require dummy windows. Opening a window is one action kind.
- A new, explicitly versioned Extension Contract will cover Language/LSP,
  BuildSystem/Task, RunConfiguration/Test, DebugAdapter and ServiceProvider,
  including pure Build/Debug/Services packages with no UI or language declaration.
  Exact version numbers, handler transport and fields are not published here.
- Built-in and plugin providers should use the same typed domain registries.
  Providers supply behavior/processes/data; hosts own scheduling, permission,
  presentation and lifecycle. Reuse existing language, build, run/test and DAP
  backends instead of duplicating them or branching by plugin name in composition.
- Services will accept general resources with provider/descriptor/instance/status/
  actions/logs semantics. Disabling unregisters contributions and releases
  plugin-owned resources; it must not implicitly stop independently running
  external services. An explicit stop action requires its own authorization.
- API level 2 remains supported unchanged. UI Schema evolves independently;
  domain extension points need a new contract version and compatibility fixtures.
  Windows implements its own host adapter over shared data, not SwiftUI types.

Planned end-to-end samples are a native Tree with an independent refresh command,
Build Task in existing Build, ServiceProvider in Services, and third-party DAP in
existing Debug UI. Each must verify disable/re-enable, resource ownership and
restoration; view-bearing samples also verify layout persistence. These samples
are future acceptance criteria, not claims about current runtime support.

The design source is the [proposed public Extension Contract and Provider API](https://github.com/1lck/Lithe-IDEA/blob/preview/.agents/notes/proposed/architecture/2026-10-13-public-extension-contract-and-provider-api.md).
Current runtime behavior is recorded in the [first-stage workbench UI Note](https://github.com/1lck/Lithe-IDEA/blob/preview/.agents/notes/implemented/architecture/2026-10-12-workbench-ui-contributions.md).

### Current Windows availability
Windows can validate API level 2 through Rust Core but its UI adapter has not
implemented this contract yet. Its marketplace must filter unsupported API
levels until that adapter is available.

### Existing community store and Lua template

The community index is [Lithe Store](https://github.com/Lithe-IDEA/Lithe-store).
The [Lua plugin template](https://github.com/Lithe-IDEA/lithe-plugin-lua) uses
schema 2 / API level 1 for language-server and run providers; those declarations
remain valid. To add a host-rendered view to that template:

1. Set `pluginAPIVersion` to 2. Keep the existing language and execution fields.
2. Add `ui.contribute` to the existing permissions and the new `onView` /
   `onCommand` events to the existing activation events.
3. Add `ui.toolWindows` and `ui.commands`; prefix every ID with the plugin ID,
   for example `io.github.lithe-idea.lua-support.tools`.
4. Keep `vendor.signatureRequirement: "none"` for community packages. The
   existing package checksum, user install review and content digest still
   apply; UI does not bypass them.
5. Set the new Store version entry's `pluginAPIVersion` to 2. The index schema,
   release archive format and SHA-256 rules stay unchanged. Only list platforms
   with an implemented API level 2 UI host (currently macOS).

`fixtures/hello-lithe.plugin.json` is a contract fixture in the reserved test
namespace, not a ready-to-publish community package. Change its ID and all
references to your own namespace before using it in Lithe Store.

### UI icons (macOS host)

API level 2 tool windows and commands accept an optional `icon`. Prefer a stable
host icon ID; it resolves through Lithe's existing icon library, not SF Symbols:

```json
"icon": { "host": "database" }
```

Supported host IDs: `tool-window`, `plugin`, `database`, `services`, `terminal`,
`search`, `refresh`, `run`, `debug`, `settings`, `add`, `remove`, `git`, `problems`.
These IDs are public; bundled SVG paths remain implementation details.

Custom SVG and PNG icons are relative to the plugin package root:

```json
"icon": {
  "path": "icons/database.svg",
  "darkPath": "icons/database-dark.svg",
  "mode": "template"
}
```

`mode` defaults to `template`: the host tints the image using the containing
control's theme and selected/hover state. `original` preserves brand colors;
control backgrounds and disabled opacity still follow the host. `darkPath` is
optional; without it the same resource is used in both themes. Brand authors
must make that resource legible in both themes or provide a dark variant.
`host` cannot be combined with resource paths or original-color mode.

The host owns icon size: 20pt tool-window rail and 16pt actions/menus/palette.
Panel titles are text-only: no title icon, outline or bottom divider. A declared
window icon remains available in the activity rail and management menus.
Aspect ratio is preserved inside each icon slot. Plugin-specified
size, color, stroke, arbitrary style, remote URLs and SF Symbol names are rejected.
Stroke geometry belongs to the asset; authors should follow the host icon
weight, rather than expecting the host to rewrite paths or PNG pixels.

Window and toolbar management submenus reuse the same declared icons at the
host menu size. Template icons in the command palette use the host selected-text token on the
selected row; brand icons retain their theme variant when keyboard selection moves.

Files must be regular files inside the verified package, without symbolic links
in their path. Each resource is limited to 256 KiB and 1024×1024; unique icon
bytes per package are limited to 8 MiB, with at most 4,194,304 total image pixels. PNG is decoded as a single image. SVG
accepts static shapes, groups, gradients, clip paths and the standard SVG version attribute; scripts, event handlers,
external references, embedded images, style elements/attributes, entities and
DOCTYPEs are refused. Use explicit presentation attributes for SVG colors.
Unknown fields and unsupported formats are rejected at installation and launch.

Window entries without an icon use the shared generic tool-window icon. Commands
without an icon remain text actions (palette retains its existing action marker).
Missing/unreadable declared resources reject the package instead of silently
using a different image. Assets are read-only and held in process memory; no
runtime disk cache or app-bundle write is created. Installed icon bytes follow
the existing package signature/digest, update and rollback lifecycle.

macOS 宿主布局菜单允许把已注册工具窗口移到左侧、右侧或底部，并保存入口
顺序与显隐；`ui.toolWindows[].placement` 仍只声明首次使用的 `bottom`/`right`
位置，未新增插件契约值。项目、提交和搜索采用相同的工具窗口注册路径，
原生业务内容保持宿主所有；左侧恢复插件窗口仍按 `onView` 激活所属模块。

macOS 动作的可见、可用、勾选和激活中状态由宿主计算，不接受清单中的可执行
条件脚本。窗口尚在激活时，其打开命令在工具栏、菜单和命令面板禁用；窗口入口
仍可取消显示。多个窗口同时请求同一插件模块时只构造一次；禁用或关闭会取消
并清理在途激活，旧的菜单或命令引用不能重新调用已禁用的贡献。

#### Shared executable candidates (`executableResolution` 1)

Declare executable sources in `invocation.executables`, in preference order.
Array order is the recommended form; no custom path setting is required for a
plugin that only needs automatic discovery. Existing `projectFile`, `environment`,
`command` and `runtime` sources retain their v1 behavior. The shared
`executableResolution: 1` capability adds `setting` and ordering metadata:

```json
"executables": [
  { "id": "selected", "kind": "setting", "settingID": "toolPath" },
  { "id": "wrapper", "kind": "projectFile", "path": "mvnw" },
  { "id": "system", "kind": "command", "command": "mvn" }
]
```

A `setting` references a declared **global file** setting with `effect: "reload"`
or `"nextRun"` (`settings: 2`). Core receives raw `request.settings`. An absent
value uses the declared default; an explicit empty string emits a setting candidate
with `path: null`, which skips. A nonempty value must satisfy the setting rules,
be absolute, and have no surrounding whitespace or controls. Invalid stored
values reject the invocation instead of invoking the normal settings display
resolver's fallback-to-default behavior. Project overrides never select tools.
The host checks file permissions and versions: a configured failure is terminal,
including a failure to probe, and must not fall back to subsequent candidates or
a Provider's own lookup. Paths with spaces remain single paths. The selected
setting's directory precedes PATH. Runtime candidates construct their environment
before version probing and reuse it for execution; a rejected candidate's
environment does not leak into the next choice. Provider hints and task/test
execution use this same plan/selection mechanism. If resolution fails before a
configured candidate is reached (for example, an earlier Runtime is missing),
any nonempty setting in the tool or Runtime candidate sets still forbids the
Provider's independent lookup. All-empty settings retain automatic-discovery
fallback. This check applies after failure, so an earlier successful candidate
is unaffected by a later unused setting.

Optional metadata applies within **one candidate set owned by one plugin**:

- `id` is a unique stable identifier; anonymous candidates cannot be anchors.
- `priority` is a signed 32-bit integer; higher wins, absent means 0. Ties retain
  original array order.
- `insertBefore` or `insertAfter` names an ID in this set. One candidate cannot
  combine either with `priority`, or declare both insertion fields. Constraints
  mean relative order, not immediate adjacency.
- Normalize the complete set into a directed graph before platform filtering.
  Repeatedly select a zero-indegree node by descending priority, then original
  index; emit it and remove its edges. Explicit edges take precedence over
  priority. Duplicate/invalid IDs, unknown anchors, cycles/self-edges and
  conflicting metadata are manifest errors. Filter platforms only after sorting,
  so anchors remain valid even if they do not apply to the current platform.

`plugins::executables` owns the reusable source types and deterministic order;
`ExecutableCandidateResolver` receives file-system, Setting (already validated by
Core), Environment, Runtime and command-discovery capabilities from the host.
Results distinguish `skip`, `resolved` and `terminalFailure`; plugins declare data
and cannot inject host native code. Each operation uses a value snapshot for its
settings/environment and ordered plan. Passive import does not resolve/probe
runtimes or execute project wrappers. A project candidate remains project code
and is only executed through the consumer's existing trust/user-action workflow.

This PR connects Build Systems and their custom Runtime Dependencies. Own Build
Providers already adapt command/runtime launches through BuildToolResolver and
receive the selected build tool as `tool.executable`; their ServerProcess protocol
is unchanged. Language Servers, Execution Providers, and other ServerProcess
launch forms can later adapt into this same resolver without changing their
manifest structure all at once: preserve package-realpath/executable checks,
per-operation consent (there is no workspace trust state yet), auto-start
restrictions, runtime ownership and cancellation.
They do **not** advertise support for new candidate declarations until their
adapter is implemented; this capability currently authorizes the Build candidate
positions only. Windows does not advertise it yet.

Compatibility: Cargo 0.1.1 already shipped as a preview with `buildSystems: 2`
and `invocation.executableSetting`. That field is deprecated and supported only
as a v2 input adapter: prepend an equivalent setting candidate to the normal
list; never emit `configuredExecutable` or use a separate resolution branch.
New plugins use the fifth candidate and `executableResolution: 1` (Build v1
remains sufficient). Legacy manifests do not need the new capability; hosts
without it reject new-style plugins before decoding unknown fields. Published
0.1.0/0.1.1 archives remain immutable; migration is a new plugin version.

See [`build-tool-path.plugin.json`](fixtures/build-tool-path.plugin.json).

### Host-rendered native content (`ui` 3, native schema 1)

macOS supports `requires.ui: 3` for a tool window whose sole body is `native`.
Text and Web windows retain their existing behavior. Windows does not advertise
ui 3 and rejects these packages before installing them. The independently
versioned [native schema](native-ui.schema.json) has no style, script, HTML or
host-action fields. The host renders every control with its shared theme.

See [native-panel.plugin.json](fixtures/native-panel.plugin.json) and the runnable
[Node SDK Sample Explorer](https://github.com/Lithe-IDEA/lithe-plugin-docs/blob/main/sdk/node/examples/sample-build/plugin.json).
`native.kind` is `tree`, `list` or `form`; `nodes` contains literal `id`, `label` and
optional `children`. IDs are stable, case-sensitive ASCII letters/digits plus
`._-` (1–128 bytes). The component, initial nodes and actions have distinct IDs.
The entire node set is limited to 2000 nodes and depth 16 (root depth 0); labels
are nonblank and at most 1024 UTF-8 bytes. Lists reject nested children.

A `form` declares `nodes: []`, an empty `contextMenu`, at most 32 `controls`
and 16 `buttons`; at least one control or button is required.
Tree/list panels cannot contain controls. Each control has a unique `id`, literal
`label` (1–256 UTF-8 bytes), `kind`, initial `value`, optional `enabled` (default
true), and optional `onCommit` referencing a declared `invoke` action that does
not require a selection. An optional literal `info` (1–1024 UTF-8 bytes) renders the shared information
icon beside the label; tooltip timing, pinning, accessibility and styling are host-owned.

- `input` / `search`: string `value` (at most 1024 UTF-8 bytes), optional `placeholder`
  (at most 256 UTF-8 bytes), no options. Uses the IDE settings text-field owner.
- `select`: string `value` equal to one of 1–128 unique `options: [{id,label}]`;
  option IDs use the standard identifier rule, labels are 1–256 UTF-8 bytes.
  No placeholder. Uses `LitheSettingsSelect`, including its popup and keyboard behavior.
- `segmented`: string value and 1–8 options, using the same option contract and
  the shared segmented selector; no placeholder.
- `editor`: string value up to 8192 UTF-8 bytes, optional `rows` (2–12, default 4),
  no placeholder/options/onCommit. Reuses the shared multiline editor; Enter inserts
  a newline and form buttons submit its current value.
- `stepper`: finite numeric value, required `minimum`, `maximum` and positive
  `step`; bounds and step are limited to ±1e9/1e9, and value must fit the range.
  No placeholder/options. Uses the shared settings stepper and bound behavior.
- `checkbox`: boolean `value`, no options or placeholder. Uses `LitheSettingsCheckbox`.

Forms may declare `layout: {"columns":12}` (1–12 columns). Each control may
provide `span` (1–columns); omitted span fills a row. Controls pack in declaration
order, wrapping before a span would exceed the row. Without layout, the form
retains its original single-column presentation and must omit span. Layout is
form-only. Gaps, alignment and breakpoints remain host-owned; plugins cannot
supply pixels, CSS or gap values. macOS uses a native `Layout`, 12pt gaps,
top-aligned variable-height rows, and switches to one column below 640pt of
content width. Reflow preserves the same controls, local values and focus.

Buttons reference an existing non-selection action through `action`, have stable
`id`, literal `label`, optional `primary`, `enabled` and `info`.
Text actions reuse the host's shared natural-width button style and 6pt action
spacing; a narrow action group falls back to vertical stacking. Deprecated
`buttons[].width` (`content`/`fill`) and `buttons[].span` are accepted for older
experimental packages, but do not change button width or action-group layout.
Grid spans continue to apply to value controls. The declaration cannot override
button colors, fonts, chrome, padding or fixed/max widths.

Input/search editing saves local values without executing plugin code; Return commits.
Selectors, segmented selectors, steppers and checkboxes commit after a changed value. Omit `onCommit` to keep
a field local. Commits pass **all** current fields as `params.values` (strings,
booleans and numbers keyed by stable control ID), together with `selectedID: null`.
The subsequent form source call also receives `{values}` and returns `{nodes: []}`.
Disabled fields still contribute their values; they cannot edit or commit.
A pending call disables all fields. Values use the existing 64 KiB per-plugin,
per-window, per-workspace state store; removed fields, invalid types and removed
options are discarded when restoring. Provider replies never overwrite local
fields. Form declarations and choices are static in this version.
See [native-form.plugin.json](fixtures/native-form.plugin.json) and
[host UI acceptance fixture](https://github.com/1lck/Lithe-IDEA/blob/preview/macos/Tests/Fixtures/native-ui-lab/README.md) for acceptance.

An optional `source` names this plugin's `buildSystemID` and a function returning
`{ nodes: [...] }`. This phase uses the existing provider transport; it adds no
new backend, provider registry, or process protocol. There must be exactly one
detected instance of that build system in the workspace; zero or multiple
matches produce an error instead of silently targeting a different root.
Static panels omit `source` and declare empty actions and placements.

`actions` declares at most 64 independent handlers with `id`, literal `title`,
`kind` (`refresh` or `invoke`) and `requiresSelection`. A refresh reloads the
source and cannot require selection or name a function. An invoke names a
`function` and receives `{ selectedID: string | null }` (forms also include `values`). Invocations return an
optional `{ message }`, then the host reloads the source. `toolbar` and
`contextMenu` contain distinct references to declared action IDs in display
order. Toolbar actions are icon-only and appear when the pointer enters the whole
panel, like the host hide control; keyboard and accessibility focus also reveal them.
An optional `icon: {"host":"search"}` reuses the host icon vocabulary (including
`reset`); native actions do not load custom package icons. Without an icon, refresh
uses the refresh icon and invoke uses the generic run icon. The literal title is
the tooltip and accessibility name. A context-menu action selects its clicked row before running; selecting
a row alone never starts a provider function. These are panel-local actions;
this phase does not change API-v2 commands into arbitrary function handlers.

The host allows one operation per panel, disables actions while busy, and
shows loading, empty, failure and success feedback. A source reply is at most
1 MiB and follows the same node limits; invalid data preserves the last valid
rows. Selection and expansion use stable IDs and the existing per-plugin,
window and workspace state store (at most 64 KiB). Arrow keys move selection,
expand/collapse nodes and select a parent; hidden/reopened panels restore state.
Provider calls retain existing consent, scope checks, timeout and cancellation.
Hiding a native panel cancels its pending operation. Disable, package replacement
and workspace close synchronously invalidate it through the existing shared
plugin-page lifecycle; late replies cannot publish. All state is outside the
installed package and application bundle.

Schema 1 loads the complete node set on refresh. Forms, lazy child data sources,
multi-instance selectors, global function commands, native renderer factories
and Windows rendering remain follow-up work under #1209; this subset does not
claim completion of that whole issue.
