# Plugin-owned toolchains: Core foundation

**Status: shared Core implemented; the macOS settings pages run both routes
read-only.** Core validates data and resolves captured facts; it does not launch
providers, probe programs, parse manager files, watch paths, write pins, or
download tools. The macOS settings host expands `discoveryPlan` scans, starts or
reuses each enabled provider's plugin backend, sends `toolchains/query` through
`lsp.toolchainRequest`, passes every raw reply with native facts to `decodeReply`,
runs the definition's version probe on executables Core returns from
`candidates`, and shows the result. Any change to a watched input reloads the
whole snapshot. Nothing is saved by these pages. The pinned Stage D integration
adds a separate fresh-resolution adapter for macOS Build and Provider Run;
settings detections are never used as launch permits. Existing Java and
language-server consumers still use their previous adapters. Windows has no
toolchain adapter and does not advertise `toolDefinitions` or
`toolchainProviders`, so Core refuses packages that require them there.
Publisher signatures provide independent origin evidence when present; legacy
unsigned records never do.
Consumer migration, the native query lifecycle and cache, pin saving and
version-manager plugins are not specified yet. The manifest shape is
[plugin-manifest.schema.json](../plugin-manifest.schema.json).

## Manifest admission and registry

`toolDefinitions[]` needs `requires.toolDefinitions: 1` and
`requires.executableResolution: 2`. `toolchainProviders[]` needs
`requires.toolchainProviders: 1`, `backend: 2`, `serverProcess: 1`, and permissions
`backend.launch` / `toolchains.provide`. Capability lists are exact: missing or
unused capabilities reject the manifest. A definition/provider alone is a valid
contribution. Old executable candidate sets retain their strict source types.
Build consumers may also require executableResolution 2 for their existing
`toolchain` candidate without contributing a definition; they do not gain
definition-owned candidate fields.

Definitions own IDs, labels/icons, `executableLayouts`, ordered `executables`,
`version`, `homeLayouts`, `discovery`, `homeVariable`, `commands`, `wrappers`,
`exports`, `pathPrepend` and argv `launch`. Counts, relative paths, bounded globs,
platforms, templates and version expressions are validated recursively; unknown
fields fail closed. Candidate graph ordering reuses the existing shared graph
validator and cannot cross layer barriers. This slice does not support a
definition candidate of `kind: runtime`, or `toolchainConsumers`.

Provider entries contain `{id, displayName, tools, watchFiles?}`; each watch entry
is `{pattern, reader: "native" | "compatible"}`. A present `watchFiles` lists 1-32
unique patterns; an absent one makes an installation-only provider, whose
replies may not contain statements. Providers share the plugin's
backend; admission permits a host-query trigger without a page or startup event,
and the macOS host starts the backend on the first query. Bootstrap must be `packaged`, or
`runtime` with `packagedRuntime`, without discovered runtime dependencies. Existing
runtime launch tool restrictions remain; generic consumer launches are not added.

`toolchains.provide` may influence which program a defined tool launches. It does
not grant arbitrary command replacement, installation, network or workspace-code
execution. Short definition IDs require independently verified official origin;
community definitions use `<own-plugin-id>:<local-id>`. Community providers may
answer short IDs. No host-owned tool table, name alias or manager parser is added.

A native Build consumer that directly executes a tool currently accepts only
`["${executable}", "${arguments}"]`: its tool context carries a program and
separate Build arguments. Extra launch flags or `${home}` tokens are refused
before probing, rather than dropped. An installation dependency instead consumes
checked version evidence and declared exports; it does not instantiate the tool's
entry-launch recipe. For example a runtime can declare a JAR recipe while a build
engine consumes only that runtime's installation and environment. Such a dependency
is not published as a direct executable binding. Entry processes continue to use
their own declared process recipe; supporting more direct templates remains pending.

## Two installation routes

A definition receives installations through either route, or both. Neither is
required: a tool may rely only on pins, project files, global defaults and
login-shell commands.

| Route | Declared by | Fits | Runs |
| --- | --- | --- | --- |
| Declarative discovery | The definition's `discovery`, `homeLayouts`, `homeVariable`, `commands` and `version` | Installations with a fixed directory shape: a single-component glob under the user home, an environment variable or an absolute system directory, an optional home suffix, and a version expression over a probe | The host expands `discoveryPlan` scans; no plugin code runs |
| Provider query | `toolchainProviders[]` answering `toolchains/query` | Locations those primitives cannot express: registries, property lists, manager databases, command output, manager-specific version files | The provider's packaged backend |

