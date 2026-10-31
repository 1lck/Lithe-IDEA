# Plugin-owned toolchains: Core foundation

**Status: shared Core implemented; neither native host is connected.** This
slice validates data and resolves captured facts. It does not launch providers,
probe programs, parse manager files, watch paths, write pins, or download tools.
The [broader proposal](proposals/toolchains/README.md) still describes unsupported
consumer migration, native lifecycle, UI, persistence and manager-plugin work.
The active shape is [plugin-manifest.schema.json](plugin-manifest.schema.json),
not the proposal envelopes. No native product support is implied by Core support.

## Manifest admission and registry

`toolDefinitions[]` needs `requires.toolDefinitions: 1` and
`requires.executableResolution: 2`. `toolchainProviders[]` needs
`requires.toolchainProviders: 1`, `backend: 2`, `serverProcess: 1`, and permissions
`backend.launch` / `toolchains.provide`. Capability lists are exact: missing or
unused capabilities reject the manifest. A definition/provider alone is a valid
contribution. Old executable candidate sets retain their strict source types.

Definitions own IDs, labels/icons, `executableLayouts`, ordered `executables`,
`version`, `homeLayouts`, `discovery`, `homeVariable`, `commands`, `wrappers`,
`exports`, `pathPrepend` and argv `launch`. Counts, relative paths, bounded globs,
platforms, templates and version expressions are validated recursively; unknown
fields fail closed. Candidate graph ordering reuses the existing shared graph
validator and cannot cross layer barriers. This slice does not support a
definition candidate of `kind: runtime`, or `toolchainConsumers`.

Provider entries contain `{id, displayName, tools, watchFiles}`; each watch entry
is `{pattern, reader: "native" | "compatible"}`. Providers share the plugin's
backend; admission permits a host-query trigger without a page or startup event.
This is not implemented native activation. Bootstrap must be `packaged`, or
`runtime` with `packagedRuntime`, without discovered runtime dependencies. Existing
runtime launch tool restrictions remain; generic consumer launches are not added.

`toolchains.provide` may influence which program a defined tool launches. It does
not grant arbitrary command replacement, installation, network or workspace-code
execution. Short definition IDs require independently verified official origin;
community definitions use `<own-plugin-id>:<local-id>`. Community providers may
answer short IDs. No host-owned tool table, name alias or manager parser is added.

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
| `toolchains.resolvePins` | `{document,directory,tool}` | `resolution` |
| `toolchains.resolve` | Captured resolver input described below | `resolution` |
| `toolchains.checkVersion` | `{registry,tool,output,minimumVersion?}` | `version` |
| `toolchains.discoveryPlan` | `{registry,platform}` | `plan` |

Every `registry` input is the raw `{plugins:[...]}` request, not a previously
normalized result. Core revalidates complete production manifests and the
host-supplied `verifiedOfficial` boolean; a plugin cannot assert that evidence
inside its own manifest. Output is `{definitions:[{pluginID,definition}],
providers:[{pluginID,provider}]}` in stable order. Duplicate plugin/tool ownership
rejects the batch without replacing earlier owners. Limits are 128 plugins,
512 aggregate definitions and 256 aggregate providers.

## Provider reply validation

`decodeReply` takes `{registry,pluginID,request,response,currentGeneration,
filesystem,platform,filesystemCaseSensitive?,workspaceRoots?}`. `pluginID` binds
the host-owned session, not a provider claim. `platform` is `macos`, `windows` or
`linux`; native filesystem case policy is explicit where platform defaults differ.

`request` is `{jsonrpc:"2.0",id,method:"toolchains/query",params:{operationID,
generation,providerID,authority:{kind:"local"},context,workspace,tools}}`.
`context` is `{contextID,generation}` or `null`; workspace queries require it.
`workspace` is `{rootID,root,directory}` or `null` for global-only queries.
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
Inactive/unknown tools lose installation authority; bounded requirement facts
remain diagnostic only. Lists normalize deterministically; sort order never
chooses between conflicting requirements. A reply is bounded to 1 MiB, 512
installations, 256 statements and 256 watch paths; mismatched IDs/generations,
remote authority, unsafe paths and malformed error mappings reject it.

The snapshot contains `{installations,statements,watch,diagnostics}`; normalized
entries carry qualified `<pluginID>:<providerID>` provenance and project source
directory. JSON-RPC errors are checked against the distinct semantic/numeric map
in the [protocol proposal](proposals/toolchains/protocol.md#stable-failure-mapping).
Cancellation, deadlines, cache invalidation and whole-generation requery remain
native-client implementation work, not behavior performed by this decoder.

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
`projectCodeAllowed` and `providerChoices`. `local` defaults to an empty v1
document. Probes are host observations `{executable,output,exitCode}`; system
installations are `{tool,home}`. Shell environment home variables and
`commandHomes` come from the native login-shell adapter, not command-name guessing.

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
diagnostics while lower sources may resolve. Safety, identity and cancellation
failures are not converted to missing tools. A valid explicit pin does not need
lower-layer provider answers at all.

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
returns `{tools,limits}` with platform-filtered scans and definition-owned layouts
and probes. It neither scans nor executes them; limits are 256 roots, 4096 entries
and 64 ancestors for the eventual host adapter.

Production-shape examples are [tool-definition.plugin.json](fixtures/tool-definition.plugin.json)
and [toolchain-provider.plugin.json](fixtures/toolchain-provider.plugin.json).
Core acceptance vectors are in
[toolchain_definitions.rs](https://github.com/1lck/Lithe-IDEA/blob/preview/rust/lithe-core/src/tests/toolchain_definitions.rs),
with sibling pins/query/resolution suites. Passing them is not native product
verification. Contract changes must be mirrored after merge with
`node scripts/contract.mjs sync --revision <merged-preview-commit>` in
[lithe-plugin-docs](https://github.com/Lithe-IDEA/lithe-plugin-docs).