The declarative primitives are frozen: root kinds stay `home`, `environment`
and `absolute`, and patterns stay single-component `*` globs. A new installation
shape is answered by a provider, not by a new root kind or a host parser. The
plugin that defines a tool may also declare a provider for it; omit
`watchFiles` when it only reports installations. A provider backend never runs
on a tool it discovers: the bootstrap rules above apply to a defining plugin's own
provider as well.

`discoveryPlan` lists both routes per tool. The host expands `scans` into
`systemInstallations`, recorded with provenance `host:system`, and queries every
qualified provider in `providers`. In the automatic layer both routes form one
candidate set. One canonical home counts once: a provider answer labels it
before the host scan, and among providers the smaller qualified ID labels it.
This label is display provenance and never chooses between different homes;
equal highest versions in different homes remain an `automatic` conflict that
names every route.

## Commands and envelopes

All commands accept UTF-8 JSON values and have a 4 MiB input budget. Success is
`{status:"ok", <key>:value}`; refusal is `{status:"rejected",error:{code,message,
field?}}`. Errors are structured policy outcomes, not host-localized UI text.
Future hosts render stable codes through shared i18n; English diagnostic messages
are not a substitute for that adapter. These commands perform no native I/O.

| Command | Input | Success key |
| --- | --- | --- |
| `toolchains.registry` | `{plugins:[{manifest,verifiedOfficial}]}` | `registry` |
| `toolchains.decodeReply` | Query/response and native evidence described below | `snapshot` |
| `toolchains.failureReply` | `{params,code}` described below | `reply` |
| `toolchains.resolvePins` | `{document,directory,tool}` | `resolution` |
| `toolchains.resolve` | Captured resolver input described below | `resolution` |
| `toolchains.checkVersion` | `{registry,tool,output,minimumVersion?}` | `version` |
| `toolchains.discoveryPlan` | `{registry,platform}` | `plan` |
| `toolchains.candidates` | Captured discovery input described below | `candidates` |

Every `registry` input is the raw `{plugins:[...]}` request, not a previously
normalized result. Core revalidates complete production manifests and the
host-supplied `verifiedOfficial` boolean; a plugin cannot assert that evidence
inside its own manifest. Output is `{definitions:[{pluginID,definition}],
providers:[{pluginID,provider}]}` in stable order. Duplicate plugin/tool ownership
rejects the batch without replacing earlier owners. Limits are 128 plugins,
512 aggregate definitions and 256 aggregate providers.

## Provider backend negotiation

A provider answers over its plugin backend's JSON-RPC connection, the same
`serverProcess` transport other backend requests use. The backend need not
declare a language, language server, Build provider or callable function.

The host starts the backend with `lsp.startServer` and passes the manifest's
provider IDs as `toolchainProviders`. Only a plugin-owned session that declares
at least one provider is offered the protocol, in the client capabilities of
`initialize`:

```json
{"experimental": {"litheToolchains": {"versions": [1], "providers": ["first", "second"]}}}
```

`providers` lists the declared IDs in sorted order. The backend selects in the
server capabilities of its `initialize` result:

```json
{"experimental": {"litheToolchains": {"version": 1, "providers": ["first"]}}}
```

`version` must be an offered version and `providers` a non-empty list of
offered IDs without repeats; other fields are ignored. Any other answer, including
an unoffered version, an undeclared, repeated or non-string ID, or an empty list,
enables no provider at all rather than a partial set, and no query is sent. On
success Core emits a `toolchainProviders` runtime event with `result: {providers}`.

The host sends each query with `lsp.toolchainRequest`
`{sessionId, operationId?, params, timeoutMilliseconds?}`, where `params` is the
`toolchains/query` params described below; Core writes the request with that
method and its own JSON-RPC ID. A `params.providerID` the backend did not select
is refused with `not_supported` and details `plugin.toolchain.providerUnavailable`,
and nothing is written. `timeoutMilliseconds` is clamped to 1-60,000; without it
the session's request timeout applies. Completion carries `result.value: {id,
response}`: the wire ID and the complete, unvalidated response, error replies
included. The host passes it with the same `params` to `decodeReply`.
Cancellation and late results follow
[`lsp.toolchainRequest`](https://github.com/1lck/Lithe-IDEA/blob/preview/shared/contracts/rust-core-api.md).

## Provider reply validation

`decodeReply` takes `{registry,pluginID,request,response,currentGeneration,
filesystem,platform,filesystemCaseSensitive?,workspaceRoots?}`. `pluginID` binds
the host-owned session, not a provider claim. `platform` is `macos`, `windows` or
`linux`; native filesystem case policy is explicit where platform defaults differ.

`request` is `{jsonrpc:"2.0",id,method:"toolchains/query",params:{operationID,
generation,providerID,authority:{kind:"local"},context,workspace,tools}}`.
`context` is `{contextID,generation}` or `null`; workspace queries require it.
`workspace` is `{rootID,root,directory}` or `null` for global-only queries.
The JSON-RPC `id` is a positive integer or a nonempty string of at most 128
UTF-8 bytes without control characters; the reply preserves its exact type and
value. Core's LSP transport uses string IDs. Numeric `1` and string `"1"` are
distinct identities and cannot acknowledge each other's request.
`directory` is normalized workspace-relative, with `.` for the opened root.
Tools are unique and sorted. This envelope is validated as inert data; no query
is dispatched and no protocol capability is negotiated by this command.

Successful `response` echoes JSON-RPC `id` and has `result:{operationID,generation,
providerID,installations,statements,watch}`. Installations are `{tool,version,home}`.
Statements are `{tool,scope,source,request,installation,kind,reader}`: scope is
`project|global`, kind is `environment|declaration`, reader matches the provider's
declared watch pattern; `installation:null` records an unmet requirement. Request
syntax is opaque. Non-null installations must reference the same tool in the
reply. `watch` contains absolute native inputs, including missing paths.

Each native filesystem fact is `{path,canonicalPath,kind,executable?}` with kind
`file|directory|missing`. These facts come from the authority-local host, never
the provider. Core checks unique paths, actual-kind evidence, definition-owned
executable layouts, canonical home containment and exclusion of all workspace
roots. Provider homes are final tool homes; `homeLayouts` is not reapplied.
A non-missing fact also attests its canonical target with the same kind and mode,
so canonical results found through a link are checked against the same snapshot;
facts that disagree about one canonical path reject it.
Inactive/unknown tools lose installation authority; bounded requirement facts
remain diagnostic only. Lists normalize deterministically; sort order never
chooses between conflicting requirements. A reply is bounded to 1 MiB, 512
installations, 256 statements and 256 watch paths; mismatched IDs/generations,
remote authority, unsafe paths and malformed error mappings reject it.

The snapshot contains `{installations,statements,watch,diagnostics}`; normalized
entries carry qualified `<pluginID>:<providerID>` provenance and project source
directory. Cancellation, deadlines, cache invalidation and whole-generation
requery remain native-client implementation work, not behavior performed by this
decoder.

### Error replies

A provider that cannot answer returns a JSON-RPC `error` instead of `result`.
`error` has exactly `{code,message,data}`, and `data` has `{code,operationID,
providerID}` plus an optional `details`:

- `code` is a number from the table below and `data.code` is the stable code
  on its row. Each number has exactly one stable code.
- `operationID` and `providerID` equal those of the request `params`.
- `message` is non-empty diagnostic text of at most 1,024 UTF-8 bytes without
  control characters. It is shown as provider text and never selects behavior.
- `details`, when present, is an object of at most 4,096 bytes serialized. It
  must not carry credentials.

`decodeReply` then refuses with the stable code and the provider's `message`.
An error reply that breaks any of these rules, including an unknown number or a
number that does not match `data.code`, is refused as
`plugin.toolchain.invalidReply`.

| JSON-RPC | Stable code | Meaning |
| --- | --- | --- |
| `-32601` | `plugin.toolchain.methodUnavailable` | The backend does not serve the query method |
| `-32602` | `plugin.toolchain.invalidParams` | Malformed request or invalid declared input |
| `-32800` | `plugin.toolchain.cancelled` | The caller cancelled the request |
| `-32070` | `plugin.toolchain.permissionDenied` | A permission, review or enabled-state prerequisite is missing |
| `-32071` | `plugin.toolchain.authorityUnsupported` | The provider cannot serve the requested authority |
| `-32072` | `plugin.toolchain.timeout` | The local deadline passed |
| `-32073` | `plugin.toolchain.providerUnavailable` | The backend failed to start, disconnected, or its upstream query failed |
| `-32074` | `plugin.toolchain.invalidReply` | Malformed reply, or an installation reference to another tool |
| `-32075` | `plugin.toolchain.limitExceeded` | A reply, scan or watch budget was exceeded |
| `-32076` | `plugin.toolchain.unsafePath` | A path is not absolute, escapes its containment or fails executable checks |
| `-32077` | `plugin.toolchain.operationExpired` | The context or generation was already stale when the query was sent |

A missing installation, an incompatible version or conflicting requirements are
not errors: report them in `result` (an unmet requirement has
`installation:null`) and let the resolver give the reason.

When a query gets no reply at all, the host asks `failureReply` for one. `params`
is the query's own `params` and `code` is `plugin.toolchain.timeout` (the local
deadline passed) or `plugin.toolchain.providerUnavailable` (the backend failed to
start, disconnected or did not offer the provider). The result is
`{id,response}`, the same shape `lsp.toolchainRequest` completes with, holding the
mapped JSON-RPC error for that operation and provider. The host decodes it with
the same request like any provider error. Cancellation and every other code are
rejected, so a cancelled or refused query never becomes a missing provider.

## Pins and snapshot resolution

`resolvePins` validates an inert local document `{version:1,toolchains,pins?}`.
`toolchains` retains legacy entries; `pins` maps directory keys to tool maps of
`{home,version,provider}`. It returns `{pin,sourceDirectory}`, both `null` if absent.
Nearest exact ancestor wins; sibling prefixes do not match. Dormant pins survive
missing definitions. No lookup grants execution authority or writes a file.
Saving, conflict protection and `.lithe/.gitignore` updates are not implemented.

`resolve` requires `{registry,tool,directory,operationID,generation,context,
platform,workspaceRoot,filesystem}` and accepts `workspaceRoots`,
`filesystemCaseSensitive`, `local`, `minimumVersion`, `probes`, `queries`,
`systemInstallations`, `globalDefault`, `environment`, `commandHomes`,
`projectCodeAllowed`, `providerChoices` and `fixed`. `local` defaults to an empty v1
document. Probes are host observations `{executable,output,exitCode}` keyed by the
canonical executable a selection reports; system installations are `{tool,home}`.
Shell environment home variables and `commandHomes` come from the native login-shell
adapter, not command-name guessing. An environment candidate selects only through
its declared `path` layout.

Each query is a complete `decodeReply` input, bound to the resolver's registry,
generation/context, root/directory, case policy, roots and filesystem snapshot.
The resolver accepts local workspace queries here; global-only decoder inputs
are not a substitute for the workspace-bound query round. `providerChoices`
records explicit project/global provider or automatic-installation choices; it
does not activate providers or bypass their evidence checks.
Its shape is `{project?:"pluginID:providerID",global?:"pluginID:providerID",
automatic?:"absolute-installation-home"}`; choices not present in the current
validated candidate set confer no authority.
Unavailable/timed-out optional providers remain visible as `providerUnavailable`
diagnostics while lower sources may resolve. Each is `{code,tool,provider,cause}`,
recorded only for a query that asked about this tool; `provider` is qualified and
`cause` is the decoded error code, keeping a missed deadline apart from a backend
that could not answer. Safety, identity and cancellation
failures are not converted to missing tools. A valid explicit pin does not need
lower-layer provider answers at all.

A consumer may supply `fixed:{home}` or `fixed:{executable}` for one operation.
Each object has exactly one field, an absolute native path bounded to 4,096 UTF-8
bytes, without traversal or control characters. It contains no version, environment,
provider or execution grant. This explicit choice precedes directory pins and fails
terminally if invalid; lower scans and providers cannot replace it. Installation
choices use the definition's layouts and exports. An executable choice preserves
its lexical launcher path, has no inferred home, and omits home exports and PATH
entries. It requires a fresh successful version probe even without a minimum.
A definition whose launch requires `${home}` cannot use that choice. A lexical or
canonical executable inside the workspace requires the current explicit action
before it becomes a probe target. Directory pins and packages stay unchanged.

Four layers apply: fixed nearest pin; nearest project source (wrapper > environment
> declaration, native reader before compatible reader of the same source);
application global default > unambiguous/chosen provider global > login shell;
highest compatible installed release. Nearest project requirements mask parent
requirements. Invalid fixed values are terminal, even if a definition omits a pin
candidate. Uninstalled requirements retain reasons while resolution falls back.
Conflicts require explicit choices, never plugin-ID or home-path precedence.
Manual pin-only installations are not automatic candidates.

Outcome is `resolved` with `{home,executable,version,provider,layer,projectCode,
environment,pathPrepend}`, `skip` with a reason, or `terminalFailure` with a reason.
Output also carries operation/tool/directory, `trace`, `unmet` and `conflicts`.
Wrapper homes may be `null`; home exports/PATH are then omitted. Project code
requires an explicit consumer authorization snapshot and is never passively
probed. This foundation rejects project programs or environment homes whose
canonical identity differs from their declared lexical identity;
complete native link-chain validation, including common venv interpreter links,
is deferred rather than silently treated as safe. Each candidate builds a fresh
environment, so rejected exports cannot leak into its successor.

`checkVersion` returns `{satisfied,version}` from the definition's first regex
capture. Numeric dotted components (at most eight unsigned 32-bit parts, 64 bytes)
compare with trailing zeros ignored; aliases and tool-specific version syntax are
not interpreted. No match gives `version:null,satisfied:false`. `discoveryPlan`
returns `{tools,limits}`. Each tool carries platform-filtered `scans`, the sorted
qualified `providers` that declare it, and the definition's `homeLayouts`,
`executableLayouts`, `version` probe, `pathPrepend` templates and `environment`
login-shell home variables (`{variable,path}` from its platform-applicable
`environment` candidates). It neither scans, queries nor executes them; limits
are 256 roots, 4096 entries and 64 ancestors for the host adapter.

## Settings candidates

`candidates` reports what a settings page shows for one tool's global and
automatic layers without resolving a directory. It requires `{registry,tool,
platform,workspaceRoot,filesystem}` and accepts `workspaceRoots`,
`filesystemCaseSensitive`, `minimumVersion`, `probes`, `systemInstallations`,
`providerInstallations`, `environment`, `fixed` and `projectCodeAllowed`, with the same meaning and checks as in
`resolve`. `providerInstallations` (at most 512) are `{tool,home,provider}` rows a
host copies from `decodeReply` snapshots; `provider` must name a registry provider
`pluginID:providerID` declaring the tool, and the row keeps that attribution when
a scan reports the same canonical home. The output is
`{tool,shell,installations,skipped,selected,conflicts}`:
A checked `fixed` choice without a version contributes a `probeFailed` skipped row
with its executable for the native probe. An unauthorized workspace program never
contributes such a target. This candidate report itself grants no authority.


- `shell` lists each declared home variable present in `environment` as
  `{candidateID,variable,home,executable?,version?|reason?}`, checked through
  the candidate's own `path` layout.
- `installations` are eligible host-scanned homes `{home,executable,version,
  provider}`, highest version first, with the canonical home Core checked.
- `skipped` lists homes that failed a check as `{home,provider,reason,
  executable?}`; reasons are stable codes such as `unsafePath`, `probeFailed`
  and `versionUnsatisfied`.
- `selected` is the automatic-layer home, or `null`; equal highest versions
  in different homes leave it `null` and add an `automatic` entry to `conflicts`.

A first call without `probes` returns every checked executable as `probeFailed`.
The host runs only those executables with the definition's probe arguments,
then calls again with their `{executable,output,exitCode}`. Homes inside a
workspace root are refused before any probe, so a project program is never run
to read its version. The macOS host bounds probes by count, concurrency and
total time, and reports skipped work as diagnostics rather than a missing tool.

Production-shape examples are [tool-definition.plugin.json](../fixtures/toolchains/tool-definition.plugin.json)
and [toolchain-provider.plugin.json](../fixtures/toolchains/toolchain-provider.plugin.json).
Core acceptance vectors are in
[toolchain_definitions.rs](https://github.com/1lck/Lithe-IDEA/blob/preview/rust/lithe-core/src/tests/toolchain_definitions.rs),
with sibling pins/query/resolution suites. The pin document, query exchange and
one error reply per stable code that those suites share are inline in
[toolchain_vectors.rs](https://github.com/1lck/Lithe-IDEA/blob/preview/rust/lithe-core/src/tests/toolchain_vectors.rs).
Passing them is not native product verification. Contract changes must be mirrored after merge with
`node scripts/contract.mjs sync --revision <merged-preview-commit>` in
[lithe-plugin-docs](https://github.com/Lithe-IDEA/lithe-plugin-docs).
