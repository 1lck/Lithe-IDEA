# Rust Core API

## Normalized shortcut import validation

`keymap.decodeImport` accepts `{commandIDs: string[], reply: {bindings:
[{commandID: string, keys: [{key: string, modifiers: string[]}]}]}}` and
returns `{bindings: [...]}`. The caller supplies its current action catalog;
unknown or duplicate actions, duplicate keys or modifiers, unknown fields,
unsupported keys and unmodified printable keys fail with `invalid_request` and
no partial result. Modifiers are `control`, `alt`, `shift` and `meta`, in
that canonical order. Keys are lowercase single ASCII graphic characters,
`f1` through `f24`, or `up`, `down`, `left`, `right`, `return`, `tab`,
`space`, `backspace`, `delete`, `escape`, `pageup`, `pagedown`, `home`, `end`
and `insert`. This is the portable vocabulary; each host must still reject keys
its native input and shortcut model cannot represent. A printable character or `space` requires `control`, `alt` or
`meta`. Empty key lists represent an explicit unbinding. Actions are returned
in ID order; each action's key order is retained because the first is its
primary binding. A shortcut used by different actions is retained for the
host's final conflict check. Requests are limited to 1 MiB, 4096 catalog IDs,
4096 actions, eight keys per action and 128 UTF-8 bytes per ID. The shared
[fixtures](../fixtures/keymap/import-provider-v1.json) cover this contract.

This validates normalized results only. It neither parses an IDE's private
format nor discovers or starts a provider; an unimplemented provider API must
not be inferred from the existence of this Core command. Conditional rules and
multi-stroke keys cannot be represented and must not be silently made global.

`debug.startOrContinue` accepts `{active, paused, requestPending}` booleans and returns
`{action: "start" | "continue" | "none"}`. An in-flight request or an active,
non-paused session returns `none`; an inactive session starts, and an active
paused session continues. The platform executes the result against its current
session and must still guard against state changes.

`keymap.planImportBindings` accepts `{current: [{commandID, customized, keys}],
incoming: {bindings}}` and returns `{displaced, conflicts}`. Current entries
are the host's complete action catalog and effective key-press bindings;
non-key-press bindings remain in the host and are never displaced. Incoming
bindings use the same validation as `keymap.decodeImport`. Each displacement
names an unchanged default action and only the keys to remove. A customized
owner or two imported actions claiming the same key produces a conflict naming
`commandID`, `ownerID` and `key`; a conflict clears all displacements so a
caller cannot apply a partial plan. Actions included in the import replace
their old bindings, permitting swaps. Results are deterministic. Requests are
bounded to 1 MiB, 4096 actions, eight keys per action, 4096 conflicts and
131072 ownership comparisons. Hosts must recheck the source and settings
revisions at apply time. See [plan fixtures](../fixtures/keymap/import-plan-v1.json).

`keymap.planImportSources` accepts `{manifest, providerID}` and returns
`{inputs, recognition, limits}` for exactly that declared provider after validating the entire
manifest; an unknown provider or invalid manifest returns `invalid_request`.
The payload is bounded to 1 MiB. It performs no filesystem I/O and does not
establish package trust: callers must supply the enabled, previously accepted
plugin manifest. Selectors and native read limits are defined by the
[plugin contract](plugins/v1/README.md#shortcut-import-providers-core-foundation).
The returned limits bound selectors, recognition probes, files, bytes per file and per snapshot,
bytes per chunk, directory entries scanned and matching entries per directory;
native adapters apply these values to their I/O.
See [source plan fixtures](../fixtures/keymap/source-plans-v1.json).

For the provider foundation, `lsp.startServer` optionally accepts
`keymapImportProviders`, an array of at most eight declared plugin-local IDs.
Only a plugin-owned session with valid IDs offers
`experimental.litheKeymapImport: {versions: [1], providers}`. A backend may
select a non-empty, duplicate-free subset using `{version: 1, providers}`;
Core emits `keymapImportProviders` with `result: {providers}` only for a valid
selection. Invalid IDs, unknown selections and unsupported versions enable no
providers. This negotiation alone does not implement the product workflow. See the
[negotiation fixtures](../fixtures/keymap/provider-negotiation-v1.json).

`lsp.keymapImportRequest` accepts `{sessionId, operationId?, providerID,
snapshotID, timeoutMilliseconds?}` and returns `{operationId}`. The requested
provider must have been selected in that exact session. `snapshotID` is an
opaque 1–128 byte ASCII alphanumeric, hyphen or underscore token, never a
filesystem path; the native snapshot service must separately enforce ownership,
expiry and read permissions before supplying any source data. The method sends
`lithe/keymap/import` with only `{providerID, snapshotID}` and caps the request
deadline at 60 seconds. Completion returns the untrusted JSON-RPC reply as
`result.value: {id, response}`; callers must validate successful reply data via
`keymap.decodeImport` before applying it. Replies larger than 1 MiB fail with
`plugin.keymapImport.replyTooLarge`; no partial result is returned. Normal
session cancellation and teardown apply. Backend attempts to call
`lithe/keymap/*` are refused as recursive domain calls. The macOS host has a
scoped snapshot service, but native provider discovery and a product consumer
are not implemented yet.

## Shortcut context compilation

`keymap.parseContext` accepts `{expression: string}` and returns
`{parsed: {keys: string[], values: boolean[]} | null, error: {code: string, byteOffset: number} | null}`.
Exactly one of `parsed` and `error` is non-null. Diagnostics use zero-based UTF-8
byte offsets in the original expression, not editor UTF-16 positions.

The grammar supports boolean context identifiers (`[A-Za-z0-9_.]+`, with
`true`/`false` reserved), quoted strings, parentheses, unary `!`, strict typed
`==`/`!=`, `&&`, and `||`, in that descending precedence order (unary precedes
equality, which precedes AND and OR). Comparisons are not chainable; use explicit
boolean operators. Strings support escaped quotes, backslash, `n`, `r`, and `t`.
Missing context keys are false; non-empty strings are truthy. Whitespace-only
source is an unconditional match. This is Lithe's boolean context grammar,
not the full VS Code context-key language.

Source is limited to 4096 UTF-8 bytes, 128 tokens, 32 nested parentheses/unary
operations, and 12 distinct context identifiers. Full consumption is required.
Syntax diagnostic codes are `invalid_character`, `invalid_escape`,
`unclosed_string`, `expected_operand`, `expected_closing_paren`,
`trailing_token`, `too_long`, and `too_complex`. Syntax diagnostics are
successful protocol responses with no partial plan; malformed request shapes
use the existing `invalid_request` envelope.

Core computes the entire truth table. `keys` are sorted by ASCII order and
`values` has exactly `2 ** keys.length` entries; key zero supplies the least
significant bit of the index. A native boolean snapshot can synchronously
project its key values to that index and look up the Core-produced result.
Hosts must not tokenize source, interpret an AST, or recompute expression
semantics. This preserves synchronous keyboard default prevention without
an IPC round trip per key event. The maximum table has 4096 outcomes.

`keymap.evaluateContext` accepts `{parsed, context: {[key: string]: boolean}}`
and returns `{matches: boolean}`. It evaluates the same precompiled table,
rejecting oversized, noncanonical, duplicate-key or incorrectly sized plans
with `invalid_request`; it never reparses source. Parsed tables are portable
data, not authorization tokens. Neither command retains global state.

Windows validates imports before changing the preset/store and validates
additions/updates before persistence. Hydrated/default/extension bindings stay
inactive until their Core table is ready; invalid conditions stay inactive.
Compilation is refreshed on binding/preset changes, and the keyboard owner
releases preparations on teardown. Expression caching is limited to 256 entries
and native compilation to 16 outstanding requests. Cache limits, teardown and
stale-store guards belong to the window adapter. macOS has no free-form
`when` parser and is unchanged. See `shared/fixtures/keymap/context-v1.json`.

## Shortcut binding conflicts

`keymap.analyzeConflicts` accepts `{platform: "macos" | "windows", layers: [{entries: [{command, key, when?, enabled?}], disabledCommands?: string[]}]}`
with layers ordered from the lowest priority (defaults) to the highest (user
overrides) and returns `{conflicts: [{key, when, commands}], invalid: [{command, key, code}]}`.
Within a layer, a command's entries replace every lower layer's entries for that
command; `disabledCommands` unbind a command from lower layers first. An entry with
`enabled: false` is in force but unbound. Conflicts are computed over the final
effective bindings only: two different commands with the same canonical key sequence
and whitespace-normalised `when` clause. Binding text is case-insensitive, modifier order
and aliases do not matter (`cmd`/`command`/`mod` follow `platform`: Command on macOS, Control on
Windows; `meta`/`super`/`win` are always Meta; `option`/`opt` are Alt; `return` is `enter`; `esc` is
`escape`), chords are whitespace-separated steps, a trailing `+` is the plus key, and `doubleshift`
is the double-tap Shift gesture. Parse failures are listed in `invalid` with `empty`, `empty_key`,
`multiple_keys`, `too_long` or `too_many_steps` and never take part in conflicts; more than
20000 entries is `invalid_request`. Hosts reject saving a binding when a conflict contains the edited
command. Native key-event conversion and the synchronous matching path stay in the host.
See `shared/fixtures/keymap/binding-conflicts-v1.json`.

`keymap.modifierGestureStep` accepts `{state?, event, timestamp}` and returns `{state, triggered}`. It is the
double-Shift gesture as a pure transition: `event` is `{kind: "keyDown"}`, `{kind: "reset"}` or
`{kind: "flags", shift, otherModifiers}`; `timestamp` is seconds on a clock the host keeps; `state` is opaque
host-held memory (omit it for the idle state) that the host sends back with the next event. The rule lives in the
pure crate `rust/lithe-core-rules` (no I/O, no clock) so it can run on a synchronous key path: macOS calls it
through the C ABI, and the Windows frontend runs the same source compiled to wasm (`lithe_rules_alloc`,
`lithe_rules_dealloc`, `lithe_rules_execute` over JSON envelopes), loaded asynchronously at startup. A malformed
payload is `invalid_request`. Hosts only convert native events to this input and act on `triggered`; both are
tested step by step against `shared/fixtures/keymap/modifier-gesture-v1.json`.

`editor.workbenchState.reduce` accepts `{state?, action}` and returns `{state, removedGroupIds}`. `state` is
`{groups, focusedGroup?}`; a group is `{id, members, selected?, mru?, pinned?, preview?}` (ordered members, the shown
member, most-recent-first order, pinned members, one transient preview), which is the union of what macOS (a flat
tab list with placements and per-group selection) and Windows (pane groups with MRU, pins and preview) track.
`action` is tagged by `kind`: `normalize {emptyGroups?, unplaced?}`, `open {group, member, activate?}`,
`close {group, member, emptyGroups?, selectionFallback?}`, `activate {group, member?}`,
`move {member, from, to, before?, after?, activate?, emptyGroups?, selectionFallback?}` (with `from == to` it only
repositions), `reorder {group, fromIndex, toIndex}`, `setPinned {group, member, pinned}`,
`setPinnedEverywhere {member, pinned}`, `setPreview {group, member?}`, `clearPreviewEverywhere {member}` and
`mergeGroup {from, into, activateSelected?}`. Every group an action touches leaves with unique members, a selection
that is a member (the first one when it was missing or stale, `null` when empty), an MRU order that starts at the
selection and lists every member once, and pins and preview that only name members; groups an action does not touch are
returned as sent, so a host may send only the groups an action involves. `emptyGroups` is `keep` (default), `remove`
(may leave no group) or `removeKeepingFirst`; it applies to the group a `close` or `move` emptied and to every group for
`normalize`. `selectionFallback` is `adjacent` (default: the member that slid into the vacated position) or `first`.
`normalize.unplaced` members no group lists join the focused group (the first group when `focusedGroup` is missing or
stale), and `focusedGroup` moves to the first remaining group when its group was removed. Actions that name an unknown
group or an unknown move destination change nothing. `removedGroupIds` lists removed groups in their previous order so
hosts prune their own layout tree; split directions, ratios, pixels and dragging never reach Core. A malformed payload is
`invalid_request`. It lives in `rust/lithe-core-rules` and is called synchronously: macOS through the C ABI, Windows
through the wasm build inside zustand `set()`, one call per user action. Both hosts run every case of
`shared/fixtures/editor/workbench-state-v1.json` through it.

`workspace.classifyVisibility` accepts `{hiddenDirectoryNames?, hiddenFilePatterns?, entries: [{path, isDirectory?}]}`
and returns `{hidden: boolean[], watchedDespiteHiding: boolean[]}` with one answer per entry, in request order. `path`
is workspace-relative with `/` separators; `isDirectory` is `true` for a folder, `false` for a file and omitted when the
host does not know (every component may then be a folder). The two lists are the user's own entries: Core adds the
built-in folders and patterns, and a `!entry` turns a built-in off. Matching ignores case. A folder name hides the folder,
everything below it and a file with that exact name (a linked worktree's `.git` file). `hidden` means the tree, search and
Local History leave the path out; `watchedDespiteHiding` marks the hidden project configuration folder (`.lithe`) whose file
events must still be delivered, except the built-in noise below it such as `.lithe/run/local.json`. Hosts send all children
of a directory in one call. `workspace.visibilityDefaults` takes `{}` and returns the built-in lists
(`hiddenDirectoryNames`, `hiddenFilePatterns`, `builtInPatterns`, `configurationDirectory`, `configurationPattern`) so hosts
display them without keeping a copy. Both live in `rust/lithe-core-rules` like `keymap.modifierGestureStep`, run in wasm on
Windows, and are tested against `shared/fixtures/workspace/visibility-v1.json`.

## Terminal link targets

`terminal.parseLinkTarget` accepts `{texts: string[], baseDirectory?, homeDirectory?, providerSchemes?: string[]}`
and returns `{targets: (Target | null)[]}` with one entry per text. A target is
`{kind: "file", path, line, column, explicit}` or `{kind: "external", url}`. Core splits a trailing
`:line[:column]` (positive integers), decodes `file://` URIs (percent escapes, `localhost`, Windows drive
and UNC forms), expands `~` from `homeDirectory`, and resolves relative paths against `baseDirectory`
lexically (`.` and `..`), keeping Windows drive/UNC separators. `providerSchemes` name host file
providers (for example `remote`, `wsl`): such URIs are returned unchanged, and under a provider
`baseDirectory` relative and rooted POSIX paths stay inside that provider. Other `scheme://` texts and
`mailto:` are `external`; a bare `name:12` is a file, not a scheme. `explicit` is true when the text
itself says it is a path (separator, `~`, `file://`, provider URI or line suffix). Core never inspects
file extensions or touches the file system: the host checks existence, owns hit regions, and opens the
target. At most 256 texts of 4096 bytes. See `shared/fixtures/terminal/link-target-v1.json`.

The Rust core is the shared application runtime for macOS SwiftUI and Windows
React/Tauri. macOS calls the stable C ABI while the Tauri host links the Rust
crate directly. The C ABI remains:

```c
const char *lithe_core_version(void);
char *lithe_core_execute_json(const char *request);
char *lithe_core_execute_json_with_events(const char *request, void (*callback)(const char *, void *), void *context);
int32_t lithe_core_git_askpass(const char *prompt);
char *lithe_core_lsp_provider_catalog_json(const char *workspace_root);
int32_t lithe_core_cancel(const char *operation_id);
void lithe_core_free_string(char *value);
void lithe_core_install_log_waker(void (*callback)(void *), void *context);
int32_t lithe_core_remove_log_waker(void *context);
void *lithe_agent_open_json(const char *configuration, void (*callback)(const char *, void *), void *context);
int32_t lithe_agent_send_json(void *handle, const char *command);
void lithe_agent_close(void *handle);
```

The macOS package uses the small C bridge in `macos/Sources/LitheRustCore/`. The
canonical C declarations are in `rust/lithe-core/include/lithe_core.h`.
Native clients can link the same `staticlib` or `cdylib`; Rust hosts call
`lithe_core::execute_json` and `lithe_core::cancel_operation` directly. Hosts
call `lithe_core::execution::plan_launch_command` (or the
`execution.planLaunchCommand` JSON command) before spawning a Java process. It
estimates the Windows command-line limit and moves oversized classpath/module-path
options into argument-file text, so macOS can apply the same automatic behavior
without a Windows-only setting. The planner requires a Java executable and a
known JDK feature version of at least 9, obtained through
`java_feature_version_from_release`; other launches remain unchanged. It stops
at the application target (class, JAR, or module), preserving all program arguments.
JSON hosts may instead supply `javaReleaseContents`, an array of host-read
release files ordered nearest first. Core reads the first `JAVA_VERSION` entry;
an unrecognized version remains unknown rather than falling back to an ancestor.
An explicit `javaFeatureVersion` takes precedence over the supplied contents.
Core owns the Unicode argument-file text and quoting. The Windows host encodes
that text losslessly using the launcher's actual system code page, independently
of the JDK feature version: JEP 400 does not make native launcher arguments UTF-8.
An unrepresentable path is reported as an actionable failure, never substituted.
The host also escapes backslash bytes introduced by multibyte encoding inside
quoted values, since the native argument-file parser processes bytes.
Every execution owns an exclusively created temporary file; partial writes and
spawn failures clean it up, while successful launches retain it until that exact
process exits. A replacement execution never shares its predecessor's file.
For a known JDK older than 9, Rust hosts call
`lithe_core::execution::plan_classpath_jar_launch` instead. Under the same
command-line budget it replaces the effective `-cp`/`-classpath` value with a
host-owned JAR path and returns the ASCII `META-INF/MANIFEST.MF` text: the
`Class-Path` header lists every entry, in order, as an absolute percent-encoded
UTF-8 `file:` URL (directories end in `/`), wrapped at 72 bytes. The host
answers whether each entry is a directory and writes the manifest-only JAR with
the same exclusive temporary-file lifecycle. Wildcard entries, drive-relative
Windows entries, `-jar` launches, and unknown JDK versions stay direct. This is
a Rust API only; there is no JSON command yet because the macOS process
argument limit (`ARG_MAX`) is far above the Windows cap, so a direct JDK 8
launch already succeeds there.
Strings returned by the core are UTF-8 JSON allocated by Rust. The caller must
release response strings with `lithe_core_free_string`.

Rust native adapters may call `execution::java_version_from_release` to read the
full JDK version from bounded host-read `release` metadata, then reuse Core's
runtime candidate ordering. Passive Build discovery never falls back to running
Java when that metadata is missing or invalid; explicit tool execution owns probes.
### Localized action search

`search.actions` accepts `{query, candidates: [{texts: [string]}]}` and returns
`{indices: [integer]}`. Native hosts supply the original title, subtitle and group
alongside their current interface translations. Plugin-owned titles stay verbatim.
Core performs case-insensitive, NFC-normalized Unicode subsequence matching after removing query
whitespace, preserving input order and returning zero-based candidate offsets.
It retains no catalog, performs no workspace I/O, and never executes actions.
The request is limited to 4096 candidates, 16 fields per candidate, 2 MiB of text
and a 4096-byte query; excess input returns `invalid_request`.
[Action search fixtures](../fixtures/search/actions-v1.json) cover both languages,
English aliases, ordered results, Unicode and literal plugin titles.

### Remote workspace path identity

Workspace-aware commands accept an optional top-level `remoteWorkspace` with
`sessionId`, `localRoot` (the native placeholder), and `remoteRoot` (the host
folder). Roots must be absolute without parent components; `localRoot` must
have a final component. Without this context commands retain local behavior.
Remote failures never trigger a local filesystem or process fallback.

Paths below `remoteRoot` project below `localRoot`. Absolute host paths outside
that folder, including containing Git repositories and canonical symlink
targets, project below a virtual sibling named
`<localRoot final component>.lithe-remote-host`, followed by the host path with
its leading `/` removed. For example, opening `/srv/repo/src` as `/native/src`
returns `/native/src.lithe-remote-host/srv/repo` for the containing repository.
This namespace is not materialized or persisted as user data. The native
registry recognizes both namespaces as the **same binding** and attaches its
original context to subsequent requests (status, stage, watch, etc.). Core
reverses both projections before accessing the host. Never infer a connection
from a raw host absolute path or use `..` to escape the placeholder. Multiple
hosts with the same host path retain distinct native identities; mixed local
and remote roots or different bindings in one request remain unsupported.
Only schema-owned path/URI fields are mapped; opaque argv and user text stay
unchanged. This is a client/Core projection, not a remote-server wire change.

The ACP Agent calls use an opaque handle for one agent process and connection
per workspace and agent; one connection carries many conversation sessions.
`lithe_agent_open_json` accepts `{ "agentId"?: string, "command"?: string,
"args": string[], "cwd": absolutePath, "dataDirectory"?: absolutePath,
"authentication"?: "apiKey" | "codexSubscription",
"provider"?: { "protocol": "responses" | "chatCompletions" | "anthropicMessages",
"baseUrl": string, "apiKey": string, "name"?: string, "model"?: string,
"allowInsecureHttp"?: bool } }`. With `agentId`, the host starts the adapter
installed by `agent.install` under `dataDirectory`. Omitted `authentication`
defaults to `apiKey`, which requires `provider`. Credentials travel over ACP
stdio, never in Lithe's adapter launch arguments, environment, or files.
This guarantee covers Lithe launching the ACP adapter, not the entire child
process tree. The pinned Claude SDK serializes object-valued `options.settings`
into the Claude Code CLI's `--settings` argument. Consequently,
`settings.env.ANTHROPIC_API_KEY` is visible in that child process's arguments;
SDK debug output may also record those arguments. This route does not eliminate
that upstream exposure. Moving the key solely to `options.env` requires separate
validation of precedence against user/project settings to preserve the selected
provider's credentials.
Responses providers use `gateway` authentication with `Authorization: Bearer
<key>`. Claude uses the pinned adapter's public `_meta.claudeCode.options` on
both `session/new` and `session/load`: its native API-key route is supplied in
SDK `env` and programmatic `settings.env`, with `apiKeyHelper` and competing
Bearer/OAuth/custom-header/cloud routes cleared. This avoids the adapter's
gateway placeholder Bearer token overriding a valid `x-api-key`; it does not
patch the adapter or change native CLI configuration files. Missing Claude
credentials fail before session creation instead of falling back to an account.
The provider model is a new-session default: Claude supplies it only as
`_meta.claudeCode.options.model` on `session/new`, never as a process-wide
`ANTHROPIC_MODEL` pin or an `options.model` override on `session/load`. On a
Claude API-key restore, the Host re-asserts the returned model selector
(`category: model`) through `session/set_config_option`, even if its value is
unchanged or outside the picker. Only a matching acknowledgement publishes
`sessionLoaded`; its complete configuration replaces the load response.
Rejection, mismatched confirmation or timeout reports a load failure. Both
requests share the existing 60-second load deadline. Adapters without model
selectors and other Agent routes retain standard ACP loading; no additional
model cache, transcript access or global CLI mutation is introduced.

Claude API-key sessions also set `CLAUDE_CODE_MAX_RETRIES=0`,
`CLAUDE_CODE_RETRY_WATCHDOG=0`, and
`CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1` in both option tiers. The native
budget cannot distinguish permanent errors and may honor minutes of Retry-After.
The Host owns a short interactive recovery budget instead: five total prompt
attempts, with 0.5/1/2/4-second delays. Only known temporary failures before any
reply, thought, plan, tool or permission progress can be replayed. Permanent
credentials/access/request/quota errors fail immediately. Native model resolution
can still probe a missing model twice; this is not another Host attempt.
Claude API-key connections negotiate AIR v1 `sessionFailure` alongside
`recommendedValue`. A terminal AIR failure in a successful `end_turn` response
is normalized to `requestFailed`; its category/actions determine retryability,
and title/details retain the actionable error. For generic service failures,
a fixed CLI `API Error:` HTTP banner can veto retries for permanent statuses;
text never enables a retry. Legacy categorical JSON-RPC `errorKind` remains
supported; unknown legacy errors are terminal. The failed idle SDK request is
interrupted before resubmission to avoid duplicated native HTTP requests.
Codex API-key sessions use native recovery with `request_max_retries=0` and
`stream_max_retries=4`, so HTTP and stream retries cannot multiply. The pinned
ACP adapter replaces the gateway provider table; a first-party stdio relay
applies those public App Server fields on `thread/start`, `thread/resume` and
`thread/fork`, and disables `features.unbounded_connection_retries`. Other
configuration, native history, tools and stream processing remain engine-owned.
The relay also retains native error information in a JSON `litheCodexFailure`
envelope inside the AIR failure title, because the adapter otherwise drops
`codexErrorInfo`, HTTP status and details from retry warnings. Only negotiated
failure metadata is decoded; assistant/model text never enters this policy.
Titles presented as errors are decoded to the original actionable message.
Known permanent native categories or HTTP 4xx (except 408/409/429) stop recovery
immediately, even when the service supplies a long `Retry-After`. Unknown native
errors retain their native retry decision. The Host recovery window applies
only before any work; subsequent native recovery is engine-owned.
Native HTTP 429 may terminate without stream recovery. Before any reply,
thought, plan, tool or permission progress, only this typed 429 gap may replay
the settled prompt with short Host delays. It shares the same five-attempt
counter with native recovery, rather than adding another budget; recognized
quota/context/budget exhaustion is permanent. No other Codex terminal failure
automatically resubmits a prompt. Subscription sessions preserve native login,
refresh and retry policy; custom ACP commands receive no Codex configuration.

Each Codex launch requiring retry compatibility, history recovery or guarded
subscription observation owns `<system-temp>/lithe-codex-retry-<UUID>/` until its
process tree stops. Its script comes from embedded first-party source and holds
no credential. Preparation/spawn failure, cancellation and completion remove
the directory. The host does not write installed packages, bundles, CLI settings
or user configuration; this runtime helper is excluded from worktree reuse.
The route fixture is `shared/fixtures/agent/acp-events-v1.json`'s
`upstream.claudeSessionRouting`. The
user's own CLI is passed as `CODEX_PATH` or `CLAUDE_CODE_EXECUTABLE`, and a
non-empty Codex `model` as `CODEX_CONFIG`; Claude uses the per-new-session option above. Without `agentId`, `command` runs
a user-provided agent that must support gateway sign-in with a Responses
provider. Agents start with the executable's directory and the login shell's
`PATH` first. API-key mode never falls back to account login. Invalid settings
and launch failures are reported as a `stopped` event with a message.

`codexSubscription` is accepted only for `agentId: "codex-acp"` with no
`provider`. It reuses the locally installed Codex CLI and its own account storage
(including `CODEX_HOME`). The child uses the official `openai` model provider;
inherited API-key, endpoint, token and gateway overrides are removed for this
child only. Session configuration also clears `openai_base_url` and selects the
official `chatgpt_base_url`, preventing saved custom routes from overriding the
subscription selection. The quota probe always keeps the official account route; optional inference observation never changes login or quota routing. No Lithe HTTP provider, stored API key or configured provider model
is consulted. Codex owns login, token refresh and session model options.
The pinned ACP adapter's `_auth/status_update` notification confirms the account.
An existing account proceeds to `account` then `ready`; otherwise
`authenticationRequired` waits for the user's `authenticate` command before
`authenticating` opens the upstream ChatGPT browser login. Login is cancellable
by closing the handle, with a five-minute deadline. Account loss or email change
disconnects the connection rather than silently changing its billing identity.
`account` exposes only nullable `email` and `plan`, never credentials.

`refreshQuota` is ignored outside subscription mode, coalesced while in flight,
and throttled to one read per connection per 60 seconds. The host uses a bounded
20-second, short-lived official `codex app-server` process because codex-acp
1.13.1 does not expose structured rate limits. It only initializes, checks
`account/read`, reads `account/rateLimits/read`, and checks the account again;
it never creates a thread or prompt. The process tree is owned by the connection
and terminated after the query or cancellation. The account email must match
the active ACP account; missing identity cannot prove a match. This is not a
workspace/account-ID verification guarantee: the upstream ACP identity provides
no stable account ID. Lithe reads no credential files for this path.

`quota.snapshot` has `fetchedAt` (Unix seconds) and deterministic `windows` with
`id`, `name`, `limitSeconds`, nullable `usedPercent` (0–100) and nullable
`resetsAt` (Unix seconds). Actual window durations are preserved; primary does
not imply five hours. Unknown usage remains null. `quotaFailed.code` is
`unavailable`, `timeout`, `unparsable`, `unauthorized`, or `accountChanged`.
Consumers retain the last snapshot as stale for transient errors, clear it on
identity failures/disconnect, and never reinterpret unknown as zero. The macOS
composer refreshes while visible and active, and requests a throttled refresh
after turns. Hover details include all windows and reset times; API-key
connections show no quota control.
macOS keeps a compact icon and text quota summary in the composer top strip,
preferring the actual five-hour window and falling back to the actual seven-day
window. Details appear only on hover and show
separate used percentages, gray-track progress bars and reset times. Known usage
is green through 60%, yellow above 60% through 90%, and red above 90%; unknown
or stale data remains gray. Window duration and missing values are never invented.

`lithe_agent_send_json` queues one command: `newSession`, `loadSession`,
`listSessions`, `setConfigOption`, `applyNextTurnConfiguration`, `prompt`, `steer`, `cancel`, `permission`, `authenticate`,
or `refreshQuota`. Results arrive as events:
`ready`, `sessionCreated`, `sessionLoaded`, `sessions`, `update`, `permission`,
`sessionConfigured`, `nextTurnConfigured`, `modelCall`, `steeringResult`, `turnRetrying`, `turnActivity`, `turnCancelling`, `turnFinished`, `requestFailed`, `stopped`,
`authenticationRequired`, `authenticating`, `account`, `quota`, and `quotaFailed`. Commands and events, including
their camel-case field names, are fixed by
`shared/fixtures/agent/acp-events-v1.json`; `token` values are echoed so a caller
can correlate concurrent requests. `stopReason` uses ACP wire names such as
`end_turn` and `cancelled`.

Codex `sessions` and `archivedSessions` use the installed official App Server's
`thread/list` across all providers, within the selected account's Codex home,
source-kind and workspace scope. The Host
normalizes its `recencyAt` (conversation activity) into the existing optional
ISO 8601 `updatedAt` history field, and sorts upstream pages by `recency_at`.
`useStateDbOnly: true` avoids rollout-file scans/read-repair for this read-only
listing. Merely loading a conversation or changing its metadata can advance
Codex's raw `updatedAt`; that field is never a fallback for activity. Missing or
invalid `recencyAt` yields `updatedAt: null`, so consumers omit the relative time
and time-sorted history rows place unknown activity after known timestamps,
breaking ties by session ID. The switcher's existing current-session pin is unchanged.
Listing failure retains consumers' existing rows through `requestFailed`; it
does not fabricate a local timestamp. Other Agents retain standard ACP listing.
`shared/fixtures/agent/history-activity-v1.json` covers initial state, metadata-only
viewing, and a new conversation turn. The history UI geometry is unchanged.

History summaries may additionally include `modelProvider`, the opaque provider
identity reported by upstream history. Missing, null or blank metadata is unknown;
it is never inferred from the current billing route, model name or local annotation.
Codex forwards `thread/list.modelProvider`; standard ACP Agents without equivalent
metadata omit it. Older consumers can ignore this additive field. Presentation
defaults to all providers and may explicitly filter an exact identity or unknown
metadata, composing with search, favorites, local removal and archived rows.
Provider choices come from active and archived snapshots, not the configured
provider catalog. Filtering is local and read-only: it never changes the current
route, resumes a thread, rewrites history or starts another list request.

Both native Codex App Server listing and standard ACP listing may emit additive `sessionsPage` events for nonterminal pages with matching rows. Each carries the original `listSessions` token and only that page’s summaries. Consumers merge these rows without pruning cached entries or completing the loading state. The existing terminal `sessions` event still carries the full snapshot; consumers that ignore `sessionsPage` remain compatible. A later `requestFailed` retains cached and already received rows. Ignore pages from superseded, completed, or disconnected requests. Empty filtered pages do not end a scan: follow the Agent’s cursor. Platform history surfaces may reuse successful connection-local snapshots (including empty results) for 30 seconds, with independent active/archive freshness; explicit refresh and post-unarchive reconciliation bypass freshness. Failed scans remain retryable and reconnection invalidates freshness. On macOS, a confirmed `turnFinished` invalidates active-list freshness, including for background sessions, without expiring the archive snapshot. A scan still in flight at that boundary may update displayed rows but cannot renew freshness when it completes; the next history open queries again after that scan finishes. Loading or viewing history alone does not invalidate freshness or synthesize activity timestamps. This adds no persisted history or runtime resource directory.

`prompt` retains `text` and optionally carries ordered `files` entries with `uri`
(a native `file://` URL) and `name` (the display filename). The host validates up to
32 references and sends upstream ACP `resource_link` blocks after the text block;
empty text is allowed when files are present. It never reads, copies, or embeds
file bytes. These native resource URLs identify user-selected context, not portable
workspace records; the agent owns reading, permissions, and history. Invalid
references produce `requestFailed` before reserving a turn. Older text-only callers
remain compatible by omitting `files`.

The Host appends one standard ACP text block containing the immutable connection
`cwd` as JSON `openedWorkspaceRoot`, with guidance that "current project" means
the editor's opened workspace unless the user specifies otherwise. A containing
repository and inherited `AGENTS.md`/`CLAUDE.md` retain their development-rule
role, without replacing the subject of project-purpose/structure questions.
The same builder handles `prompt` and `steer`, retry payloads, and prompts after
`session/load`; it never reads a README or guesses a Git root. User text stays
first and file links retain their order. Native slash commands retain their original text and ordered attachment links,
including leading whitespace and deferred steering commands; no workspace block
is appended, so adapter command parsing and `/usage` detection keep working.
No optional prompt capability, private system prompt, new command field, or
provider-specific path override is required.

Only the exact Host-added workspace text suffix is omitted from
`user_message_chunk` presentation, including adapters that join adjacent text
blocks in history. Generated `session_info_update.title` and session-list titles
also omit a recognized full or truncated, whitespace-normalized Host suffix.
If the remaining title is empty or whitespace-only, it is represented as `null`
in the Host event rather than an empty string, preserving downstream provisional
message, New Chat, untitled-history and export fallbacks.
Other user content, model output, tools and metadata pass through unchanged.
Upstream history remains untouched and may retain this
context as part of its original prompt; it contributes to upstream token usage.
Workspace selection remains platform-owned, and this context is guidance rather
than a filesystem sandbox. The `workspaceContext` fixture covers nested roots,
normal prompts, steering, restored prompts and clean user-message replay.

`ready.canSteer` is true only when the ACP initialize response's top-level
`_meta.steering.supported` is exactly true; absent capabilities remain false.
`steer` carries `token`, `sessionId`, `text` and optional `files`, with the same
validation as `prompt`. The Host uses the existing `_session/steering` extension,
not a concurrent `session/prompt`. One outstanding supplementary request per
session preserves ordering. Its `steeringResult` echoes the token and session;
`outcome` is `injected`, `promptRequired`, or `failed` (with `message`). These
delivery results never finish or reset the original logical turn. `injected`
means upstream accepted the input, not proof that a model has already consumed it.
Only `promptRequired` explicitly leaves the input unconsumed and permits the
client to submit it once through normal `prompt`, after completion and staged
configuration. Stop revokes this fallback even while configuration is pending
and no native turn is active; it leaves the configuration request intact and
does not send a native cancel for an unstarted continuation.
Unknown delivery after a thirty-second
request timeout closes the connection; it never blindly replays the message.

Supplementary input whose first text block starts with `/` (ignoring leading
whitespace) is left unconsumed by the Host, with `promptRequired`, instead of
being passed to the steering extension. This also applies when files accompany
the command. The client waits for the original turn and staged configuration,
then submits it once via normal `prompt`; the owned ACP response confirms
completion even when the command never starts a model turn. Command parsing
remains upstream-owned. Codex ACP 1.13.1 reports `startedNewTurn` for both real
continuations and completed command-only input, so that outcome alone cannot
establish a native lifecycle for a command.

The pinned Codex ACP may instead return `startedNewTurn` at the completion
boundary for ordinary supplementary messages. The Host reports it as accepted
and retains the same logical turn until Codex's explicit
`_meta.codex.threadStatus` transitions end the continuation.
The original idle and the continuation's idle are distinct; duplicate idle
updates do not complete another turn. Stop and its existing watchdog still apply.
Original-response usage is omitted for this detached continuation because no
complete ACP usage response is available. An unknown adapter returning a detached
continuation closes the connection rather than manufacturing completion. macOS
displays supplementary input with pending/received/failed delivery; live user
echoes do not duplicate local input, while history loading still replays messages.

`sessionCreated` and `sessionLoaded` optionally carry the agent's `configOptions`.
`setConfigOption` carries `token`, `sessionId`, `configId`, and a select-option
string `value`; the host uses ACP `session/set_config_option`. Its acknowledged
full option list arrives as `sessionConfigured`. Consumers also accept ACP
`config_option_update` notifications. Agent-provided IDs, choices and current
values remain authoritative; unsupported controls are not synthesized.
Configuration failure echoes the token and does not finish a prompt. Native clients may stage next-turn choices while a
prompt is active, without sending configuration commands or replacing the
Agent-confirmed values. Both products keep that intent per session and, after a
terminal turn event (including a failed turn), send one
`applyNextTurnConfiguration` command with `token`, `sessionId`, the product's
latest `catalog` (`id`, optional `category`, `currentValue`, `choices` value
IDs) and `choices` (`configId`, `value`). The Host owns the order and
validation: model options first, then the rest in catalog order; each remaining
choice is revalidated against the latest catalog the Agent returned, skipped
when already current, and must be confirmed by the Agent's reported value. It
answers with one `nextTurnConfigured` event (`token`, `sessionId`, optional
`configOptions` = latest Agent catalog once any request succeeded, optional
`failure` = `unsupported` | `notConfirmed` | `requestFailed`, and for a failed
request the upstream `message`). Products localize the failure code, clear the
remaining intent, keep confirmed settings, and fail a deferred supplement
instead of sending it; disconnect clears the intent as well. A deferred
supplement after a failed turn is failed with that turn's error, never replayed.
The next prompt remains blocked until the command finishes. The Host still
rejects the command while the session's prompt is running. Shape and cases:
`shared/fixtures/agent/next-turn-configuration-v1.json`.

For a new session, the host also preserves the adapter's optional legacy model
catalog while decoding the ACP response and negotiates only the versioned
`jetbrains.air.recommendedValue` extension. If the configured current model is
absent from that catalog, the host prefers an upstream recommendation present in
both the catalog and selector. Without a usable recommendation it selects the
first catalog model available in the selector, including grouped options. The
host requests that model before publishing `sessionCreated`; only the
acknowledged full configuration is exposed, keeping the official choices visible
after the adapter removes its synthetic unknown model. Both
requests share the session creation deadline; rejection, timeout, or an
unconfirmed selection emits `requestFailed`. Valid configured models, loaded
history, and global CLI files remain unchanged. Missing or malformed optional
catalog data or an empty catalog/selector intersection leaves standard ACP
behavior intact. The `upstream`
scenarios in the agent fixture protect this workflow without changing the
command/event JSON shape.

A `cancel` answers pending permissions with `cancelled`, sends one
ACP `session/cancel`, and reports `turnCancelling`. The session remains busy
until its prompt response arrives. A second prompt and configuration changes
are rejected while it is busy. If the agent fails to acknowledge within ten
seconds, the connection fails and its process tree is stopped; clients retain
the visible transcript and offer reconnect followed by `session/load`. This
explicit recovery prevents another message from entering a lost cancelled turn.
Other sessions on the same process are also detached on this failure.
Normal cancellation does not restart the process.

Normal `prompt` turns have no absolute wall-clock deadline. Silence alone cannot
prove that model reasoning or a tool has stalled. After five minutes without
reported reply, thought, plan or tool progress, the host emits advisory
`turnActivity` with `sessionId` and `quiet: true`, once per quiet interval. Actual
progress emits `quiet: false` and starts a fresh advisory interval. The threshold
is fixed in `agent-turn-policy.json`, consumed by the shared Host and the Windows
frontend monitor. This notice never cancels, releases or replays the prompt.
Clients offer continue waiting (dismiss only) and stop, preserving busy state,
transcript, edits and elapsed time. Completion, failure and disconnect clear it.
Permission and stopping states take precedence over the advisory.

Permission decisions have no timer. The host tracks all pending permissions in
that turn and suspends the quiet advisory until all are answered, then starts a
fresh interval. Registration stays ordered under the permission/turn locks;
waiting and responding run in an SDK-owned task so inbound updates, additional
permission requests and connection EOF are not blocked. Cancel, terminal prompt
response and connection shutdown settle every pending request with `cancelled`.
Child permissions retain both the original requester and the owning root turn.
Registration holds the ownership lock through insertion into the permission map;
lock order is ownership, pending permissions, then running turns. A terminal
child or ancestor settles only that subtree's pending requests with `cancelled`,
rejects later requests from that subtree, and leaves root and sibling permissions
and the root prompt running. Settled requests release quiet-period accounting.
The existing child lifecycle update also removes those prompts from the UI queue
and refreshes its attention and tool-wait interval; no new wire event is needed.
Initialization, session/configuration requests, pre-work failure recovery and
cancellation acknowledgment retain their own bounded deadlines. Tool execution
and model-request budgets belong to the upstream Agent. This policy does not
provide a new user-configurable task budget.

The pre-work API-key reconnecting window is twenty seconds from the first temporary
failure, in addition to the initial request and at most ten seconds to confirm
cancellation. It does not reset on each retry. Actual progress removes this
short window and prohibits whole-turn replay; normal turn duration remains unlimited.
Codex owns later stream recovery after progress. While its public error metadata
reports `willRetry: true`, the Host retains the same busy turn without a recovery
deadline or a second attempt limit, and never replays the whole prompt. Native
`stream_max_retries=4` remains configured; this is not unbounded native retry.
Permanent errors, explicit terminal failure, process/connection closure and user
Stop still end the turn through the existing acknowledgment/cleanup paths. A
terminal error preserves local messages and edits; explicit continuation reuses
the session, or reloads native history after reconnection, without automatically
resending the original request. Upstream persistence of unfinished fragments is
not guaranteed. Pre-work window expiry retains the same busy/cancel/acknowledgment semantics
above and reports the last provider error. During backoff, user cancellation
ends the local turn without another prompt. `turnRetrying` carries `sessionId`,
a unique Host or native `turnId`, and `attempt` (at least 2). Pre-work recovery
includes `maxAttempts` (5); native recovery after work omits it, because observed
warnings cannot establish a Host limit for engine-owned requests. It is a
recovery observation, not actual work or a terminal event. macOS presents
“Reconnecting 2/5…” with elapsed time; it clears counts on progress or completion
and ignores retries for retired turns. With no maximum it presents
“Reconnecting…”. Five minutes after the first post-work recovery warning, the
Host emits the same quiet advisory; further warnings cannot postpone it. Actual
progress clears it and starts normal quiet tracking again. macOS shows a recovery
waiting notice with Continue waiting and Stop; dismissal does not resend or
release the busy turn. Permission and Stop take priority. No silent timer implies
thinking or retry.
Generic ACP support does not imply control of its retry engine. Unadapted agents
retain their native retry policy without a Host absolute prompt limit; reliable
counts and a short recovery window require explicit provider recovery events or
a verified configuration adapter. Lithe never applies blind prompt replay to
arbitrary agents.

ACP `usage_update` notifications are forwarded unchanged in `update`, with
`used` (tokens currently in context) and `size` (context window capacity), scoped
by `sessionId`. Consumers replace the previous snapshot, allowing usage to drop
after compaction; these values are not cumulative billing tokens. Missing or
invalid data and a zero capacity represent unknown usage, not an empty window.
The macOS indicator clears stale capacity on disconnect or confirmed model
changes; it does not infer limits from model names. A consumer may retain the
last actual report in its existing workspace/Agent/session-scoped store, bound
to confirmed raw model option IDs and values. Restore it only after loading
confirms the same nonempty model selection. Preserve the historical source
in state; the macOS UI omits source labels and shows only the usage figures.
A new valid or invalid replay report takes precedence. Model changes
invalidate stored occupancy; historical messages without a report remain unknown.
For the pinned Codex adapter, the Host may recover its missing history report
from the existing native App Server connection during the same load. The relay
uses an authenticated, bounded, per-launch loopback channel and per-load tickets;
no second thread writer, prompt or private history parsing is used. The Host
emits the same `usage_update` shape before `sessionLoaded`, with
`_meta.lithe.contextUsageSource: "history"` to identify a last-reported snapshot.
Standard ACP reports take precedence; cancelled/replaced loads cannot publish
a late native report. Failure or absent native usage never blocks history loading.

`turnFinished` optionally includes the ACP prompt response's `usage` object:
required unsigned `totalTokens`, `inputTokens`, `outputTokens`, and optional
`thoughtTokens`, `cachedReadTokens`, `cachedWriteTokens`. The pinned SDK's
`unstable_end_turn_token_usage` feature preserves these counters; absent, null
or invalid usage is omitted without preventing completion. Zero is a reported
value. Counters are Agent-owned: consumers must not infer a per-turn aggregate,
session delta or billing amount, because the adapters' accounting scopes differ.
They must not derive these counters from context occupancy or subscription quota.
`acp-events-v1.json` covers completion both with and without usage.

The launch JSON's optional `observeSubagents` (default `false`) negotiates the
pinned adapters' AIR v1 `nativeSubagentSessions` capability. macOS and Windows enable it;
consumers without child-session UI omit it. Native execution and history remain
upstream-owned. `update` preserves the immediate parent `sessionId` and the
adapter's `subagent_spawned` payload (`subagentSessionId`, `name`, `task`,
`capabilities`), or `subagent_state_update` payload (`subagentSessionId`, `state`).
Ordinary child updates use the child's `sessionId`. Cycles, cross-parent
reattachment and reuse of a known root ID are rejected. A root history reload
clears its old child associations before upstream replay announces them again.
The host's bounded notification shim adds these two adapter variants to the
pinned SDK; all ordinary updates still use SDK validation. The newer SDK's
experimental `subagent_update` draft is not wire-compatible with these adapters.

Child permissions retain their original request `sessionId`, while the outer
`permission.sessionId` identifies the owning root turn. Root cancellation,
completion or shutdown settles all child permission waits through the existing
permission lifecycle. Terminal children and their descendants cannot request
new permissions. Child output and lifecycle count as actual root progress;
child model failures never trigger a whole-root replay. Child messages and
thoughts are scoped separately from the root reply; tool IDs are scoped by
child session, preserving file-review evidence. Only an explicit `completed`
state counts as success. Failed, cancelled and disconnected children do not;
a terminal parent leaves any unreported descendant outcome disconnected.
`acp-events-v1.json` includes nested ownership, output, tools and completion.

The launch JSON's optional `observeModelCalls` (default `false`) asks the host to
start a loopback proxy for API-key gateways or Codex subscription inference and hand the Agent
`http://127.0.0.1:<port>/lithe-<token>` instead of the configured endpoint.
Requests and responses are forwarded unchanged; requests other than generation
endpoints stream through without buffering, and generation bodies over 32 MiB
are forwarded without composition. Same-origin `Location` headers are mapped
back onto the proxy path; cross-origin targets are left unchanged. A proxy that
fails to start leaves the native route unchanged. Codex subscriptions retain the
official OpenAI provider and receive a process-only openai_base_url ending in
/backend-api/codex; Codex owns account credentials, refresh and retries. Each generation request
(`.../messages`, `.../responses`, `.../chat/completions`) then produces one
`modelCall` event with `call.api`, optional `model`, HTTP `status` (200 for
WebSocket completion or an explicit upstream error status), `streaming`,
optional `firstTokenMs`, `durationMs`, optional provider `usage`
(`inputTokens` excluding cache reads and writes for every protocol, `cacheReadTokens`, `cacheWriteTokens`,
`outputTokens`, optional `reasoningTokens`) and optional estimated prompt
`context` (`systemPromptTokens`, `toolTokens`, `mcpToolTokens`, `messageTokens`,
`toolCount`, `mcpToolCount`, `scaledToUsage`) and, only when true, `auxiliary`
(a background request the Agent made for itself, such as Claude Code naming the
session: its tokens count, but it is not a conversation step). Claude subscription
connections are observed the same way: the host points `ANTHROPIC_BASE_URL` at the
loopback proxy, which forwards to `https://api.anthropic.com` byte for byte while
the CLI keeps sending its own credentials. `sessionId` is present only when
exactly one non-cancelling prompt was running when the request started; consumers
drop unattributed calls instead of guessing. The host waits up to two seconds for
a turn's attributed calls to report before emitting its `turnFinished`, so they
arrive first. A call still open after that bound carries `afterTurnFinished: true`
and counts for the session only, never for a later turn. Each `modelCall` also carries
`statistics`, the Host's accounting contribution of that call (`requests`,
`steps`, `failedSteps`, `nonStreamingSteps` for successful non-streamed steps
only, `durationMs`, the four token buckets, optional `reasoningTokens`,
`callsWithUsage`, `firstTokenMs`/`firstTokenCount` and
`generationMs`/`generatedTokens` of streamed steps, and optional `context` when
the call describes the current prompt: auxiliary requests never do, and once a
session's main requests carry tools, tool-less ones no longer do). Products
merge contributions in event order (counters add, `reasoningTokens` adds over
calls that report it, a present `context` replaces the previous one) and never
reinterpret `call` for accounting. Cases:
`shared/fixtures/agent/model-call-statistics-v1.json`. The launch accepts `contextLimits` (`windowTokens`, `autoCompactTokens`, both optional;
zero means unset). Codex receives them as `model_context_window` and
`model_auto_compact_token_limit` in its session configuration. Claude Code has a single
switch, so the threshold (else the context length) is exported as
`CLAUDE_CODE_AUTO_COMPACT_WINDOW`. The Agent's reported `usage_update.size` can differ from
the configured value and may change within a turn, so consumers cap the displayed
capacity themselves instead of trusting the report. Redirect (3xx) hops are
forwarded but are not model calls; only the followed request is reported.
Responses WebSocket upgrades preserve the original handshake and wire bytes,
including masking, fragments, compression, control frames and close frames.
Observation parses copies with a 32 MiB limit for each frame/assembled or
inflated message, preserving each negotiated deflate dictionary lifetime.
Each response.create inference has one observation; generate=false prewarm,
handshakes and control frames never count. previous_response_id inherits only
verified cached numeric section sizes and completed output sizes. One previous
response ID (at most 256 bytes) and at most 1024 output item sizes are retained
per connection. Unknown previous IDs omit composition rather than treating a
delta as the whole context. Malformed, overlapping or over-budget messages
stop observation only; forwarding continues. All upgraded sockets and tasks
are closed with the owning launch. Bodies and credentials are never persisted.
The existing native relay permits subscription observation only after a current
account/read confirms workspaceRouting with backendOrigin https://chatgpt.com
and accountRoutingOverride NO_CONSTRAINT. Missing/failed/managed routing keeps
the native default inference endpoint. Account/login change notifications revoke
confirmed routing and pending discovery requests, so a late response cannot
authorize the new account or workspace even when its email is unchanged. A fresh
native query is required; an account change also closes an already observed
connection. Login, workspace discovery and quota routing remain native.
Old subscription histories retain actual native context occupancy but cannot
acquire missing request composition retroactively.

Calls without `usage` make session token sums a lower bound, which consumers
must label as such. Unparsable provider data omits the
optional fields and never affects forwarding. Without these events, consumers do
not estimate model-call counts, first-token latency, output speed or prompt
composition. Decision:
`.agents/notes/implemented/architecture/2026-10-13-agent-model-call-observation.md`.

macOS keeps local turn statistics in memory. Elapsed time uses a monotonic clock
from user submission (including queued session creation/loading, tools and
permission waits) until completion, request failure or disconnect. Cancellation
continues timing until acknowledged. Each observed turn keeps a frozen footer
before the next user message; tab switches do not reset it. Replayed history
does not fabricate timing or token measurements absent from the Agent's records.

Tool updates preserve ACP `kind`, `locations`, `rawInput`, `rawOutput`, and
`content` (including diffs). Partial updates replace only fields supplied by
the agent. Permission displays combine already received tool details with the
permission request, and distinguish allow/reject option kinds.

The Host advertises `clientCapabilities.session.notices: {}` using the pinned
SDK's `unstable_session_notices` feature. ACP `notice` updates retain their
`severity`, plain-text `title`, and optional `description` in the existing
`update` envelope. They are live advisories, not assistant replies or persisted
history. macOS displays the latest notice per session through its shared Banner,
allows dismissal, and clears it on the next submitted prompt or disconnect.
An outstanding permission request takes presentation priority without discarding
the notice; the notice is displayed after the user answers. Visible text is
bounded to two title lines and three detail lines, with full text on hover.
Claude ACP 0.81.2 may defer its initial Auto fallback warning until the first
prompt: its structured warning title `Auto mode unavailable` is shown only
while the confirmed mode is `acceptEdits`. A confirmed model change clears a
warning from before that change, while preserving a new warning emitted between
an upstream Auto-to-Accept-edits mode transition and its next complete config
snapshot. This transition is session-local and consumed by one config snapshot;
it also covers native `/model` changes without a local request token. A later
model change clears the warning normally. A pending or failed local setting must not clear a still-applicable
warning. Plain assistant text is never classified or removed by this rule.
When a configuration request is pending, the matching fallback notice waits for
that request's result before checking the confirmed mode. This preserves a new
fallback sent before its `config_option_update` or response, while still dropping
an obsolete startup notice after a confirmed switch to Plan. A newer applicable
notice in the same session invalidates the older pending fallback, so a later
configuration success or failure cannot replay it over the newer notice. In the
reverse order, the newest fallback still waits for confirmation before replacing
the earlier notice. Invalid notices and notices for other sessions do not change
that ordering.
Windows has no consumer for this shared Host conversation API yet.

The caller must close each handle
exactly once; closing revokes callbacks and stops the process tree, force
killing processes that do not exit after a short grace period. The callback
context must remain valid until close returns. This API is owned by
`lithe-agent-host` and is separate from the synchronous JSON command envelope.

## Envelope

The typed `lithe_core::ai` API provides credential-free commit request planning,
configuration parsing, and response decoding. macOS uses `ai.commitInputBudget`,
`ai.planCommit`, and `ai.decodeCommitMessage` over the existing JSON C ABI; Windows
uses the typed API. The [AI commit contract](ai-commit.md) defines the bounded diff
prefixes, payloads, errors and platform-owned I/O.
`ai.pullRequest.plan` / `ai.pullRequest.decode` and `ai.inlineEdit.plan` /
`ai.inlineEdit.decode` share that provider request model; see
[AI generation requests](ai-generation-requests.md).

Every request has this shape:

```json
{
  "id": "request-id",
  "operationId": "operation-id",
  "timeoutMilliseconds": 30000,
  "origin": { "source": "user", "trigger": "find-in-files", "operation": "op-7f3a" },
  "command": "workspace.search",
  "payload": {}
}
```

`operationId` is optional for compatibility and defaults to `id` when `id` is
present. `timeoutMilliseconds` is optional; a positive value starts a
cooperative deadline. `lithe_core_cancel` is thread-safe and returns `1` when
the operation is active. Cancellation and deadlines are checked at command
boundaries, workspace traversal points, and Git process waits. They return
`cancelled` or `timed_out` in the standard error envelope.

`origin` is optional diagnostics provenance:
`{ source?: "user" | "background" | "unknown", trigger?: string, operation?: string }`.
It never changes command behavior. `trigger` is the stable identifier of the UI
action that caused the request, and `operation` is the correlation identifier
shared by that action and every request it caused. A `trigger` must be 1–64
bytes of ASCII letters, digits and `._:/-$`, and an `operation` 1–128 bytes of
ASCII letters, digits and `._:/@+-`. A value outside its shape is omitted from
the trace instead of failing the request. See [Execution traces](#execution-traces).

Successful responses contain `ok: true` and `data`. Failed responses contain a
stable error code and a user-facing message:

```json
{
  "id": "request-id",
  "ok": false,
  "error": {
    "code": "invalid_request",
    "message": "Invalid JSON request"
  }
}
```

## Commands

### MCP configuration

`mcp.probe` accepts a user-reviewed connection `{transport, command?, args?, env?,
url?, headers?}` with only those fields. Agent Host uses the pinned official
rmcp SDK for initialization, session handling and paginated `tools/list`; it
never sends `tools/call`. Results are `{tools:[{name,description}]}`, sorted by
name, deduplicated, bounded to 1000 tools/20 pages/2 MiB of metadata. stdio input
and each HTTP response body are bounded before decoding. A probe has a
30-second request budget plus bounded cleanup, cancellation is cooperative,
and stdio children and their process groups are reaped on completion or cancel.
HTTP accepts HTTPS and loopback HTTP, rejects credential-bearing URLs and
redirects, preserves TLS verification and explicit headers, and uses no cookie
store. It does not inherit another Agent's OAuth session or unmapped native
configuration options. Legacy `sse` remains a configurable transport but this
SDK probe returns `not_supported` rather than inventing a healthy status.
The host must require an explicit detection action; launching local code or
package runners also requires the product's execution confirmation.

`mcp.toolPolicy` is a pure text operation with `{source,content,server,tools,
owned?,tool?,enabled?}`. `source` is `codex` or `claude`; omission of `tool` and
`enabled` reads current policy. It returns `{content,changed,owned,tools,
hasRestrictions}`. The returned tools contain `{name,enabled,editable}`.
Codex uses entry-local `disabled_tools`, preserving `enabled_tools`; Claude's
input is its user `settings.json`, editing only `permissions.deny` with exact
`mcp__<normalized-server>__<normalized-tool>` rules. Unknown settings/formatting
outside the targeted value survive. Existing unowned denies, broad wildcard
rules, allow-list exclusions and ambiguous normalized names are not relaxed.
Hosts retain the exact added tool names by native path/server, validate full
file snapshots before atomic writes, and never treat a read as ownership.
Policies describe the user configuration; project/managed settings and live
Agent sessions may differ. Claude server renames are refused while user MCP
restrictions exist, to avoid re-enabling tools under a new name.

`mcp.commandLine` accepts `{action:"format",command,args}` to return `{line}`,
or `{action:"parse",line}` to return `{command,args}`. POSIX shell-style quoting
is only a lossless text projection: hosts pass argv directly, never evaluate a
shell, substitutions, pipes or redirects. Blank and embedded-newline arguments
are preserved; malformed quoting is rejected. These operations and probe
results use `shared/fixtures/mcp/tools-v1.json` as a synthetic contract fixture.

`mcp.parseRegistry` accepts `{ content: string }` (at most 1 MiB UTF-8) and
normalizes an official MCP Registry v0.1 response into `{ entries, nextCursor }`.
Each entry has `id`, `title`, `summary`, `version`, nullable `publisher`,
`source: "registry"`, nullable HTTPS `website` and
nullable `draft: McpServer`. At most 100 input entries are accepted. Inactive
records are skipped, pagination cursors remain opaque, and links containing
credentials or unresolved variables are not offered. Only static HTTPS remote
endpoints without header/variable inputs, or versioned npm/PyPI stdio packages
without additional runtime/package/environment inputs, using the public default
registry and runner, produce drafts. npm versions must be complete releases;
mutable tags and major/minor ranges remain documentation-only. Other
records remain documentation-only. This operation never fetches, installs or
executes anything. Hosts own cancellable directory requests and require the
user to review and save a draft before modifying Agent configurations.
`shared/contracts/mcp-registry-page.json` is a portable synthetic response.

`mcp.featuredRegistry` accepts `{}` and returns the same page shape with
`source: "featured"` from the Git-owned, compile-time catalog at
`rust/lithe-core/src/mcp/featured.json`. It performs no network, filesystem,
package resolution or execution. Catalog package versions are pinned; remote
requirements remain subject to the publisher's documentation. Hosts show this
page without contacting the Registry, extend matching entries on explicit
search, and retain available results when a directory request fails.
The release catalog includes Context7, Playwright, Chrome DevTools, Microsoft
Learn, GitHub, DeepWiki, Exa, Filesystem, Fetch and Memory. A featured entry may
add `setup: "bearer-token" | "allowed-directories"`: its draft is an incomplete
template, requiring an Authorization bearer value or at least one absolute
directory argument after the fixed Filesystem package argument. Hosts must
collect and validate these inputs before saving and must not select Agents by
default. Public Registry parsing never copies `setup`, even when input uses a
featured-looking ID. `shared/fixtures/mcp/featured-setup-v1.json` illustrates the
optional field; ordinary entries omit it. Brand marks are platform-owned,
read-only bundled assets, selected only for known featured IDs; public entries
keep the transport fallback. No response can select arbitrary resources or
cause remote image fetching.

`mcp.parseConfiguration` accepts `{ source: "codex" | "claude", scope:
"global" | "project", content: string, projectPath?: string }` and returns
`{ servers: McpServer[] }`. Claude project scope requires `projectPath` and reads
`projects.<projectPath>.mcpServers`; Codex reads `mcp_servers` in the supplied
file. Core handles bounded text only; hosts own paths, file I/O, backups and
atomic writes. Configuration text is limited to 1 MiB UTF-8. Invalid requests or
configuration return redacted `invalid_request` errors.

A server has `name`, `transport` (`stdio`, `http`, `sse`), optional `command` and
`url`, `args: string[]`, `env` and `headers` arrays of `{ key, value }`, plus two
lowercase SHA-256 hashes with separate purposes:

- `definitionHash` keeps the existing library grouping identity: name, transport,
  and modeled fields used by that transport, with environment/header entries
  sorted deterministically. Unknown fields do not change this hash.
- `sourceHash` covers the name and the **complete semantic source entry**,
  including unknown authentication, timeout, nested and non-string values, as
  well as fields unused by the active transport. Object/table keys are sorted,
  array order and value types are preserved, and source formatting/comments are
  excluded. This hash is source-specific and is not a grouping key. Parsed
  servers always supply it; request decoding permits an absent/null value for
  compatibility with older clients and new drafts.

`mcp.planWrite` accepts `{ source, scope, projectPath?, content?: string | null,
operation: "set" | "remove", server?: McpServer, name?: string,
previousName?: string, expectedHash?: string, owned?: OwnedEntry[],
toolFilters?: {enabledTools?: string[], disabledTools?: string[]} }`. `set`
requires `server`, `remove` requires `name`, and project scope requires
`projectPath`. `previousName` identifies the original of a rename. Each owned
entry is `{ name, definitionHash, sourceHash?: string }`; hosts must record the
hashes returned from the actual write plan rather than hashes from the draft.

Successful Codex removals also return `toolFilters` when native `enabled_tools`
or `disabled_tools` exists. These lists contain tool names only; an empty
allow-list stays empty and malformed lists reject removal. Hosts retain them
by native path/server only after the complete write batch succeeds, separately
from live source ownership. A later `set` applies retained filters only when
inserting a new Codex entry; existing/renamed native policy always takes
precedence. Returned hashes cover the restored policy. Claude's user deny
rules remain in its separate settings file during server removal.

Automatic replacement/removal, including unchanged set plans used for repeated
registration, requires an owned record whose name, `definitionHash` and
`sourceHash` match the current entry. An existing raw entry omitted from discovery
because it lacks a usable command/URL also conflicts rather than being treated as
an empty slot. A legacy owned record
without `sourceHash` does not prove ownership: mutation is refused with
`externallyModified` when the name is recorded. An unrecorded name returns
`ownedByUser`. Hosts must not silently upgrade legacy records from the current
file or append the displayed hash to `owned` to authorize an explicit action.

When supplied, `expectedHash` means the **full `sourceHash` of the original
entry displayed to the user**, not `definitionHash`. It is checked against the
current entry before unchanged-definition or ownership early exits; a missing
entry or different hash returns `externallyModified`, even if a newer ownership
ledger matches the current file or the desired modeled definition is unchanged.
An exact match authorizes an explicit edit/remove of that original even when
it is not owned. For rename, it refers to `previousName`, and cannot authorize
an unrelated existing destination; destination ownership checks still apply.

The response is `{ content, changed, action, conflict, definitionHash?,
sourceHash?, toolFilters? }`. Actions are `inserted`, `updated`, `unchanged`, `removed`, `absent`,
or `conflict`; conflicts leave the input unchanged. Successful set plans return
both hashes computed by parsing the actual output entry, including preserved
unknown fields. Unchanged set plans also return the current entry's hashes;
removal can return the old definition hash for filter retention; absence has no entry hashes. Hashes sent on the draft server
are never trusted as write output or persisted into Agent configuration.

The MCP server library is planned by three Core commands; hosts only discover
paths, read and atomically write files, persist the ledger and localize codes.
Each takes `files: LibraryFile[]` (at most 16, unique `id`), where a file is
`{ id, source: "codex" | "claude", scope, projectPath?, path, content?: string |
null, owned: LedgerEntry[] }`. `id` is the host's opaque ledger key and `path`
the native path that keys retained tool filters. A ledger entry is `{ name,
definitionHash, sourceHash?, toolFilters?: { <path>: {enabledTools?,
disabledTools?} } }`; it never contains env/header values.

`mcp.librarySnapshot` accepts `{ files }` and returns `{ rows, failures }`. Rows
merge every parsed server by `name#definitionHash` (`id`), carry the definition
from the first source in host file order, `sources: [{ file, definitionHash,
sourceHash, ownedByLithe }]`, `hasDefinitionConflict` (another global entry
with the same name has a different definition) and `projectOnly`. A source is
owned when a ledger entry records its name and complete `sourceHash`. Rows are
ordered by natural, case-insensitive name (digit runs compare numerically, bytes
break ties), then global before project-only, then definition hash. A file that
fails to parse contributes no rows and appears in `failures: [{ file, code,
message }]` without echoing content; hosts report their own read failures.

`mcp.validateDraft` accepts `{ draft: { name, transport, command, url,
arguments, env, headers, enabledAgents, setup? } }` and returns `{ issues:
[{ field, code }], definition }`. Issues are ordered by display priority:
`name`/`nameRequired` or `nameInvalid` (`^[A-Za-z0-9][A-Za-z0-9._-]*$` after
trimming), `enabledAgents`/`agentsRequired`, `env` or `headers`/`duplicateKeys`
(active transport only, blank keys ignored), `command`/`commandRequired`,
`url`/`urlInvalid` (an absolute URL with a host), then featured setup:
`headers`/`bearerTokenRequired` (one `Authorization: Bearer <token>` value,
scheme case-insensitive) or `arguments`/`allowedDirectoriesRequired` (at least
one POSIX, drive or UNC absolute folder after the two fixed arguments).
`definition` is the normalized server a save writes — trimmed name, command or
URL, only the active transport's fields, blank keys dropped, entries sorted by
key — or `null` while issues remain. Values are never echoed in issues.

`mcp.batchPlan` accepts `{ files, intent }`, with `intent` one of:
`{ kind: "save", draft, original?: { name, sources: [{ file, sourceHash?,
ownedByLithe }] } }`, `{ kind: "setAgent", definition: McpServer, agent,
enabled }` or `{ kind: "delete", name, files: string[] }`. `save` validates the
draft as above, removes the captured original from every global source whose
Agent is no longer enabled (requiring the captured `sourceHash` and a ledger
entry with that exact hash), and sets the definition in every global file whose
`source` is enabled, passing the captured hash as `expectedHash` and renaming
from the original name where the original existed. `setAgent` targets the first
global file of `agent`; `delete` removes the name from the listed files. Each
file's operations are planned in order with `mcp.planWrite` rules against the
previous output and the evolving ledger. The response is `{ status: "invalid",
issues }`, `{ status: "rejected", rejection: { code, name, file } }` with code
`notOwned`, `externallyModified` or `agentHasNoGlobalConfiguration` (`file` is
the conflicting file, or `null` for draft-level checks), or `{ status: "ready",
changes: [{ file, changed, content?, owned, renames: [{ from, to }] }] }` in
host file order. `content` is present only when changed; `owned` is the file's
next ledger (unchanged files return their input ledger). Hosts write every
changed file as one rollback batch and publish ledgers and renames only after
the whole batch succeeds. `shared/fixtures/mcp/library-v1.json` holds the shared
cases; its `{{sourceHash:<file>:<name>}}` placeholders are resolved from the
parsed fixture files.

### Agent adapters

`ai.configuration.sources` takes `{source, home, environment}` (`source` is
`codex` or `claude`, `home` an absolute path, `environment` only the directory
overrides `CODEX_HOME` / `CLAUDE_CONFIG_DIR`) and returns `{files}`: the native
files `{file, path}` the platform should read. `ai.configuration.parse` takes
`{source, files, environment, allowIncomplete}` with the file texts keyed
`config`, `auth`, `settings`, `credentials` and `root`, each at most 1 MiB, and
returns `null` when nothing is configured, otherwise `{model, provider, issue,
reasoningEffort, hasCredential, credential, unsupportedAuthentication}`. The
response never contains a secret: `credential` is a locator
(`{kind: "environment", name}` or `{kind: "file", file, path}`) that the host
resolves natively against the same text or environment. Malformed input returns
`invalid_request` with a fixed code (`AI_COMMIT_INVALID_CONFIG`,
`AI_CONFIGURATION_INVALID_AUTHENTICATION`, `AI_CONFIGURATION_SMART_QUOTES`,
`AI_CONFIGURATION_TOO_LARGE`) and never echoes input. `allowIncomplete: true` is
for editor drafts: it ignores the environment, accepts blank or partial text and
keeps missing endpoint/model fields empty. The shared cases are in
`shared/fixtures/ai/cli-configuration-v1.json`. It replaces the former
`agent.parseProviderConfiguration`.

`agent.edits.reversePlan` takes `{diffs, disk}` (normalized edit evidence plus the
current file text, or `null` when the file is missing) and returns the rollback
plan or a conflict; it never touches the file system. Path containment, encoding,
guarded writes and Trash stay with the platform. Cases are in
`shared/fixtures/agent/edit-review-v1.json`.

`agent.instructions.read` takes `{agentId}` (`codex-acp` or `claude-acp`) and
returns `{agentId, path, content, exists, revision}`. It does not create files.
`agent.instructions.save` takes `{agentId, content, expectedPath, expectedRevision}`.
The host resolves the native user profile again and rejects a changed effective
path or byte revision before replacing the file. The result is a fresh effective
snapshot: clearing a Codex override may return the base `AGENTS.md` instead.
No prompt injection, account settings, repository files, or native history are
modified. Files must be regular UTF-8 files at most 1 MiB; terminal symlinks are
rejected. Read-only files cannot be overwritten. Existing file permissions are
preserved; Unix new files use `0600` and new directories use `0700`.
Save staging is a sibling temporary file removed on completion/failure.
Other Lithe saves are serialized by a non-waiting lock; external writers do not
share it, so revision checks are optimistic rather than an OS-wide transaction.
Errors use the existing envelope codes with stable `details` reasons including
`unsupported_agent`, `file_access`, `unsafe_file`, `file_changed`, `file_too_large`,
`invalid_utf8`, `profile_missing`, `profile_relative`, and `busy`.
The fixture is `shared/fixtures/agent/agent-instructions-v1.json`.

`agent.instructions.shared` takes a platform-selected absolute `dataDirectory`
from the writable application-support adapter plus one tagged action:

- `read`: returns `{file, agents}` without creating files. `file` is the shared
  `Shared.md` snapshot; each Agent reports `{agentId, file, enabled, needsSync,
  ownLineCount, issue}`. A native read or marker failure sets `enabled: null` and
  an actionable issue rather than claiming disabled.
- `save`: takes `content`, `expectedRevision` for Shared.md and `files` guards
  (`{agentId,path,revision}`) for targets. It saves the shared source, then updates
  already-enabled native targets. A failed target retains its bytes and an issue;
  other targets continue. `needsSync` compares the actual block with the saved source.
- `setEnabled`: takes `agentId`, `enabled`, the shared `expectedRevision` and one
  `file` guard. It inserts/replaces or removes only the Lithe-delimited block in the
  effective native file; it never disables the Agent or removes its own instructions.

Marker tokens are `<!-- LITHE:SHARED-INSTRUCTIONS:BEGIN -->` and
`<!-- LITHE:SHARED-INSTRUCTIONS:END -->`. The owned range includes its separator
newlines, so disabling restores the original bytes. Duplicate, incomplete or edited
markers are rejected; shared content may not contain the marker tokens. Native
source selection, size, permission, symlink and optimistic revision guards remain
those of `agent.instructions.save`. A nonblocking OS file lock in `.sync.lock`
serializes shared writes across app processes. Shared.md uses the same 1 MiB bound,
private Unix modes and atomic replacement; source/target commits are individually
atomic and partial success is explicit. Cancellation stops remaining targets and the
next page read reconciles actual state. None of these files is a build cache or
installed resource. The fixture is `fixtures/agent/shared-instructions-v1.json`.

`agent.hooks` manages a platform-owned writable Hook library. Requests take
`dataDirectory` and a strict `action`: `read`, `save`, `remove`, or `sync`.
Mutations require `expectedRevision` and native `files` guards containing
`agentId`, `path`, and `revision`. Guard paths never select write destinations:
Agent Host resolves `CODEX_HOME/hooks.json` and `CLAUDE_CONFIG_DIR/settings.json`
using native profile defaults when environment overrides are absent.

`save` also takes `hook`: a UUID `id`, unique ASCII `name` (1–80 letters,
digits, hyphens or underscores), `description` (at most 200 Unicode scalars),
`event` (`turn-end`, `after-tool`, `before-tool`, `prompt`, `session-start`),
`matcher` (`all`, `shell`, `edit`), nonempty UTF-8 `command` (at most 32768 bytes),
nullable `timeoutSeconds` (1–86400, null inherits the native default), selected
`agents` (`codex-acp`, `claude-acp`), `enabled`, and `pendingRemoval: false`.
Only tool events accept a non-`all` matcher. `remove` takes `id`; `sync` retries
the existing desired state. Neither configuration management nor reading the
library executes commands or grants native trust.

The result contains source `revision`, flattened `hooks` with actual
`configuredAgents` and `needsSync`, plus `targets` containing `agentId`, nullable
`file` guard, nullable `issue`, and `disabled` (Claude's `disableAllHooks`).
Native configuration contents, which can include secrets, are never returned.
Desired state is committed before target writes; target failures remain visible
and removal failures retain a `pendingRemoval` row. A nonblocking OS file lock
coordinates library writers. Each bounded UTF-8 file replacement is guarded and
atomic; cross-file synchronization is explicitly partial, with write-ahead
ownership records permitting recovery after interruption. Native duplicate JSON
keys, malformed JSON, symlinks, nonregular files and changed snapshots are rejected.
Existing unknown JSON values survive writes, while formatting is normalized.

Only exact recorded placements can be retired. Native groups are cleared to
`{"hooks":[]}` instead of compacted, preserving Codex's index-based trust keys.
Unchanged commands keep their original positions; edited commands do not inherit
trust. A matching user-owned entry is never claimed or duplicated. Codex still
requires native Hook enablement and approval in `/hooks`; `configuredAgents`
does not claim execution. Source, ownership journal, lock and temporary siblings
are user state outside installed resources and cannot be reused across worktrees.
The shared fixture is `shared/fixtures/agent/hooks-management-v1.json`.

`agent.hooks.validateDraft` validates an unsaved editor draft without reading or
writing files, using the same rules `save` enforces in Agent Host. The payload is
`{hook, existingHooks}`: `hook` has `id`, `name`, `description`, `event`, `matcher`,
`command`, `agents` and the raw `timeoutText` of the timeout field (empty inherits
the native default; only ASCII digits are integers), and `existingHooks` lists
library rows as `{id, name}` for the case-insensitive unique-name rule. The result is
`{valid, issues, timeoutSeconds}`: `issues` holds at most one `{field, code}` per
field in editor order, and `timeoutSeconds` is the parsed value platforms store when
saving (null when empty or rejected). Fields and codes: `id` `invalid`; `name`
`required`, `too_long`, `invalid_characters`, `duplicate`; `description` `too_long`;
`matcher` `incompatible_event`; `command` `required`, `too_long`, `contains_nul`;
`timeout` `not_integer`, `out_of_range`; `agents` `required`, `unsupported`,
`duplicate`. Platforms localize `agent.hooks.draft.<field>.<code>` and enable saving
only when `valid`. A malformed payload fails with `invalid_request`. The fixture is
`shared/fixtures/agent/hook-draft-validation-v1.json`.

`agent.status`, `agent.install`, `agent.uninstall`, and `agent.installCli` manage ACP adapters in
`<dataDirectory>/agents/<agentId>`, using the Node.js and npm the user installed.
Lithe never installs Node.js or npm; the agents' own command-line tools are installed only through `agent.installCli` on an explicit user action. `agent.status`
detects Node.js and npm through the login shell's `PATH` and lists every
supported agent with its pinned version, installed version, provider protocol,
and blocking issues. Each adapter also reports optional `updateAvailable`: true only when the verified catalog version is strictly newer than the installed version under SemVer precedence, false for equal or newer local versions, and absent for missing or unparseable versions. Build metadata does not affect precedence. This target remains Lithe's verified catalog version, not an unverified latest registry version. Hosts must not derive updates from version-string inequality. Adapters that drive the agent's own CLI (Codex, Claude Code) report the
CLI found on that `PATH` with its minimum version; they are installed with
`--omit=optional`, so their bundled CLI copy is not downloaded, and are launched
with the user's CLI through the adapter's variable (`CODEX_PATH`,
`CLAUDE_CODE_EXECUTABLE`). A missing or
too old CLI is an issue for the user to resolve, never installed by Lithe.
For every catalog CLI, `cli.installation.updateAvailable` is `true` only when the verified
installation owner reports a newer release, `false` when no newer release is found
(npm's published version or Homebrew's local index), and absent when the check is
unavailable. Optional `cli.installation.availableVersion` retains the actual target returned by that same query: npm's published version or the matched Homebrew entry's `current_version`. Hosts display the detected current version and confirmed target together, including in the collapsed CLI row. If Homebrew confirms an outdated package without supplying its target version, hosts show an unknown target rather than inferring one from the installed version. Empty Homebrew outdated results do not provide a latest version. Failed read-only probes include optional `cli.installation.updateCheckError` with a bounded diagnostic reason; unavailable native protocols remain unknown without pretending to have checked the latest version. It does not change `canUpdate`, which only describes whether Lithe can
safely invoke that owner. npm checks query the verified update target, including
its explicit `@latest` tag; Homebrew checks query the verified owning package and
do not refresh the local index automatically. Native installers without a
read-only version protocol report an absent value; checks never execute an
updater or substitute a different release channel. New catalog CLIs reuse this
source-based check without command-name branches.
`agent.install` runs `npm install` into a staging directory
and replaces the previous install only after the adapter executable exists; it
honors `operationId` cancellation and `timeoutMilliseconds`. Failures use
`runtime_missing` (Node.js or npm unusable), `process_failed` (npm failed, with
its output tail), `invalid_request`, `cancelled`, or `timed_out`. Payloads and
results are fixed by `shared/fixtures/agent/agent-management-v1.json`.

`agent.installCli` resolves the current PATH executable and its installation
owner again on each explicit action. A missing CLI uses npm; an existing npm CLI
requires the selected npm's global root, package manifest/bin and active link
to agree before `npm install -g <package>@latest`. Homebrew requires the active
target to belong to its reported Caskroom/Cellar and an installed package receipt;
it runs `brew upgrade --cask/--formula <owning-package>`, retaining the installed
channel. A standard Claude native launcher uses `claude update`. Unknown,
broken, unrecorded, or mismatched Node/npm installations require manual updating;
there is no force overwrite, installer migration or automatic npm fallback.
After completion, the host refreshes the login-shell PATH and requires the CLI
selected there to meet the adapter's minimum version before returning `cliVersion`.
The successful response also includes optional `updaterWarning` (null for a clean
exit, a bounded output tail for a recovered installer failure). A nonzero exit
can succeed only if the CLI is now present and usable, and its numeric version
strictly increased compared with the pre-update CLI (or it was previously absent).
An unchanged, downgraded, missing or still-too-old CLI remains `process_failed`;
cancellation, timeout and process-start failure never recover through a version
probe. Hosts show the verified version as success and keep any warning/log separate
from errors. Older responses without `updaterWarning` decode as a clean result.
Node.js and npm remain user-managed. Detection is read-only and locally bounded.

`agent.status` includes optional `cli.installation` with `source` (`npm`,
`homebrew`, `native`, `missing`, `unknown`), `canUpdate`, and display-only
`updateHint`. Hosts show the source and guidance, and offer automatic update
only when `canUpdate` is true. The hint is never executable input. Absent fields
remain backward compatible with older hosts. Windows installer/shim ownership
has not been verified; unrecognized installations use the manual path.
The minimum CLI version is a compatibility requirement, not a latest-version
check. For all CLIs, macOS offers Update only when `canUpdate` and
`updateAvailable` are both true, including when the preflight row is collapsed.
A false or absent `updateAvailable` hides that action, even for a CLI below the adapter's minimum version; compatibility warnings and manual guidance remain visible. Hosts show loading and completion on every refresh, retain old detection data on failure with the failure reason, and hide stale update actions until a subsequent successful check.
After a successful update, users reconnect the Agent to start the updated CLI
and obtain its model catalog; existing conversations are not interrupted automatically.

`agent.install` and `agent.installCli` publish `agentInstallProgress` through the
existing synchronous `execute_json_with_events`/C ABI event callback. Each event
carries the request's `operationId` and a `progress` object: `stage` (`preparing`,
`downloading`, `installing`, `updating`), `downloadedBytes` (received archive body bytes),
`bytesPerSecond` (most recent sample), `elapsedMilliseconds`, and
`idleMilliseconds` (since the last archive bytes). Counters contain no URLs,
headers, credentials, or paths. npm still owns fetching, proxies, retries, cache,
and extraction. A built-in Node observer counts bytes without consuming its
stream and restores inherited `NODE_OPTIONS` before npm starts child scripts.
No total or overall percentage is supplied: npm can discover additional packages
and may use cached packages. Events stop before the final response, including
failure, timeout, and cancellation. Hosts reject stale operation IDs and clear
live counters at completion. Examples are in `agent-management-v1.json`.
Homebrew and native updaters emit `updating` with zero transfer counters: their
package manager owns the download and Lithe does not infer bytes from logs.

| Command | Purpose |
| --- | --- |
| `core.ping` | Verify the ABI and protocol version |
| `community.discourse.auth.begin` | Create an ephemeral RSA-OAEP authorization session and return the Discourse browser URL |
| `community.discourse.auth.complete` | Decrypt, validate, and consume one Discourse user API key callback |
| `community.discourse.auth.revoke` | Revoke the current Discourse user API key |
| `community.discourse.topics` | List normalized latest or top topic summaries |
| `community.discourse.topic` | Read one topic with ordered, sanitized post HTML |
| `community.discourse.categories` | List normalized visible categories |
| `community.discourse.search` | Search normalized topics and sanitized posts |
| `editor.lineEdit` | Apply a deterministic line-level text transform and return the replacement plus selection to restore |
| `lsp.planWorkspaceEdit` | Validate language-server workspace edit targets against the workspace and open documents, and order the commit |
| `lsp.classifyNavigationTarget` | Classify a language-server jump target as workspace, external read-only or rejected |
| `editor.planTextEdits` | Validate and order a plugin document edit batch into UTF-16 offsets with the document's line ending |
| `editor.parseNavigationInput` | Parse a bounded line or line:column input into zero-based editor coordinates |
| `editor.navigationHistory.reduce` | Reduce one bounded back/forward navigation history event and return the next state plus the location to open |
| `editor.lineCommentToken` | Resolve the line comment token for a file extension or language id |
| `workspace.releaseIndexing` | Retire a policy and clear index/cache data at project close; accepts `root`, optional `ownerId`, and that owner's last observed `revision`, returns `released`; an old close must not retire a new generation |
| `workspace.refreshIndexing` | Refresh external Git decisions for a live `root`, `ownerId`, `revision` lease without changing preferences or release tokens; returns lazy `IndexingStatus` |
| `workspace.configureIndexing` | Install a process-local, canonical-root indexing policy before workspace consumers run; returns a monotonic revision, effective directory reasons and Git failure state; see `shared/fixtures/workspace/indexing-policy-v1.json` |
| `network.proxyPolicy` | Normalize the stored proxy settings into the policy a network stack must apply (mode, server, credentials, exclusions) |
| `workspace.snapshot` | Enumerate visible workspace nodes and relative file paths; `nestedWorktrees` lists linked worktrees checked out inside their own repository, which are left out of the tree, files, and search index; the built-in hidden names are skipped without being read, and include `node_modules`, Python virtual environments (`.venv`, `venv`), `__pycache__` and `*.pyc` files; `includeTree: false` returns only `files` and a childless `root`; `files` (and the tree, when included) keep the lowercase traversal order that bounded consumers such as Windows Quick Open rely on, not the natural display order of `workspace.listDirectories` |
| `workspace.filterChanges` | Filter an array of workspace-relative paths, or `{ paths, hiddenFilePatterns }` whose `!` entries turn default exclusions off, against Core's default build/cache exclusions; preserve order, spelling, and the empty root path. Native event loss bypasses filtering. Hosts relativize to the most specific explicit watch root and retain explicitly watched files. |
| `workspace.planDuplicate` | Name the copy of one project item next to its source (`foo.txt` → `foo copy.txt`, then `foo copy 2.txt`) from the sibling names the host has seen to exist |
| `workspace.planPaste` | Name pasted project items in one destination directory: a free name is kept, a taken one gets the copy suffix, and earlier items of the same paste count as taken |
| `workspace.reduceDirectoryAction` | Apply "set role", "exclude" or "cancel exclusion" to a root's persisted directory rules and return the complete state to persist |
| `workspace.relocateDirectoryRules` | Move (or drop, after a delete) the directory rule keys of a renamed, moved or deleted subtree, optionally into another workspace root's rules |
| `workspace.listDirectories` | Return one visible level of children for each requested workspace-relative directory (`""` is the root); missing, hidden, symlinked, or nested-worktree paths are omitted, and each listing reports the nested worktrees it left out. Child directories have `children: []` only when a shallow probe proves them visibly empty; otherwise children remain omitted (unloaded), with no recursive tree allocation. Children list directories first, then names in IDEA's natural file-name order (digit runs compare by value, case-insensitive, `-` next to `_`; fixture `shared/fixtures/workspace/file-name-order-v1.json`) |
| `workspace.repositories` | Discover deterministic Git repository roots for an opened workspace |
| `workspace.recentProjects.reduce` | Apply one record, remove, pin, import, or normalize action to the recent project list and return the retained order |
| `workspace.search` | Search visible file names and UTF-8 text files |
| `workspace.searchEverywhere` | Search visible file names, Java types/methods, and UTF-8 text files |
| `workspace.rankNames` | Pure ranking of candidate names that the platform enumerates itself (`{ query, candidates: [{ name, path? }], context: { openPaths, recentPaths }, limitPerTier? }`). Use it only for lists Core cannot index: Windows remote/WSL roots, symbol lists, navigator lists. Roots Core indexes go through `workspace.searchEverywhere`, so an inventory is never sent back to Core. Returns `matches: [{ index, degree, tier, nameMatchRanges }]` ordered by degree, open/recent tier, recency, then file-name order (fixture `shared/fixtures/search/rank-names-v1.json`) |
| `workspace.replacePreview` | Return deterministic replacement lines and complete replacement text |
| `workspace.replaceText` | Plan replacement against a host-captured text snapshot without writing |
| `workspace.searchTextBatch` | Search provider-captured text snapshots using workspace matching rules |
| `file.read` | Read a UTF-8 file using a workspace-relative path |
| `file.write` | Write a UTF-8 file using a workspace-relative path |
| `document.lifecycle` | Reduce a shared document save, external-change, or conflict event without reading text or disk |
| `document.planSaveBatch` | Select the open documents a Save All or save-before-launch batch writes |
| `document.reduceSaveBatch` | Reduce save batch member outcomes and live documents into one batch status |
| `history.record` | Store a versioned text snapshot and metadata |
| `history.entries` | List valid history entries for one file or a workspace |
| `history.content` | Read a stored history snapshot by relative storage path |
| `history.relocate` | Move retained history for a file or directory subtree after a rename or move |
| `history.planEvent` | Plan which snapshots an editing event (save, auto-save, restore, manual, discarded unsaved text, external change, before rename, before batch replace) records and under which reason |
| `history.rename` | Set or clear a user-visible label on a history entry |
| `history.delete` | Delete one history entry and its snapshot |
| `history.ignorePreview` | Validate local history ignore rules and report which rule skips a sample path |
| `history.usage` | Report one project's allocated history size and the storage cap |
| `history.clear` | Delete every snapshot of one project's history |
| `diff.compareTexts` | Compare two host-supplied texts line by line into paired side-by-side rows and unified lines |
| `maven.scan` | Parse a Maven project descriptor and recursively return modules/profiles |
| `maven.launchPlan` | Produce a deterministic Maven invocation from a versioned project context |
| `execution.resolveEnvironment` | Merge native `inherited` string values, selected `javaHome`/`mavenJavaHome` for the current `toolchain`, and `overrides` into `{ environment }`. `caseInsensitive: true` canonicalizes Windows keys to uppercase. Maven uses Maven JDK with project-JDK fallback; Java uses project JDK. String overrides win; structured `{ toolchain, property: "home" }` bindings use the current step's home for JAVA_HOME, and the named toolchain for other variables. Unknown bindings are omitted. |
| `execution.resolveSearchPath` | Preserve existing path precedence, sort platform candidates by priority and identity, and deduplicate using the requested case policy. |
| `execution.planLaunchCommand` | Move oversized Java path-list options into a JDK argument file |
| `processLifecycle.resolve` | Decide how each process or resource of one Lithe instance ends |
| `processLifecycle.inventory` | Group a process snapshot of one Lithe instance into terminals, Agent tasks and background services |
| `processLifecycle.settle` | Turn confirmation answers into what ends, what is kept and the updated settings |
| `maven.dependencyPlan` | Produce a bounded dependency-tree invocation for one Maven module |
| `maven.dependencies` | Normalize the bounded dependency-tree file one plan wrote into a deterministic tree |
| `maven.diagnostics` | Parse stable Maven compiler diagnostics from build output |
| `maven.testResults` | Parse bounded JUnit/Surefire result summaries and failure locations |
| `debug.createSession` | Create a transport-neutral DAP session and return its initialize frame |
| `debug.validateAdapterEndpoint` | Validate an IDE-to-DAP TCP endpoint and classify whether remote consent is required; performs no DNS or network I/O |
| `debug.transport.policy` | Return the default byte-stream deadlines, queue budgets and the session `initialize` deadline; creates no state |
| `debug.transport.handle` | Apply one platform event to an IDE-to-adapter byte-stream lifecycle and return the effects the platform runs next |
| `debug.transport.release` | Forget the lifecycle of a stopped byte stream once the platform dropped its handles |
| `debug.launch` | Queue a launch or attach request, including during initialization |
| `debug.javaTestLaunch` | Normalize JUnit or TestNG launch metadata into Java DAP arguments |
| `debug.steppingFilters` | Return adapter defaults or normalize portable stepping filters |
| `debug.relocateBreakpoints` | Move source breakpoints across one exact UTF-16 editor replacement |
| `debug.planVariablePage` | Plan the first bounded `variables` page of one scope or structured variable from its reported counts |
| `debug.reduceVariablePage` | Merge one returned variable page into its cursor and decide whether the container is exhausted |
| `debug.planDisassemblyWindow` | Plan the first `disassemble` request of the window around the instruction pointer or one listed edge |
| `debug.reduceDisassemblyPage` | Reduce one `disassemble` reply to the next bounded recovery request, a deduplicated page, or the adapter's failure |
| `debug.setBreakpoints` | Replace and deterministically order one source's DAP breakpoints |
| `debug.setExceptionBreakpoints` | Replace and deterministically order one session's exception filters |
| `debug.setFunctionBreakpoints` | Replace and deterministically order one session's named function breakpoints |
| `debug.dataBreakpointInfo` | Resolve an adapter-owned data breakpoint identity for a paused variable or field |
| `debug.setDataBreakpoints` | Replace and deterministically order one session's resolved data breakpoints |
| `debug.setInstructionBreakpoints` | Replace and deterministically order one session's machine-instruction breakpoints |
| `debug.setVariable` | Replace one visible variable value in its adapter-owned parent container |
| `debug.cancelOperation` | Cancel or time out one pending operation and ignore its late response |
| `debug.execute` | Submit continue, pause, next, step-in, or step-out control |
| `debug.inspect` | Request normalized threads, frames, scopes, variables, or evaluation |
| `debug.receive` | Reduce base64-encoded bytes received from a platform-owned DAP transport |
| `debug.runInTerminalResponse` | Complete one adapter-requested native terminal launch |
| `debug.disconnect` | Begin the DAP disconnect handshake without closing the native transport |
| `debug.destroySession` | Remove a session and its whole child tree after the platform closes its native transport; the response lists `destroyedChildSessionIds` (leaves first) whose transports the platform must also close |
| `lsp.applyTextEdits` | Apply LSP UTF-16 text edits with range validation |
| `lsp.plainSnippet` | Convert LSP snippet insert text into plain editor text |
| `lsp.builtinCompletions` | Return lightweight current-file identifier completions |
| `lsp.builtinHover` | Return lightweight current-symbol hover text |
| `lsp.builtinNavigation` | Return lightweight current-file definition/reference locations |
| `lsp.mergeCompletions` | Choose which candidates survive when several prioritized providers complete at one position |
| `lsp.activationPolicy` | Decide whether a language server may start automatically after failures, using a platform monotonic clock |
| `lsp.problems.query` | Filter, order, and group Problems tool-window diagnostics and count them by severity |
| `lsp.documentUri` | Convert a native absolute path into a canonical file URI |
| `lsp.startServer` | Start one Rust-owned process/session and begin initialization |
| `lsp.jdtWorkspaceKey` | Derive the deterministic JDT LS workspace-state directory key |
| `java.workspacePolicy` | Decide Java workspace activation and classify changed paths |
| `java.runMarkers` | Project JDT main/test discovery and canonical build test outcomes into editor Run markers |
| `java.jdtWorkspaceFingerprint` | Reduce platform build-file observations to the portable JDT LS workspace fingerprint |
| `java.jdtCacheRetention` | Select expired inactive JDT LS workspace-state keys from platform metadata |
| `lsp.stopServer` | Gracefully shut down a session, with a bounded force-stop fallback |
| `lsp.updateWorkspaceConfiguration` | Replace the plugin configuration a running plugin-owned session answers `workspace/configuration` with, and announce it |
| `lsp.updateMavenConfiguration` | Send a changed Maven context to a running Java session, or force JDT LS to re-resolve its Maven projects |
| `lsp.syncDocument` | Open a document or apply a full-text or incremental `didChange` with monotonic versions |
| `lsp.saveDocument` | Report a confirmed disk save with its exact saved text, honoring server save options |
| `lsp.workspaceFilesChanged` | Publish normalized created, changed, or deleted workspace files to one session |
| `lsp.closeDocument` | Close a document and clear its diagnostics |
| `lsp.request` | Submit a typed semantic request and return an opaque operation ID |
| `lsp.buildRequest` | Forward one planned `lithe/build/*` request to a session that negotiated the build-provider protocol |
| `lsp.functionRequest` | Invoke one registered plugin function on a session its plugin started |
| `lsp.hostResponse` | Answer one host-service request a plugin backend sent |
| `lsp.hostNotify` | Send one host notification to a plugin backend that negotiated it |
| `lsp.pluginServerRequest` | Send one request of a plugin backend to the plugin's own language server, under the plugin's declared session policy |
| `lsp.pluginServerNotify` | Send one notification of a plugin backend to the plugin's own language server |
| `lsp.configureFunctionRelay` | Replace the enabled plugins and live workspace contexts Core's plugin-to-plugin function relay checks calls against |
| `lsp.toolchainRequest` | Send one `toolchains/query` to a plugin backend that negotiated the provider |
| `lsp.keymapImportRequest` | Send one shortcut import request to a negotiated plugin provider |
| `lsp.vcsRequest` | Send one VCS operation, planned by Core, to a session that negotiated the VCS-provider protocol |
| `java.prepareLaunch` | Prepare a saved Java source through shared entry selection, serialized build and runtime path resolution |
| `java.navigationMarkers` | Resolve versioned Java gutter markers from bounded JDT LS semantic requests |
| `java.resolveNavigation` | Resolve one Java gutter marker to normalized parent or implementation locations |
| `lsp.cancelOperation` | Cancel one pending semantic operation |
| `lsp.pollEvents` | Drain ordered typed lifecycle/feature/diagnostic/result/log events |
| `lsp.waitEvents` | Block until queued events exist or a timeout elapses, then drain them |
| `lsp.clearDiagnostics` | Clear every diagnostic owned by a session |
| `lsp.snapshot` | Return a diagnostic runtime snapshot for testing and control surfaces |
| `lsp.destroyServer` | Remove a terminal session handle from the registry |
| `java.codeVision` | Return Java declaration usage counts for editor code vision |
| `java.className` | Resolve a Java source package and simple name into a runtime class name |
| `java.sourceDefinition` | Locate a Java type, method, or field declaration in source text |
| `java.serverPort` | Parse Spring server port settings from properties or YAML text |
| `java.structure` | Parse Java editor folds, inlay hints, and portable syntax roles |
| `spring.index` | Build a deterministic Spring configuration, bean, injection, and endpoint index |
| `mybatis.index` | Build a deterministic MyBatis mapper-interface and XML statement index |
| `runConfig.selectJava` | Select a project-compatible automatic JDK from platform-probed candidates |
| `runConfig.inspect` | Inspect `.lithe` run documents, versions, and staleness without writing files |
| `runConfig.projectToolchain` | Read saved project tool paths for one Provider root, with the nearest path override |
| `runConfig.generate` | Generate deterministic Java/Maven configurations and toolchain requirements |
| `runConfig.resolve` | Merge generated, project, and local layers and return diagnostics |
| `runConfig.selectContextConfiguration` | Choose a matching effective configuration for a provider-supplied source and entry identity |
| `runConfig.updateOptions` | Apply typed option edits and return an updated project or local document |
| `runConfig.updateToolPreferences` | Replace only generic preferences in a captured local Run document, preserving legacy defaults and unrelated metadata |
| `runConfig.argumentText` | Format a batch of exact argument vectors as reversible editor text |
| `runConfig.saveEditorChanges` | Prepare the local and optional project documents for one editor save |
| `runConfig.createUserConfiguration` | Validate a typed user configuration and return an updated document |
| `runConfig.createLaunchPlan` | Project one effective configuration into a platform-neutral Run or Debug plan |
| `git.repositorySetup` | Inspect repository/unborn state and scoped/effective commit identity; see `git-repository-setup.md` |
| `git.initialize` | Initialize a directory outside existing repositories without staging or committing |
| `git.configureIdentity` | Save or clear one local/global `user.name` or `user.email` override |
| `git.status` | Resolve the repository, current branch, and working-tree changes |
| `git.workspaceStatusMerge` | Plan publication of fresh, retained, and unavailable repository snapshots |
| `git.rollbackPlan` | Plan whole-file rollback from explicit Git status identities without reading or changing a repository |
| `git.rollbackPrepare` | Recheck selected identities against the repository and return rollback steps |
| `git.prepareCommitSelection` | Prepare and verify the real indexes for explicitly selected changes |
| `git.reconcileDeletedSelection` | Clear missing selected staged additions after filesystem deletion |
| `git.changelists` | Reduce local ChangeList metadata and project membership and commit scope |
| `git.commitMessageContext` | Capture bounded AI commit evidence and recheck its Git state |
| `git.untrackedDirectory` | List one level of a summarized untracked directory: its files and subdirectory summaries |
| `git.commitState` | Read exact HEAD, symbolic branch and index preconditions for a workspace commit |
| `git.watchContext` | Resolve the repository and absolute Git metadata roots needed by native file watchers |
| `git.classifyMetadataChanges` | Classify a bounded page of coalesced watcher paths without filesystem access |
| `git.worktrees` | Return deterministic registered-worktree metadata without scanning each checkout |
| `git.pullRequestContext` | Resolve worktree-aware PR branch defaults, publication state, and uncommitted-change state |
| `git.pullRequestCheckoutPreview` | Inspect and review a non-destructive PR checkout plan |
| `git.pullRequestCheckout` | Recheck and execute a reviewed PR checkout without resetting an existing branch |
| `git.command` | Execute one argument-based Git operation and return its arguments, streams, exit code, and ordered subprocess invocations |
| `git.repositoryRoot` | Resolve the repository root containing a workspace path without acquiring repository write coordination |
| `git.resolveFileContext` | Resolve a file to its owning Git checkout and relative path |
| `git.write` | Validate and execute shared Git mutations such as stage, commit, branch, checkout, remote sync, clone, and stash |
| `git.fetchPlan` | Validate Fetch choices; optionally inspect a repository to expand enabled per-remote commands |
| `git.consolePresentation` | Pure IDEA-style configuration/progress folds, empty-output notices and search ranges over retained diagnostic snapshots |
| `git.remoteUrl` | Read a configured remote URL silently; a missing remote returns a null URL |
| `git.executionInspect` | Inspect executable capabilities, configuration provenance and effective Fetch preferences |
| `git.executionConfigure` | Explicitly save or clear one allowlisted value in a selected config scope |
| `git.authRespond` | Answer or cancel a live authentication challenge once |
| `remote.probe` | Check that an SSH connection reaches a supported host |
| `remote.authRespond` | Answer or cancel a prompt relayed by `remote.probe` or `remote.connect` once |
| `remote.connect` | Open a connection, installing the shipped server when needed |
| `remote.readDir` / `remote.readFile` / `remote.writeFile` | List, read or save over an open connection |
| `remote.disconnect` | Close an open connection and its OpenSSH process tree |
| `remote.closeAll` | Close every open connection; the host calls it at application exit |
| `git.historyRewritePreview` | Review undo, message edit, squash, or drop with complete messages, eligibility, and an immutable checkout expectation |
| `git.historyActionCapabilities` | Read history menu hints from actual HEAD and the bounded first-parent chain |
| `git.rebasePreview` | Resolve the complete local linear range strictly after a selected unchanged base |
| `git.rebaseStart` | Start a reviewed native interactive rebase with persisted messages and recovery identity |
| `git.rebaseSession` | Read the latest owned rebase session and distinguish edit/conflict pauses from completion |
| `git.rebaseControl` | Continue, skip, or abort an identified session, optionally amending an edit pause |
| `git.diff` | Produce a structured working-tree, index, reference, commit, or stash patch |
| `git.parsePatch` | Parse a complete saved patch into Core-owned per-file documents |
| `git.apply` | Apply or check a patch in `stage`, `unstage`, `discard`, or Shelf restore mode |
| `git.planDiffBlocks` | Plan commit-review blocks for one file; Core owns every block patch |
| `git.applyDiffBlock` | Include, exclude or roll back one planned block under the write lease |
| `git.stageGutterChange` | Stage one editor gutter change with its original bytes |
| `git.history` | Return the legacy combined reference snapshot and first bounded commit page |
| `git.references` | Return deterministic refs, recent local branches, ahead/behind state, and effective Git identity without scanning commit history |
| `git.remotes` | Return configured fetch remote names and URLs |
| `git.tags` | Return tag names, tag object IDs, target IDs, dates, and annotations |
| `git.parseCheckoutMetadata` | Interpret bounded HEAD text without filesystem access |
| `git.parseGitdirPointer` | Interpret a bounded gitdir pointer without filesystem access |
| `git.historyPage` | Return one bounded commit page, author date, UTC offset, optional Unix timestamp, and an opaque continuation cursor |
| `git.historyQuery` | Compare bounded commit date identities with explicit absolute time bounds |
| `git.historyCursorClose` | Release an unfinished incremental history cursor and its Git process |
| `git.historyLocate` | Append bounded history pages until one commit is found and report the budget, window cursor, and exhaustion |
| `git.branchNamePreview` | Clean and validate a new branch name against already loaded references without running Git |
| `git.repositoryColorAssignments` | Assign color slots to a bounded page of ordered repository identities |
| `git.pushPreview` | Resolve a local branch push destination and the bounded commits not present on that remote base |
| `git.commit` | Return one structured commit by revision with its full message body |
| `git.commitFiles` | Return files changed by one commit |
| `git.comparison` | Return files changed between a reference and the working tree |
| `git.stashes` | Return structured stash references and messages |
| `git.checkoutPreflight` | Return local paths that would block switching to a reference |
| `git.pullPreflight` | Report the configured upstream, ahead/behind counts, divergence, tracked local changes, and the strategy Git is configured for, without fetching |
| `git.updatePlan` | Route a branch Update and gate a Pull from facts the host collected: blockers, strategy default, whether to ask, and the expected checkout |
| `git.historyWindow` | Plan a history refresh window, page merge, and selection retention over commit identities |
| `git.graphProjection` | Project a loaded history window into commit-graph lanes, color IDs, routes, print elements, and labels, optionally filtered |
| `git.integrationPreflight` | Return local paths that block a merge, rebase, cherry-pick, or revert |
| `git.conflictMarkers` | Return staged text files that still contain conflict markers |
| `git.operationState` | Report an interrupted merge, rebase, cherry-pick, or revert and its conflicted paths |
| `git.blame` | Return structured line blame metadata |
| `git.lineHistory` | Trace which commits touched a one-based snapshot line range of one file |
| `github.parseRemote` | Parse a canonical GitHub HTTPS or SSH remote into owner/name |
| `github.requestPlan` | Validate one GitHub operation and produce a trusted platform HTTP request plan |
| `github.normalizeResponse` | Normalize raw GitHub JSON and HTTP status into deterministic data or a stable error |
| `github.deviceAuthorizationTransition` | Plan the next device-authorization action, polling interval, and deadline-bounded wait |
| `github.pullRequestCheckoutPlan` | Plan a PR's safe local branch and report an existing-ref conflict |
| `diagnostics.prepareLogEvent` | Normalize a bounded application event and recursively redact structured fields |
| `diagnostics.queryLogs` | Merge and filter bounded host-collected module log tails |
| `diagnostics.encodeLogBatch` | Encode independent structured v2 log events with per-item errors |
| `diagnostics.parseLogFilter` | Parse bounded filter expressions and UTF-16 diagnostic ranges |
| `diagnostics.composeLogFilter` | Compose a filter predicate preserving unrelated terms |
| `diagnostics.formatLogRecords` | Validate and format canonical redacted records for copying |
| `diagnostics.queryLogsV2` | Query structured v2 and legacy v1 native log tails |
| `diagnostics.planLogCollection` | Plan bounded native log-tail reads from raw file metadata |
| `diagnostics.planLogRetention` | Plan log cleanup from host-owned file inventories |
| `diagnostics.resolveEngineLogSubject` | Resolve the same routing segment and channel used by engine startup, without I/O |
| `diagnostics.resolveLogChannel` | Validate channels and resolve safe session-relative destinations |
| `diagnostics.drainCoreEvents` | Atomically take process-owned Core log facts and their dropped count |
| `diagnostics.configureCoreEvents` | Set the DEBUG admission gate for Core log facts from host detailed-diagnostics state |
| `diagnostics.redactText` | Redact credentials, tokens, and home-directory paths from diagnostic-bundle text |
| `diagnostics.buildManifest` | Shape a deterministic diagnostic bundle manifest from host-gathered environment and file facts |
| `plugins.declarative.validate` | Validate and normalize a declarative plugin manifest (plugin contract v1) |
| `plugins.declarative.runPlan` | Expand a declarative plugin's run template for one workspace file |
| `plugins.declarative.discoverTests` | List a declarative plugin's workspace and file test items |
| `plugins.declarative.testPlan` | Expand a declarative plugin's test template for a workspace, file, or test case |
| `plugins.declarative.languageServerLaunchPlan` | Expand a declarative plugin's language-server, build-provider, VCS-provider, backend, or debug-adapter launch with host directories and architecture |
| `plugins.languageServers.decodeLaunch` | Bound the answer of a plugin backend that resolved a language server's launch and return the plan the host starts |
| `plugins.languageServers.stateRetention` | Choose which inactive per-workspace state directories of a plugin language server the host deletes |
| `plugins.contentProviders.decode` | Bound the answer of a plugin content provider function and return the document text |
| `debug.adapters.startArguments` | Check one debug start against a plugin's `debugAdapters[]` entry and return its DAP launch arguments |
| `debug.adapters.executablePlan` | Say where to look for the program a launch debugs: the user's setting and the adapter's candidate paths |
| `plugins.declarative.resolveSettings` | Merge a plugin's stored global and project setting layers into effective values with their source |
| `plugins.declarative.workspaceConfiguration` | Expand a language server's `workspaceConfiguration` with the merged setting values |
| `plugins.declarative.checkRuntimeVersion` | Decide whether a launch runtime's version output meets the declared minimum version |
| `toolchains.registry` | Revalidate complete enabled plugin manifests, `{plugins:[{manifest}]}`, into a deterministic tool-definition/provider registry; the host supplies no origin evidence. A short tool ID defined by several enabled plugins belongs to none of them: none of those definitions is registered, the rest register as usual, and `conflicts: [{tool, pluginIDs}]` (sorted by tool, `pluginIDs` sorted) reports each contested tool. A repeated plugin ID rejects the batch. No native host capability claim |
| `toolchains.decodeReply` | Validate an inert toolchain query/reply pair against bound provider identity, generation, declared tools and host-native filesystem evidence; no transport or native I/O |
| `toolchains.failureReply` | Build the JSON-RPC error reply for a query that missed its deadline or found no backend, so the host passes it to `toolchains.decodeReply` like a provider's own error; cancellation has none |
| `toolchains.resolvePins` | Validate a captured local document and find the nearest ancestor directory pin, retaining dormant and legacy entries without probing or writing |
| `toolchains.resolveConsumerPreferences` | Validate an inert consumer preference document and resolve one tool's explicit Run, consumer, directory or workspace choice while keeping workspace/consumer inheritance symbolic; no native files or launch authority |
| `toolchains.editConsumerPreferences` | Edit or reset one exact consumer/directory tool preference; return the document and effective input without native writes |
| `toolchains.resolve` | Resolve the fixed/project/global/automatic layers from one generation-bound snapshot, retaining unmet requirements, unavailable providers with their cause, conflicts and terminal fixed-value failures |
| `toolchains.checkVersion` | Match captured output with an enabled plugin definition's version expression and compare generic numeric components with an optional minimum; never starts a probe |
| `toolchains.instantiateLaunch` | Expand an enabled tool definition's `launch` template for a selected executable, entry, runtime arguments and arguments; a part the template cannot carry is `plugin.toolchain.launchMismatch`; performs no I/O |
| `toolchains.discoveryPlan` | Return platform-filtered definition-owned scan declarations, layouts, probes, PATH entries, login-shell home variables and budgets; never scans native directories |
| `toolchains.candidates` | List one tool's login-shell homes and host-scanned installations with checked executables, versions or skip reasons, and the automatic-layer choice; never starts a probe |
| `plugins.declarative.decodeGrammar` | Validate independent static editor resources (`languages` 2) |
| `plugins.editorActions.decode` | Validate independent action registration, collection or click results |
| `plugins.hostApi.describe` | Describe backend host methods and their required grants from Core's method table |
| `plugins.hostApi.authorize` | Check a method, service and current session grants using Core's capability rules; the host still checks session and resource ownership |
| `plugins.editorProviders.decode` | Validate editor provider registrations and provider function results |
| `run.decodeStart` | Validate a plugin backend's `lithe/host/run/start` params against its manifest and the workspace, and return the normalized start with temporary-file paths substituted |
| `debug.decodeBackendConfiguration` | Validate a plugin backend's `lithe/host/debug/start` params against its manifest and return the qualified adapter, request, label and configuration |
| `outputLinks.match` | Find the links plugin `outputLinkMatchers` declare in Run or Test console lines, as UTF-16 ranges with candidate paths or a backend function to resolve them |
| `outputLinks.decodeResolution` | Check a matcher's `resolve` function reply and return the 1-based file location to open, or `null` |
| `build.detect` | Find every build-system instance the enabled plugins declare in a workspace, with models that need no process |
| `build.resolveStoredOptions` | `{ document, local: { version: 1, document, emptySelections?: { <systemID>: { <root>: [optionID] } } } }`, without a manifest | `storage: { document, local, emptySelections }`: checked team/local merge; local values override matching keys, unrelated systems/roots/choices stay intact. No filesystem I/O. Local documents are machine/workspace preferences, not team files or plugin-native configuration. Their storage syntax is [build-local-options-v1.schema.json](build-local-options-v1.schema.json), with additional cross-field membership and byte limits checked by Core. |
| `build.editStoredOption` | `{ document, local, root, optionID, value, modelValues? }` in the standard manifest/build-system envelope | `edit: { local, options }`: changes one declared local preference. `null` removes the local override and restores team/declaration inheritance. Invalid or partially accepted edits reject before persistence. Workspace multi-selections preserve sibling-only values; explicit per-root empty markers apply only to workspace multi-select declarations. Platforms compare both native source revisions, atomically write only the local document and read back. |
| `build.invocationPlan` | List a build system's executable candidates, runtime dependencies, and version probe for one platform |
| `build.checkToolVersion` | Decide whether a build tool's or runtime's version output meets the declared minimum |
| `build.resolveModelInputs` | Validate enabled producer facts and project a bounded public model snapshot for a declared consumer |
| `build.resolveOptions` | Check stored build options against the declaration and return effective values, choices, and the fingerprint |
| `build.configurationPlan` | Plan a read of the provider's non-sensitive native configuration (v7) |
| `build.decodeConfiguration` | Validate native source identities, raw/effective values and XML bindings |
| `build.configurationEditPlan` | Plans format-independent provider editing into private host staging |
| `build.decodeConfigurationEdit` | Validates the receipt without native document bytes |
| `build.modelPlan` | Expand the command that prints a command-sourced build model, or the request a build provider answers |
| `build.taskPlan` | Expand one declared or model task for a workspace, project, or target |
| `build.testPlan` | Plan a test run for a scope, suite, or case and say where its reports will be |
| `build.testDiscoveryPlan` | Plan opt-in Provider test discovery for an instance |
| `build.decodeTestDiscovery` | Validate, deduplicate and order Provider test selectors |
| `build.prepareRunPlan` | Plan Provider-owned application/service/task preparation from a model target |
| `build.decodeRunPreparation` | Validate portable launch data before the native Run host starts a process |
| `build.prepareDebugPlan` | Plan same-plugin native debug preparation (Provider v5) |
| `build.decodeDebugPreparation` | Validate an existing instance-contained native debug program and bounded process facts |
| `build.dependencyPlan` | Expand the command that prints a project's dependency tree, or the request a build provider answers |
| `build.decodeModel` | Decode model output or a provider result into projects, targets, tasks, content roots, option values, and run entries |
| `build.decodeTestResults` | Decode a test run's reports and output into per-case results and a summary |
| `build.decodeDiagnostics` | Decode build output into workspace file diagnostics |
| `build.decodeDependencies` | Decode dependency output or a provider result into one project's bounded tree |
| `build.syncFingerprint` | Digest the files a build model depends on, to tell whether it is stale |
| `build.languageImport` | Map a build system's options to the Java language server's Maven or Gradle project import |
| `build.resolveTestRunOutcome` | Reduce a test run's termination, selected scope and decoded summary to one tool-neutral verdict |
| `build.mergeTestOutcomes` | Merge a run's test result ids into the stored history inside the host-stated id/prefix scope |
| `vcs.detectRoots` | Find the VCS roots of a workspace from static markers, with registered providers, ambiguous directories, and applied mappings |
| `vcs.ownerOf` | Assign workspace paths to the detected root that owns each |
| `vcs.decodeReply` | Validate a VCS provider's reply and return the normalized result |
| `project.generatorCatalog` | List the project generators of the given plugins, with the plugins that provide each requirement |
| `project.generatorForm` | Evaluate a generator's form: derived defaults, visibility, problems, and active requirements |
| `project.generationPlan` | Expand a filled-in form into the files, commands, and archive downloads that create a project |
| `project.checkName` | Check that a name can be a new project's directory name |
| `project.extractArchive` | Extract a downloaded project archive into the staging directory, refusing unsafe entries |
| `plugins.marketplace.validateIndex` | Validate a marketplace index and report each plugin's availability for one platform |
| `plugins.marketplace.resolveSource` | Resolve a user-entered marketplace source to the index URL to fetch |
| `plugins.marketplace.installReview` | List a package's permissions and programs, and those not yet approved |

### Maven test results

`maven.testResults` accepts `{ "root": string, "output": string }` and parses
the bounded text emitted by Maven Surefire or Failsafe after a JUnit 4/5 class
or method run. `root` must be an existing workspace directory and `output` is
limited to 500,000 characters. The response is:

```json
{
  "testsRun": 4,
  "failures": 1,
  "errors": 1,
  "skipped": 1,
  "passed": 1,
  "success": false,
  "failureDetails": [
    {
      "name": "additionIsCorrect(com.example.CalculatorTest)",
      "kind": "failure",
      "message": "expected <4> but was <5>",
      "path": "src/test/java/com/example/CalculatorTest.java",
      "line": 42,
      "column": null
    }
  ]
}
```

`kind` is `failure` or `error`; `path` is a workspace-relative source path
when a stack frame or failure footer can be resolved unambiguously. Relative
source lookup requires a complete workspace index, prefers a unique full
package-path suffix at a path boundary, and falls back to a unique filename
only when no package-path candidate exists. Ambiguous matches or an incomplete
scan (including the 10,000-directory limit) leave the location `null`.
All locations use one-based lines with nullable columns. `passed` is derived from the summary and never
negative. A final `Results` summary is preferred; when Maven only prints
per-class summaries, the counts are aggregated. Failure details retain Maven's output order and are bounded to
10,000 entries. A parser or size violation returns the standard
`parse_failed` error.

The request may also carry `reports: { module, sourcePath, classes,
notBeforeMillis }` naming the run's workspace-relative Maven module directory
(`null` or `.` for the root), the binary names of the selected test classes, and
the run's start time in Unix milliseconds. When `module` is absent and
`sourcePath` names a workspace-relative test file, the module is the nearest
directory above that file holding a `pom.xml`. An empty or absent `classes`
reads every report in the module written at or after `notBeforeMillis`. Core then reads the Surefire/Failsafe XML reports
the run wrote and returns `testCases`, otherwise an empty list:

```json
{ "className": "com.example.CalculatorTest", "method": "additionIsCorrect",
  "status": "failed", "message": "expected <4> but was <5>", "invocations": 1,
  "durationMillis": 23 }
```

Optional `durationMillis` comes only from each XML testcase's `time` seconds attribute. Repeated/parameterized invocations sum their times in whole milliseconds; if any invocation has a missing, negative, non-finite, unrepresentable time or the sum overflows the host integer range, the field is omitted. A reported zero is valid. Hosts hide missing method durations and must not substitute a console/suite summary or another class's method time. `build.decodeTestResults` preserves the same duration in its canonical testcase result.

Reports are searched in the module's configured Surefire/Failsafe
`reportsDirectory` values plus `<build directory>/surefire-reports` and
`failsafe-reports`. Only `TEST-<class>.xml` and nested `TEST-<class>$*.xml`
files modified at or after `notBeforeMillis` are read, so an earlier run's
reports never produce outcomes. `method` drops parameter lists and invocation
indexes; invocations that report a display name instead of a method are
omitted. `status` is `passed`, `failed`, `error`, or `skipped`; when a method
has several invocations, the most severe wins (error, failed, passed, skipped)
and `message` comes from the first invocation with that status. Results are
ordered by `className`, then `method`. Core reads at most 512 reports of up to
32 MiB each and returns at most 10,000 methods; malformed reports are skipped.
A module outside the workspace or a class name that is not a Java binary name
returns `invalid_request`. A class with no case means "no recorded outcome",
never "passed". Platform stores must associate the response with the
launch operation and discard it after cancellation, replacement, or workspace
change.

Workspace paths in responses are relative and use `/` separators. Line numbers
are one-based. `git.status.repositoryRoot` may be an absolute path when the
opened workspace is a subdirectory of the repository; all Git change paths are
relative to that repository root. `git.status.ahead` and `behind` report the
current branch's tracking counts and are zero when no upstream is configured.
`workspace.recentProjects.reduce` accepts `{ entries, action, capacity? }` and
returns `{ entries, added, removed }`. Entries are `{ path, lastOpenedAt, pinned }`
where `path` is the host's normalized root identity compared byte for byte and
`lastOpenedAt` is non-negative Unix milliseconds from the host clock (missing
means oldest). `action.kind` is `record { path, openedAt }` (moves the project
first and keeps its pin), `remove { paths }`, `togglePinned { path }` (unknown
paths are ignored), `import { paths, openedAt }` (adds only unlisted paths, the
first stamped `openedAt` and each later one a millisecond older), or `normalize`.
Core keeps the newest record of duplicated paths, orders pinned projects first
and then by descending `lastOpenedAt` with ties in caller order, and keeps at
most `capacity` unpinned projects (default 20, range 1–200); pins never count
against it. `added` and `removed` list paths the reduction introduced or dropped
so hosts attach or discard their own metadata (names, icons, branches). Empty,
NUL-containing or over-4,096-byte paths, negative times and out-of-range
capacities return `invalid_request`. Hosts own persistence and which roots are
worth recording; menus may show fewer rows than are retained. See
`shared/fixtures/workspace/recent-projects-v1.json`.

`workspace.repositories.repositories` is ordered with the containing workspace
repository first when present, then repositories under the opened workspace by
workspace containment, depth, and path. Each entry contains an absolute native
`path` because repository roots are platform boundary values and may be outside
the opened folder when the folder is nested inside a checkout. Canonical paths
are reported in plain native form: Core strips the Windows verbatim `\\?\`
prefix only for supported drive/UNC paths so roots remain valid Git working
directories after consumers normalize separators. On Windows, path components
ending in an ASCII dot or space, reserved DOS device basenames, verbatim dot
segments, and non-drive/non-UNC device namespaces are
unsupported: discovery, status, watch context and Git reads return
`invalid_request` before filesystem lookup, rather than aliasing another path.
The same validation applies after canonicalization and to Git-reported paths;
missing-worktree fallbacks must not suppress it. Frontend file resolution
normalizes native UNC/verbatim inputs before deciding whether to join a repository
root, and rejects unsupported names before stripping their prefix. Remote/WSL
identifiers retain their protocol and POSIX name semantics. Chinese names,
embedded spaces and long paths are not rejected by length; native Git/filesystem
errors remain visible. In particular, Windows may reject an over-MAX_PATH Git
working directory at process creation even when filesystem lookup succeeds;
this is reported as `process_start_failed`, not a missing repository. Shared examples live in `shared/fixtures/git/windows-paths.json`.
Core treats both
`.git` directories and `.git` files as repository markers, but a marker only
becomes a listed repository when Git can open it: a `.git` directory needs
`HEAD`, and a `.git` file must resolve to a gitdir (absolute, or relative to
the marker's directory) that exists and holds `HEAD`. A stale submodule or
worktree pointer whose gitdir was removed is not listed, because status and
reference loads for the whole workspace would otherwise fail for it. The default traversal
skips dot-prefixed descendant directories and the built-in workspace hidden
directory names (including `.build`, `node_modules`, `.venv`, `venv`, `__pycache__`,
`target`, `build`, `DerivedData`, `dist` and `coverage`). `.worktree` and `.worktrees` remain
traversable checkout containers; the same exclusions apply inside them.
Traversal continues below eligible discovered repositories, including ordinary
`vendor` source checkouts. An explicitly opened root and its containing repository
are never excluded by their names. These are automatic discovery rules, not Git
tracking rules: `.gitignore` and file-tree visibility overrides do not configure
repository ownership. The rules apply before repository status/reference
aggregation on both hosts. Examples live in
`shared/fixtures/workspace/repository-visibility-v1.json`.
Git metadata itself is not traversed.
Symbolic directory links are not followed, preventing cycles and traversal
outside the workspace. Callers may explicitly supply `maxDirectories` and
`maxDepth` to request a bounded scan; product consumers omit these limits.
Traversal checks cancellation between directories and entries.
`git.worktrees.worktrees` is ordered with the primary worktree first and then
by path. Each entry contains `path`, `head`, nullable `branch`, `isCurrent`,
`isPrimary`, `isBare`, `isDetached`, `isLocked`, nullable `lockReason`,
`isPrunable`, and nullable `pruneReason`. The path is absolute because linked
worktrees may live outside the opened workspace; clients must treat it as an
opaque native boundary value and must not persist it as a portable identifier.
Core reads the list with one porcelain operation and does not run status in
each checkout.
For a rename or copy, each change uses the destination as `path` and preserves
the source as `originalPath`; platform mutations that act on the Git entry pass
both paths back to Core.
The core rejects absolute paths and `..`
traversal for file commands. Native file dialogs, file watching, PTY/ConPTY,
Java processes, and runtime discovery remain platform adapters.

`git.history.recentReferences` contains at most five existing local branches in
most-recently-used order. The current branch is first. Core derives checkout
history from the repository's HEAD reflog, de-duplicates branch names, ignores
detached or deleted references, and fills missing entries deterministically.
The remote HEAD target is preferred as the default branch, followed by `main`,
`master`, and the remaining local references in refname order.

The protocol version is currently `1`. Add a fixture under `shared/fixtures/`
before changing a response shape or search rule.

`document.lifecycle` accepts a discriminated `state` (`clean`, `dirty`,
`saving`, or `conflict`) and one typed `event`. It returns the next state plus
one platform effect such as `writeToDisk`, `reloadFromDisk`, or
`showConflict`. `saving` carries the snapshot revision and `operationId`, so a
stale completion cannot clear newer edits. Live text, editor models, selections,
watchers, and native file I/O stay platform-owned; local keystrokes update the
same revision semantics in-process and never cross the Rust boundary.
`diskConflict` preserves the current editor revision and enters `conflict` from
any state when a native guarded write rejects its expected disk baseline or a
file is missing. Native document saves compare the last acknowledged raw disk
bytes with disk inside the platform write operation; the editor may use UTF-8,
UTF-8 with BOM, UTF-16 LE/BE (with or without BOM), GBK, GB18030, Big5, Shift JIS, EUC-JP, EUC-KR, Windows-1250/1251/1252, or KOI8-R while the Core
lifecycle remains encoding-agnostic. Watchers are refresh hints, not write
authorization. Conflict resolution acknowledges only the disk snapshot
observed by the user, and subsequent saves must validate that snapshot again. The
portable examples are in `shared/fixtures/documents/lifecycle-v1.json`.

`document.planSaveBatch` accepts `{ documents }`, where each open document is
`{ id, dirty, readOnly, contentSynchronized }`, and returns `{ members }` in
request order. A writable document takes part when it is dirty, or when
`contentSynchronized` is false because its editor view may still hold input
that the platform model has not received. `document.reduceSaveBatch` accepts
`{ members, results, documents }`: one `{ id, outcome }` result per member
(`saved`, `failed` or `cancelled`) and the live documents observed after every
write finished. It returns `{ status, savedCount, failed, cancelled,
remainingDirty }`. `status` is `cancelled`, `failed`, `incomplete` or `saved`,
in that precedence; any live dirty document, including one dirtied or opened
while the batch ran, keeps the batch `incomplete`. Platforms attempt every
member (sequentially or concurrently) instead of stopping at the first failure,
and own dialogs and failure notifications. Duplicate or empty identities,
missing or extra results, and more than 10,000 documents are `invalid_request`.
See `shared/fixtures/documents/save-batch-v1.json`.

GitHub command shapes, authorization behavior, and supported pull-request
operations are documented in [`github.md`](github.md). Rust Core performs no
network or credential I/O for these commands.

`community.discourse.auth.begin` accepts an HTTPS `origin`, stable `clientId`,
user-visible `applicationName`, platform-owned `authRedirect`, and a non-empty
array of supported `scopes`. It returns an opaque `flowId`, an
`authorizationUrl` that requests RSA-OAEP padding, and an `expiresAt` Unix
timestamp. The private key and nonce remain in Rust memory and expire after ten
minutes. `community.discourse.auth.complete` accepts that `flowId` and the full
`callbackUrl`; it consumes the flow, verifies the callback target, decrypts the
payload, and checks the nonce before returning `userApiKey` and `apiVersion`.
Platform hosts open the browser, receive their registered URL scheme, and store
the returned credential in Keychain or Windows Credential Manager. They do not
implement Discourse cryptography or callback validation.

The authenticated community commands accept `origin`, `userApiKey`, and
`clientId` plus their operation-specific fields. Rust owns HTTPS requests,
authentication headers, a 30-second request timeout, a 5 MB response limit,
Discourse JSON decoding, deterministic post ordering, and HTML sanitization.
Platform clients never issue a parallel Discourse request or parse a second
response shape. Credential vault reads and writes remain native adapters; the
credential is passed to Core only for the duration of one command.

`git.watchContext` accepts `{ "root": string }`. When `root` is not inside a
Git repository, it returns `null`. Otherwise it returns
`{ "repositoryRoot": string, "gitDirectory": string, "gitCommonDirectory": string }`;
all three fields are absolute filesystem paths.

`git.pullRequestContext` accepts `{ "root": string }` and returns
`currentBranch`, `suggestedBaseBranch`, `suggestedPublishBranch`,
`requiresPublish`, `detached`, and `hasUncommittedChanges`. For detached
worktrees, Core uses the worktree HEAD reflog's oldest commit and refs pointing
at that commit to suggest the branch from which the worktree started. For a
named branch, `requiresPublish` remains true until its current HEAD is present
on the same branch under `origin`, because GitHub repository identity is also
resolved from `origin`.

`git.command` accepts `{ "root": string, "arguments": string[], "input": string? }`.
Arguments are passed directly to the Git executable without a shell. A
successful process launch returns `{ "arguments": string[], "output": string,
"stdout": string, "stderr": string, "exitCode": number, "invocations":
GitCommandInvocation[], "operationError": CoreError? }` even when Git exits
non-zero. `GitCommandInvocation` is `{ "arguments": string[], "stdout": string,
"stderr": string, "exitCode": number }`. The top-level `arguments`, streams,
and exit code always equal the final invocation for compatibility, and `output`
is that invocation's `stdout` followed by `stderr`; `invocations` records every
subprocess in execution order. Validation, process-start, and workspace failures
that occur before Git starts use the standard error envelope. If a follow-up
validation or probe fails after at least one subprocess was recorded, the
response retains the invocation trace and includes the failure as
`operationError`.

`git.workspaceStatusMerge` accepts ordered `roots`, `previousRoots`, and one
`{ root, success }` outcome per root. It returns ordered entries with source
`current`, `previous`, or `missing`, plus `confirmedRoots` and `failedRoots`.
A failure is never a clean snapshot; a previous snapshot is retained only for a
still-discovered root. Duplicate, foreign, or incomplete outcomes are rejected.
Hosts keep the actual snapshots and publish the plan only if its request version
and workspace identity remain current. Failed roots must not confirm pending Git
mutations or erase their open diff; their displayed data is marked as potentially
stale. No status data or credentials are persisted by the planner.

`git.repositoryRoot` accepts `{ "root": string }` and returns the normalized
absolute repository root or `null` when the path is not inside a repository. It
is read-only and does not acquire the repository write lease.

`git.resolveFileContext` accepts `{ "root": string, "path": string }` and returns
`{ "root": string, "path": string, "ownership": "git" }` or `null` for a
file outside Git. A relative path is anchored at the existing root; an absolute
file may belong to a different checkout. Core discovers the deepest actual Git
checkout, including nested repositories and linked worktrees. Missing parent
directories are resolved from the nearest existing directory, while symlinked
parents are resolved on the owning host and the final filename is not followed.
Parent traversal components and unsupported Windows path identities are rejected.
Errors are not treated as a reason to use the active repository. The command is
read-only, observes the remote workspace IO boundary, and does not cache ownership.
Windows `remote://` and `wsl://` URI adapters retain their existing host routing.

`git.command` and typed Git writers share the repository's write lease, including
linked worktrees. A competing request fails with `invalid_request` while a writer
is active; it does not wait behind a mutex outside its cancellation deadline.

Git requests may include optional envelope metadata `gitExecution`:
`{ executable?: string | null, interactive?: boolean, useCredentialHelper?: boolean,
fetchDefaults?: GitFetchOptions, detailedFetch?: boolean, source?: "user" | "background" | "unknown" }`. Defaults are PATH,
noninteractive, helper enabled, normal Fetch defaults, and legacy Fetch results.
An executable must be an absolute native path to Git 2.31 or newer. Interactive
commands require an event receiver. These values are request-scoped, including
nested requests, and never implicitly persist. Both current applications opt
into detailed Fetch and supply their application settings snapshot.

`git.fetchPlan` accepts `{ options?: GitFetchOptions, root?: string }`. Options are
`{ remote?: string | null, prune?: boolean, submodules?: "inherit" | "no" |
"onDemand" | "yes", tags?: "inherit" | "all" | "none" | "prune" }`. It returns
`{ options, arguments, commands?: string[][] }`. Without `root` the operation is
pure. With `root`, commands expand into sorted enabled remotes, using the same
resolver as detailed execution. `remote.<name>.skipFetchAll` is respected when
fetching all remotes, using Git's boolean parser: a valueless key is true, an
explicit empty value is false, and nonzero numbers are true. Invalid boolean
values fail preflight rather than silently enabling a remote. A selected name
must exist; URLs and argument text are not
accepted as remote names. An empty enabled set is an explicit error.

Defaults are all remotes, pruning enabled, and inherited submodule/tag policy.
Tag modes map to no override, `--tags`, `--no-tags`, or `--prune-tags`; tag pruning
requires `prune: true`. `git.write` with `operation: "fetch"` accepts optional
`fetchOptions`. Supplied one-time values override repository `lithe.fetch.*`
preferences, which override `gitExecution.fetchDefaults`. Unknown fields and
Fetch options supplied to another mutation are rejected. With `detailedFetch`,
individual remote errors preserve partial successes and an `operationError`
summarizes failure; legacy clients retain one `fetch --all` invocation.

All captured non-config invocations get named temporary presentation policy
through appended `GIT_CONFIG_COUNT` entries: `color.ui=false`,
`core.quotepath=false`, `log.showSignature=false`. Helper reset is appended only
when the supplied preference disables helpers or an explicit authentication
retry selected it. Config commands are exempt so provenance is not obscured.
Fetch's existing explicit flags remain in the argument vector for compatibility.
`LC_ALL=C`, pager suppression and no terminal prompting are child-local policy.
Transfer progress is requested explicitly. No config file is implicitly modified.

`git.remoteUrl` accepts `{ root, remote }` and returns `{ url: string | null }`.
It uses the internal configuration-read path: a missing key is successful and
produces no command row. Invalid requests and real access/executable failures
remain structured errors. The configured value is used for repository discovery;
it is not console output. See `shared/fixtures/git/remote-url-v1.json`.

`git.executionInspect` takes `{ root, scope?: "local" | "global" }`, default local.
It returns `{ executable, version, scope, entries, fields, temporaryConfig,
fetchOptions, fetchError, fetchSources, resolvedFetchBehavior, credentialHelperEnabled,
interactiveAuthentication }`. Entries are `{ key, value, scope, origin, effective }`
in Git precedence order, limited to relevant configuration and redacted. Effective
`fetch.prunetags` and `remote.<name>.prunetags` entry values use Git's boolean
parser and return canonical `"true"` or `"false"` for valid spellings (including
valueless assignments); invalid values remain inspectable as their redacted raw
text. Fields are `{ key, choices: string[], configuredValues: string[] }` from
the selected file without expanding includes. `configuredValues` retain the raw
values for optimistic edit checks, even when an effective entry is normalized.
Fetch source values are `{ scope, origin }` per preference; application sources have null origins. Invalid repository
preferences return null `fetchOptions` and a structured `fetchError`.
`resolvedFetchBehavior.tags` is `{ value, source, basis, reasonCode }`, or the
whole `resolvedFetchBehavior` is null when Fetch options cannot be resolved.
The value is `reachable`, `all`, `none`, `prune`, `custom`, `remoteDependent`,
or `unavailable`. `source` is an optional `{ scope, origin }`, `basis` is `git`
`lithe`, or `multiple` when no single source explains all remotes; `reasonCode` distinguishes `noRemotes` from
`invalidConfiguration`. Repeated `remote.<name>.fetch` entries remain additive.
Git's explicit tag refspec and `pruneTags` may fetch tags even with `--no-tags`;
partial or negative tag refspecs are reported as `custom` rather than guessed.
All occurrences of relevant boolean settings are checked with Git's parser so
an invalid shadowed value is not silently interpreted as valid. Inputs and
outputs are illustrated by `shared/fixtures/git/fetch-behavior-v1.json`.

`git.executionConfigure` adds `{ key, value: string | null, expectedValues:
string[] }` to the same request. It permits `fetch.prune`, `fetch.prunetags`,
`fetch.recursesubmodules`, `pull.rebase`, `pull.ff`, `push.default`,
`credential.usehttppath`, and local-only `lithe.fetch.prune`,
`lithe.fetch.submodules`, `lithe.fetch.tags`, using the advertised choices.
Null removes the selected file's override. An optimistic expected-values check
rejects a detected intervening edit, then one Git config transaction runs under
Lithe's repository write lease. It is not an atomic CAS against external writers.
The returned snapshot reflects the saved state. No arbitrary script/argument
setting is editable through this command.

`git.authRespond` takes `{ requestId: string, answer: string | null }` and returns
`{ accepted: boolean }`. Opaque IDs are invocation-owned, unguessable and single
use; stale or invalid answers return false. Answers are bounded to 8 KiB without
NUL/newlines. Null cancels the challenge. Hosts also cancel its owning operation
when the user cancels the dialog. An event with `retry: true` requires the exact
answer `"retry"` to repeat the failed transfer with helper bypass, at most three
total attempts. The AskPass C ABI is called only in the child app's early helper
mode. Credential answers are never copied into events or settings.

See `shared/fixtures/git/{fetch-plan,execution-events,execution-policy}-v1.json`
and [Git execution and project console](../../.agents/notes/implemented/architecture/2026-09-12-git-execution-and-project-console.md).

The additive `lithe_core_execute_json_with_events(request, callback, context)`
C ABI and Rust `execute_json_with_events` API deliver sanitized Git diagnostics
while the existing synchronous request runs. Event strings are borrowed only
for the callback; clients must copy them before returning. Callbacks are serial
on the caller's worker thread and complete before the final response returns.
Callbacks may synchronously call Core, for example to answer `git.authRespond`.
Nested requests do not inherit the outer observer; they can install a separate
observer explicitly. Returning from a nested request restores the outer request's
event identity, cancellation registration, and absolute deadline.
No arbitrary environment values, authentication answers or command stdin are emitted.
The named nonsecret temporary configuration is explicit diagnostic metadata.

Each event has `operationId` and `type`:

| Type | Additional fields |
| --- | --- |
| `requestStarted` | none; cancellation is registered before delivery |
| `started` | `invocationId`, `workingDirectory`, `arguments`, nullable resolved `executable`, `temporaryConfig` key/value pairs, `displayArguments`, `globalArguments`, `source` |
| `output` | `invocationId`, `stream` (`stdout`/`stderr`), `text`, `progress`, `truncated`, optional `progressDetails` (`stage`, nullable `percent`, `completed`, `total`) |
| `finished` | `invocationId`, nullable `exitCode`, monotonic `durationMilliseconds`, nullable `error`, `expectedExit` |
| `requestFinished` | nullable `error`, including failures before a child started |
| `authentication` | `requestId`, `prompt`, `secret`, `attempt`, optional `retry`, `workingDirectory` |
| `remoteResult` | `remote`, `succeeded`, nullable structured `error`, updated/deleted reference lists and counts, `referencesTruncated`, `referencesAvailable` |

`invocationId` is scoped to the request. `workingDirectory` is a native
absolute-path diagnostic, not a shared workspace identifier. Arguments/output
are redacted diagnostics; preview alone is not proof of process startup. An
unknown exit status remains null. A failed start may produce `finished` without
`started`; consumers must not fabricate an executed command from that event.
Native journals track `requestStarted` separately from visible command records.
The native receiver retains the originating request directory so a failure before
`started` can be shown as an unconfirmed request with no fabricated arguments or
exit code. Successfully completed internal queries still produce no history row.
A request that ends with the `cancelled` error before any command started was
superseded, not a Git failure, and also produces no row; a cancelled request that
had started a command keeps that command with the cancellation as its reason.
A request-start event must not allocate a placeholder or consume command-history capacity. Clearing
history suppresses late invocations from requests already in preflight, while
started operations remain cancellable until `requestFinished`, even after their
text is cleared. See `shared/fixtures/git/console-lifecycle-v1.json`.
Console presentation entries include an optional `notice`: `waitingForOutput`,
`completedWithoutOutput`, or `fetchUnchanged`. Native hosts localize this as a
status line, separate from retained Git stdout/stderr and copied command output.
Notices require empty retained output, no progress, no truncation and no failure.
`fetchUnchanged` additionally requires a completed successful Fetch and a
`remoteResult` with `succeeded: true`, `referencesAvailable: true`, and explicit
zero `updatedReferenceCount` and `deletedReferenceCount`. Missing counts must not
be treated as zero. Other successful empty results use `completedWithoutOutput`.

`displayArguments` and `globalArguments` are additive console projections: the
former starts at the subcommand, and the latter contains temporary configuration
as `-c key=value` pairs followed by the original global argument prefix. Consoles
fold contiguous `-c` pairs at their original positions; other global arguments
stay visible. Raw `arguments` remain authoritative for copying and diagnostics. Older events without projections retain their legacy display.
Visible workflow commands and explicit `git.command` requests produce execution
events. Internal read-only queries remain silent in the console while retaining
normal workflow capture and result semantics. Missing optional config values retain their
actual exit 1 with `expectedExit: true`; only the executing workflow can mark that
normal result. Other nonzero exits and request errors remain failures. The
`remoteResult` event carries the transfer's `invocationId` so later inspection
queries cannot acquire its summary. Final command response semantics remain unchanged.

A complete line is redacted before publication. Native diagnostic limits are
16 KiB per line, 512 KiB raw diagnostic input and 4,096 output events per
invocation. Limits produce an omission record without suppressing completion.
Raw parser capture has an independent 32 MiB per-stream bound and fails on
overflow. See `shared/fixtures/git/execution-events-v1.json`.

`git.rollbackPlan` accepts `changes` (up to 10,000 entries, each containing a
repository-relative `path`, optional `originalPath`, and the two-character Git
`status`) and optional `deleteAddedFiles` (default false). It returns ordered
`steps` containing `operation` and literal `paths`. Added and copied destinations
are unstaged while their disk contents remain by default; renames restore both
paths. Adjacent compatible operations are batched. Unsafe, overlapping or
ambiguous identities are rejected. `git.rollbackPrepare` also accepts `root`,
checks selected identities using bounded literal-path Git status queries, and
fails with `GIT_ROLLBACK_STALE_SELECTION` if any selected identity changed.
Untracked directories are expanded to the untracked files observed at prepare
time; a file created later is not included in the resulting deletion steps.
The 10,000-entry limit applies to the input selection, not the number of files
inside a selected directory. Callers should prepare after confirmation and
execute steps in order, stopping on failure and refreshing after any attempted
write. This status check cannot detect content changes that preserve the same
status or lock out external Git clients between preparation and writes; it is
not a content snapshot or an atomic transaction.

`git.reconcileDeletedSelection` accepts a repository `root` and the selected
pre-delete `changes` (`path`, two-character `status`). Under the repository
write lease, Core re-reads the selected literal paths and unstages only staged
additions or copy destinations that are now missing. Retained paths, tracked
deletions, unselected paths, and copy sources are not unstaged. Filesystem
operations may partially fail and external Git clients do not share this lease;
hosts must refresh after success or failure, and concurrent external modifications
are not an atomic snapshot. Up to 10,000 selected identities are accepted.

`git.prepareCommitSelection` accepts `repositories`, a nonempty list of up to
128 distinct repository roots and each root's selected identities (`path`,
optional `originalPath`, and two-character Git `status`). At least one selected
identity is required across all roots and the selection is limited to 10,000
identities. Hosts supply every repository whose index should be prepared,
including those with an empty selection, and check their own ChangeList ownership
before and after the call. Core checks every repository and selected identity
before writing, rechecks HEAD and index under the existing repository lease,
unstages other paths, stages selected paths only when not already staged, and
verifies the exact staged path set and previously staged selected object IDs
afterward. Selected untracked directories are expanded into observed files;
untracked embedded repositories and overlapping directory selections are
rejected, while tracked submodule gitlinks remain selectable. Paths are literal, including for ordinary `git.write`
staging. The call prepares indexes; it does not create a commit or replace the
subsequent workspace commit review. On cancellation or failure earlier writes
may already have succeeded, so hosts must refresh affected repositories. Git
clients outside Lithe do not share the lease; content changes that preserve the
same status and races after the last check are not an atomic snapshot guarantee.

`git.write` accepts a typed mutation request. Its required `operation` values are
`stage`, `unstage`, `discard`, `discardAll`, `stageAll`, `commit`, `ignore`, `exclude`, `cherryPick`, `revert`,
`reset`, `undoCommit`, `editCommitMessage`, `deleteCommit`, `squashCommits`, `createBranch`, `publishBranch`,
`renameBranch`, `setUpstream`, `unsetUpstream`, `deleteBranch`, `updateBranch`, `merge`, `rebase`, `createWorktree`,
`removeWorktree`, `lockWorktree`, `unlockWorktree`, `repairWorktrees`, `pruneWorktrees`,
`fetch`, `pull`, `push`, `checkout`, `checkoutAndRebase`, `checkoutRevision`, `clone`, `stashPush`,
`stashApply`, `stashPop`, `stashDrop`, `deleteRemoteBranch`, `operationContinue`,
`operationAbort`, `operationSkip`, `createTag`, and `deleteTag`. Optional fields are `paths`, `reference`, `referenceKind`,
`gitReference`, `revision`, `revisions`, `name`, `message`, `lightweight`, `signed`, `remote`, `destination`, `mode`,
`includeUntracked`, `checkout`, `amend`, `force`, `pushTags`, `expectedPush`, `autoStash`,
`worktreeMode`, `noCheckout`, `expectedBranch`, and `expectedState`. The four history actions require the reviewed `expectedState`
described below; earlier unreviewed history-write callers must migrate.

`pull` optionally accepts `expectedBranch` as a complete local `refs/heads/*`
identity for a background update whose host has already fetched. Core pins that
branch's fetched upstream commit and integrates it with local `merge --ff-only`,
`merge --no-edit`, or `rebase`, avoiding a second network wait in `git pull`.
It verifies symbolic HEAD under the repository writer lease before resolving the
upstream and again before integration; a different branch or detached HEAD fails
with `invalid_request` and does not integrate. Explicit source references and
auto-stash are incompatible with this guarded mode. Other operations reject this field. Omission preserves
existing clients. Hosts should also recheck the selected worktree after Fetch and
before invoking the guarded update, reporting `state-changed` if the checkout changed while
the request was waiting. The lease serializes Lithe writes, not external Git
clients; the final check reduces the gap and is not an external checkout lock.

The core validates pathspecs, revisions, branch names, references, reset modes,
stash references, and operation-specific required fields before invoking Git.
`setUpstream` requires a typed remote `gitReference` and passes its complete
`refs/remotes/*` identity to Git, so a same-named local branch cannot make the
upstream ambiguous. `createWorktree` accepts `worktreeMode` values `newBranch`
(the backward-compatible default), `existingBranch`, and `detached`.
`newBranch` requires `name` and a typed `gitReference`, with an optional
`revision` override. A remote base without a revision override uses one
`git worktree add --track -b` mutation so creation and tracking have one Git
outcome. Explicit revisions resolve to immutable OIDs and use `--no-track`;
local and tag bases also use `--no-track`, independently of
`branch.autoSetupMerge`. `existingBranch`
requires a typed local branch and rejects `name` and `revision`; it passes the
validated branch identity without `-b`, leaving Git to reject an already
occupied branch. `detached` rejects `name` and requires a typed reference or
`revision` (the latter takes precedence), resolves it to an immutable commit,
and uses `--detach`. Independent `noCheckout: true` adds `--no-checkout` in
every mode; its default is false, and legacy `checkout` does not control
worktree file population. Examples are in
`shared/fixtures/git/worktree-creation-v1.json`. Worktree mutations re-read Git's
registered list and reject arbitrary paths. Removal rejects the current,
primary, or locked worktree; dirty worktrees require an explicit `force` value.
`repairWorktrees` refreshes administrative links after a repository or worktree
has moved. `pruneWorktrees` removes registrations whose checkout is already missing and
does not recursively delete an arbitrary directory.

`updateBranch` requires a typed, non-current local `gitReference`. Core resolves
that branch's configured remote upstream and performs an atomic Fetch that
refreshes the remote-tracking ref and fast-forwards the local branch without
switching HEAD. Git rejects diverged branches and branches checked out by any
worktree, so the operation cannot discard local commits or mutate another active
checkout.
Successful process launch returns `{ "arguments": string[], "output": string,
"stdout": string, "stderr": string, "exitCode": number, "invocations":
GitCommandInvocation[], "operationError": CoreError?, "stashRestore":
GitStashRestore?, "historyRewrite": GitHistoryRewriteResult?, "warnings": GitOperationWarning[] }`
even when Git exits non-zero.
`GitOperationWarning` is `{ "code": string, "message": string, "details"?: string }`
and reports a non-fatal follow-up failure after the requested mutation already
succeeded. Platform clients must retain the successful operation outcome while
presenting the warning. The top-level process fields
normally describe the final subprocess, and `output` is that subprocess's
`stdout` followed by `stderr`. `invocations` records every Git subprocess for
composite operations such as `discardAll` and Smart Checkout in execution
order; each item contains the exact argument vector (excluding the executable
name), separate streams, and exit code. A follow-up validation or probe failure
after Git has started is returned in `operationError` alongside the retained
trace. A stash restore conflict is a logical operation failure represented by
`stashRestore`, even when a later diagnostic invocation exits successfully.
Consumers must therefore consider `operationError` and `stashRestore` in
addition to the compatibility `exitCode`. The shared compatibility fixtures are
`shared/fixtures/git/command-response-v1.json` and
`shared/fixtures/git/command-error-response-v1.json`. Invalid arguments found
before any Git subprocess use the standard `invalid_request` error envelope.
`checkout` uses `referenceKind` values
`local`, `remote`, or `tag`. A remote checkout creates its tracking local branch
when missing, or fast-forwards an existing matching tracking branch to the selected
fetched remote commit. This also updates an already-current local branch and
succeeds when it is already aligned. It does not Fetch again or create merge
commits. Local-only commits (ahead or diverged) block the operation before a switch
or automatic stash; `force` discards working changes, never committed history.
Blocking working changes and another worktree's branch ownership remain protected.
The selected remote commit is pinned and branch identity is rechecked before
integration. A composite checkout may switch successfully before a later integration
or stash restore fails, so consumers refresh repository state after either outcome.
Local checkout and `checkoutAndRebase` retain their existing policies. Scenarios are
in `shared/fixtures/git/remote-checkout-v1.json`.
`clone` uses `remote` as its source and
`destination` as its target path. `publishBranch` validates `name`, creates
and checks out that branch at a detached HEAD when needed, then pushes it with
an upstream. If the push fails, the local branch is intentionally retained so
the user can fix credentials or connectivity and retry without losing commits.

`git.pushPreview` accepts `root`, an optional complete local `gitReference` or
legacy `reference`, an optional bounded `limit`, `pushTags`, and an optional
`pushTarget`. It returns `localBranch`,
`localHead`, `remote`, `remoteBranch`, `targetKind`, `createsRemoteBranch`,
nullable `remoteTrackingOid`, nullable `upstream`, exact reviewed `tags`,
`commits`, and `hasMore` using `shared/fixtures/git/push-preview-v1.json`.
`targetKind` describes how `remoteBranch` relates to the local branch:
`tracking` when both names match, `publish` when the branch has no upstream on the
selected remote and will be published under its own name, and `divergent` when the
upstream branch has a different name. `createsRemoteBranch` reports whether
`remoteBranch` is still absent on the remote. The push destination follows
`branch.<name>.pushRemote`, then `remote.pushDefault`, the configured upstream
remote, `branch.<name>.remote`, and finally `origin` or the first configured
remote. An upstream only names the destination when it lives on the selected
remote, so a `pushRemote` or `remote.pushDefault` override falls back to the
same-named branch on that remote. A destination without a fetched tracking
reference previews commits not reachable from that remote. A reviewed `push`
mutation sends these resolved fields back as `expectedPush`; Core rejects a stale
local tip, destination, or tracking OID before starting Git. An optional
`expectedPush.targetKind` is compared only when the caller supplies it, so a
caller that predates target kinds keeps its previous behaviour instead of being
rejected as stale.

A `divergent` destination is never pushed implicitly. `pushTarget` accepts
`publish` (send the branch to its same-named remote branch and repoint the upstream
there after a successful push) or `upstream` (keep the differently named upstream
branch, which is the only case allowed to update it, and leave the tracking
configuration untouched). `git.pushPreview` and `push` resolve the destination
through the same function with the same `pushTarget`, so the preview describes the
branch, tracking OID and commits that choice would update, and a reviewed push is
validated against exactly that destination. A client therefore previews with the
choice, shows the result, and pushes with the same `pushTarget` and the
`expectedPush` taken from that preview; a tracking configuration that moves in
between is rejected as stale. Without `pushTarget`, a `divergent` preview reports
the same-named destination and `push` rejects the request with `invalid_request`.
`pushTarget` is ignored for branches that are not `divergent`.
`force` binds
`--force-with-lease` to the reviewed destination OID when `expectedPush` is
present, and Core also validates the reviewed tag identities; `pushTags` accepts
`none`, `all`, or `reachable` and maps to no tag option, `--tags`, or
`--follow-tags` respectively. Legacy push callers may omit `expectedPush`. A
reviewed push uses the preview's immutable `localHead` OID as the refspec source,
so a repository change after validation cannot add unreviewed commits to the
operation. Because Git cannot infer an upstream from an OID source, Core
explicitly configures the reviewed local branch after a successful first push.

New reference-based workflows send `gitReference` as `{ "fullName": string,
"shortName": string, "kind": "local" | "remote" | "tag" }`. Core verifies
that all three fields describe the same namespace and validates the full ref
with Git. The legacy `reference` and `referenceKind` fields remain accepted for
existing platform calls. `checkoutAndRebase` requires a local or remote branch
reference and a completely clean worktree; Core records the current local
branch before switching and rebases the checked-out branch onto that original
branch. A dirty tree or detached HEAD is rejected before checkout begins. When
remote checkout finds an existing same-named local branch, Core uses it only if
its configured upstream is the selected complete remote reference.

`pull` without an explicit reference retains current-upstream behavior. An
explicit remote reference may use either the preferred `gitReference` shape or
the legacy `reference` plus `referenceKind: "remote"` fields. Core validates and
safely splits `refs/remotes/<remote>/<branch>` against configured remote names,
then invokes pull with the explicit remote and branch using `mode` `ffOnly`,
`merge`, or `rebase`. Platforms must not parse the remote reference or construct
these Git arguments themselves.

`deleteRemoteBranch` requires a complete remote `gitReference`. Core resolves
the configured remote with longest-prefix matching and invokes a structured
remote branch deletion; platforms must not split `shortName` themselves.

When `commit` includes `paths`, Core stages the complete working-tree state of
those paths, including untracked files and deletions, then commits only those
paths. Other paths already present in the index remain staged and are not part
of the new commit. Core checks conflict markers after preparing that final
snapshot in an isolated temporary index initialized from the operation's HEAD
tree. The real index is not changed on any
staging, validation, hook, signing, or commit failure; successful commits
reconcile only the selected paths, preserving unrelated staging created while
the operation ran. Selected paths used to prepare and reconcile the snapshot
are passed to Git over NUL-delimited stdin with `--pathspec-from-file`, avoiding
platform command-line limits and preserving rename source/destination identity.
`git.diff` accepts `worktreeSnapshot: true` to review that same complete
working-tree snapshot against `HEAD` through an isolated temporary index. This
mode includes staged, unstaged, untracked, deleted, and same-path recreated
files without reading or mutating the real index and cannot be combined with
other diff reference modes.
A `commit` request without `paths` retains
the legacy behavior of committing the existing index. `ignore` appends root-anchored patterns to the
repository's top-level `.gitignore`; `exclude` appends the same patterns to the
worktree-aware Git metadata path for `info/exclude`. Both ignore operations
preserve existing content, escape Git pattern characters, de-duplicate rules,
and interpret a trailing `/` as a directory rule.

`editCommitMessage` rebuilds the selected commit and its later first-parent
descendants with the new `message`. `squashCommits` requires at least two
distinct, contiguous `revisions`, uses the newest selected tree, and rebuilds
later descendants. Both preserve commit author and committer attribution and
atomically update the checked-out branch reference. `deleteCommit` drops a
non-root commit and replays later commits; deleting HEAD resets to its parent.
All three operations reject a dirty worktree, detached HEAD, an active Git
operation, a target outside the current branch's first-parent chain, a rewrite
range containing a merge commit, or any rewritten commit reachable from
`refs/remotes`. They also reject any signed commit in the affected range, so
the existing unsigned `commit-tree` execution cannot silently strip a signature.
Their complete messages must be UTF-8. Root-commit message edits and squash
ranges that include the root remain supported; root deletion is rejected.

`undoCommit` accepts one `revision` that must resolve to the checked-out local
branch's HEAD with exactly one parent. It atomically moves that branch to the
parent while preserving the index bytes and working files, including existing
staged, unstaged, and untracked edits. It rejects root and merge commits,
detached HEAD, unresolved conflicts, an active Git operation, and a HEAD known
to be reachable from remote-tracking refs. Undo may preserve a signed HEAD
because it moves a ref without reconstructing or modifying that commit object.

Native interactive rebases use the dedicated preview/start/session/control
contract in [git-rebase-session.md](git-rebase-session.md). The base selected
for “Rebase from Here” remains unchanged; only its successors are rewritten.

`git.historyActionCapabilities` accepts `{root, revisions}` with at most 1,000
full SHA-1 or SHA-256 commit identities and returns `head`, `canCherryPick`,
`canUndo`, and `canSquash`. It resolves actual checkout HEAD rather than a
visible or paginated row. Undo requires a checked-out branch and a HEAD with
exactly one parent; squash requires a distinct contiguous selection on that
branch's first-parent history within the latest 1,000 commits. Cherry-pick is
only offered for a different existing commit. These are structural menu hints,
not permission to mutate: `git.historyRewritePreview` still checks worktree,
operation state, unsupported commits, published history, and the reviewed
snapshot. Clients cancel and discard stale results when the menu closes,
selection or repository changes, or the history is refreshed. See
`shared/fixtures/git/history-action-capabilities-v1.json`.

`git.historyRewritePreview` accepts `{ "root": string, "operation": string,
"revisions": string[] }` for those four operations. It returns `operation`,
`allowed`, `blockers` (`{ "code": string, "message": string }[]`), nullable
`branch` and `head`, `selectedCommits`, `affectedCommits`, `suggestedMessage`,
and nullable `expectedState`. Each commit has a full `hash`, `parents`, and its
complete, untrimmed `message`; both commit lists are oldest first, independently
of UI sorting, filtering, or pagination. Squash's suggested message combines
all selected messages in that order. The preview permits at most 1000 affected
commits; an out-of-range selection is explicitly blocked rather than truncated.
`affectedCommits` covers later descendants whose OIDs change as well as the
selection. Remote reachability uses local `refs/remotes`, including descendants;
it is not a live server claim that a commit has never been published.

An actionable preview contains `expectedState` as `{ "branch": string,
"head": string, "stateToken": string, "operation": string, "revisions": string[] }`.
Callers return this object unchanged in `git.write`, using its selected full
OIDs in the normal `revision` or `revisions` fields. The optional edited
`message` is separately validated without silently trimming its contents.
Core normalizes subdirectory roots to the repository root. Its opaque token
covers checkout identity and symbolic HEAD, local/remote/tag refs, exact index
contents, working-file diffs, untracked-file contents, and active operation
state. Core repeats eligibility and snapshot checks before preparation and
again before the expected-OID ref update. Changed previews fail with
`invalid_request` and a stale-preview message. Typed Git writers, including
index patch operations, share a repository-wide in-process lease across linked
worktrees; external Git writers remain subject to snapshot and OID checks.

Before altering the branch, Core creates a persistent ref beneath
`refs/lithe/history-recovery/` at the original HEAD. Its reflog records the
operation, original branch and HEAD so the point remains attributable after a
process restart. At most the newest 20 recovery refs are retained after
successful cleanup; cleanup failure is explicit. These internal refs are
excluded from ordinary reference lists and unfiltered Git history, including
decorations. A host can use the recovery OID/ref with the existing `createBranch`
operation to preserve or inspect the old history without resetting working files.

After a recovery point exists, the response retains `historyRewrite` as
`{ "operation": string, "branch": string, "originalHead": string, "newHead":
string | null, "recoveryReference": string, "mutationApplied": boolean,
"outcomeKnown": boolean, "worktreeRefresh": "notNeeded" | "ready" | "failed" }`.
`newHead` is the prepared target when one exists, even if its installation failed.
`mutationApplied` is true only after successful installation or observation;
when interrupted outcome inspection also fails, `outcomeKnown` is false and
the user must inspect recovery before retrying. Clients must not infer that
nothing happened from a cancellation or generic error. Drop replays against an
isolated index before moving the ref; replay failure leaves real checkout state
unchanged. After a successful ref update, a guarded two-tree checkout refresh
does not move HEAD again. Refresh failure yields `git_worktree_refresh_failed`
while preserving `mutationApplied: true` and the recovery point. For these
structured responses, compatibility process fields describe the authoritative
mutation result instead of a later recovery-cleanup subprocess; diagnostics
remain available in `invocations`, `operationError`, and `warnings`.
The compatibility fixture is `shared/fixtures/git/history-rewrite-v1.json`.

`createTag` uses `name` for the new tag, `revision` as its target commit or
revision, and an optional `message`: when the field is present (including an
empty value), it creates an annotated tag (`git tag -a`); an absent field
creates a lightweight tag. UI callers trim new user-entered messages. Core
passes the supplied annotation with verbatim cleanup so restore preserves
CRLF and trailing blank lines, and an explicit empty value preserves an empty
annotated tag. Two optional typed fields refine that legacy choice:
`lightweight: true` forces a lightweight tag with `--no-sign`, overriding
`tag.gpgSign`, and rejects a non-blank `message` or `signed: true` with
`invalid_request` and the stable message
`Lightweight tags cannot include a message or signature` before any
subprocess; `signed: true` adds `-s`, which creates a signed annotated tag
when a message is present. Omitting both fields preserves the existing
behavior, so callers that predate the fields are unaffected. The argument
matrix is pinned by `shared/fixtures/git/tag-write-v1.json`.
Tag names must satisfy the `git check-ref-format` refname rules and must not
begin with a dash; `shared/fixtures/git/tag-names.json` pins the boundary cases
for Core and host-side validation. Before invoking Git, `createTag` probes the
repository so a duplicate tag (`A tag named '<name>' already exists`) and an unresolvable
non-commit target (`Could not resolve tag target '<rev>'`) fail with stable
`invalid_request` messages instead of localized Git output. `deleteTag` uses
`name` and removes `refs/tags/<name>`; a missing tag fails with
`The tag '<name>' does not exist`. On success the response carries a
structured `tagDeletion` record — `{ "name": string, "deletedTarget": string,
"kind": "lightweight" | "annotated", "message": string? }` — where
`deletedTarget` is the peeled commit the deleted ref resolved to and
`message` is the original annotation with its line breaks preserved. Hosts
can rebuild the tag by replaying `createTag` with `name`, `deletedTarget`,
and `message`; the tagger identity and timestamp are intentionally not
preserved. Deletion supplies the observed unpeeled object ID to `update-ref`,
so a concurrent force-update fails atomically instead of deleting new state and
returning a stale recovery target. `deleteBranch` applies the same expected-OID
guard after checking the branch is fully merged and not checked out, then
on success, carries a structured `branchDeletion` record —
`{ "name": string, "deletedTarget": string }` — so hosts can offer to
recreate the branch at its previous commit; a missing branch fails with
`The branch '<name>' does not exist`. If the ref deletion succeeds but branch
configuration cleanup fails, the response contains both `branchDeletion` and a
`branch_config_cleanup_failed` warning; hosts must preserve the Restore action while surfacing the
cleanup diagnostic.

`operationContinue`, `operationAbort`, and `operationSkip` inspect Git metadata
to select the active merge, rebase, cherry-pick, or revert instead of accepting
an operation kind from the caller. Continue is rejected while conflicted paths
remain, and skip is supported only for a rebase. All three return the normal
Git process result when Git is invoked;
an absent or unsupported operation state uses the `invalid_request` envelope.

`git.checkoutPreflight` accepts `{ "root": string, "reference": string }` or
the preferred `{ "root": string, "gitReference": GitReference }` shape and
returns `{ "blockingPaths": string[] }`. The sorted, de-duplicated result
contains tracked paths that are both locally modified and different between
HEAD and the target, plus untracked paths that the target reference tracks.

`git.pullPreflight` accepts `{ "root": string }` and returns `upstream` as a
string or `null`, numeric `ahead` and `behind` counts, `diverged`, and
`hasLocalChanges`. It reads the existing tracking reference without fetching;
`diverged` is true only when both counts are non-zero. `hasLocalChanges` checks
tracked changes and excludes untracked files. A branch with no configured
upstream returns `null`, zero counts, and false for both booleans.
`configuredStrategy` is `"rebase"` when `pull.rebase` is true, `"ffOnly"` when
`pull.ff` is `only`, `"merge"` when `pull.ff` or `pull.rebase` is false, and
`null` when Git is not configured for a strategy.

`git.updatePlan` is a pure planner; it never starts Git. `{ "stage": "route",
"branch": { "fullName", "upstream", "isCurrent" }, "worktrees": [{ "path",
"branch", "isCurrent" }] }` returns `blocked`, `fastForwardReference`, or
`inspect` with the `checkout` worktree (or `null` for the request root), the
`expectedBranch`, and whether the user may be asked. `{ "stage": "inspect",
"preflight", "interactive", "explicitSource"?, "strategy"?, "confirmation"? }`
returns `blocked` (`noUpstream`, `localChanges`, `upToDate`, `notFastForward`,
`stateChanged`), `chooseStrategy`, or `pull` with the mode for `git.write`.
The strategy is the user's choice, else the preflight's `configuredStrategy`,
else `ffOnly`; a diverged history that would need `ffOnly` asks when
`interactive` and is refused otherwise. `{ "stage": "defaultStrategy",
"preflight", "fastForwardPossible" }` returns the strategy a Pull dialog
preselects. `shared/fixtures/git/update-plan-v1.json` defines the rules.

`git.historyWindow` is a pure planner over commit identities in display order.
`refreshPlan` returns the first-page `limit`: with `preserveLoaded` it is at
least the loaded count, so a refresh never shrinks a deep window. `extendPlan`
returns the `extensionLimit` that keeps the previous tail loaded after new
commits appeared at the head. `mergePage` returns the `append` positions of a
page that are not yet in the window and whether `hasMore`, bounded to 5000
commits. `reconcileSelection` returns the retained `selected` identities in
window order plus `focused` and `anchor`, falling back to the first loaded
commit. `shared/fixtures/git/history-window-v1.json` defines the rules.

`git.graphProjection` is a pure projection of one loaded history window; it never
starts Git. The request is `{ "commits": [{ "hash", "parentHashes", "decorations" }],
"remoteNames"?, "repositoryCommits"?, "visibleHashes"?, "displayMode"?,
"currentBranch"? }`: `commits` are in Git's child-before-parent order, `remoteNames`
are the remote short names that type a bare remote-tracking decoration,
`repositoryCommits` is the complete repository window that fixes the permanent layout
(ignored unless it is unique and covers every scoped commit), `visibleHashes` applies
a filter (omit it to show every commit), `displayMode` is `compact` (default) or
`expanded`, and `currentBranch` asks for the ancestry of that local branch. Hosts call
it once per loaded window, never per commit, and recompute the whole window when a page
is appended or the history refreshes; lanes depend on every loaded edge, and a head
fragment's color ID is the Java `String.hashCode` of its principal reference name, so a
named branch keeps its color across pages. The response is `{ "version", "rows",
"laneCount", "recommendedLaneCount", "hasMissingParents", "currentBranchHashes" }`.
Each visible row carries `commitHash`, integer `lane` and `laneCount`, a signed
`colorId`, `layoutIndex`, `incomingLaneColors`, `parentEdges` (`id`, `parentHash`,
`targetLane`, `colorId`, `isMissing`, `isDotted`), typed `labels`, and
`printElements` (the up and down half-edges with `position`, `adjacentPosition`,
`colorId`, `isDotted`, `isMissing`, `hasArrow`, `isTerminal`, `targetHash`). Hosts own
pixels, curves, and the mapping from a color ID to a theme color; `colorId` `0` means
an unreferenced fragment. Requests over 20,000 commits fail with `invalid_request`.
`shared/fixtures/git/graph-projection-v1.json` defines the rules and
`shared/fixtures/git/graph-idea/` holds the pinned IntelliJ oracles.

`git.integrationPreflight` accepts either `reference` or `gitReference` with
`root` and `operation`, where `operation` is `merge`, `rebase`, `cherryPick`,
or `revert`. It returns sorted, de-duplicated `blockingPaths` and
`blocksEntirely`. Merge, cherry-pick, and revert report only dirty tracked paths
that overlap files the operation would write. Rebase reports every dirty
tracked path and sets `blocksEntirely` to true when that set is non-empty.

`git.conflictMarkers` accepts `{ "root": string }` and returns
`{ "paths": string[] }`. Paths are sorted and de-duplicated staged text files
whose staged content has a line beginning with an opening, closing, or diff3
conflict marker. A bare
`=======` line is not treated as a conflict marker.

`git.operationState` accepts `{ "root": string }` and returns `kind`,
`reference`, `step`, `total`, and sorted, de-duplicated `conflictedPaths`.
`kind` is an empty string when no operation is active; otherwise it is `merge`,
`rebase`, `cherryPick`, or `revert`. `reference`, `step`, and `total` are
nullable, and the progress counters are populated only for a rebase. State is
read from Git's own metadata, so operations started outside Lithe are reported.

`git.diff` accepts `root`, `pathspecs`, optional `reference`, `gitReference`,
`targetGitReference`, or `commit`, plus `emptyTreeBase` for a legacy target
reference whose comparison must begin at the repository's object-format-specific empty tree,
`staged`, `untracked`, `contextLines`, and `ignoreAllWhitespace`, and returns `{ "patch": string, "rows": [],
"hunks": [] }`. Rows contain one-based `oldLine`/`newLine` values where
available, `left`/`right` text, a `kind` (`context`, `changed`, `addition`,
`removal`, or `information`), and an optional `hunkID`. For `context` and
`information` rows both sides carry identical text, so `right` is omitted and
clients must fall back to `left`. Hunk entries contain their header and the
patch text needed for partial apply; rows are not duplicated per hunk, so
clients group `rows` by `hunkID` instead.
The response also carries `hasDecodingLoss`: true when Git's output was not
valid UTF-8 and Core replaced bytes with U+FFFD while decoding `patch`. Such a
patch still renders, but it is not the file's bytes; clients must not write it
back, for example as byte-faithful rollback material.
New reference-tree workflows use `gitReference`; Core validates its full
identity before constructing the diff invocation. When `targetGitReference` is
present, Core validates both complete identities and constructs the two-ref
range. The legacy `reference` field remains available for existing revision and
range comparisons.

`git.comparison` accepts `root` plus the same `reference` or `gitReference` /
`targetGitReference` forms and returns the deterministically ordered changed
files. `includeUntracked: true` adds untracked worktree files with status `A`
and `isUntracked: true`, deduplicated by path; omitted or false keeps the
previous response. The flag is invalid for a two-reference range. If status
cannot be read, the request fails rather than returning an incomplete result.
See `shared/fixtures/git/comparison-untracked-v1.json`. Platforms must not
construct a two-ref range themselves.
`git.apply` accepts `root`, `patch`, and `mode`; supported modes are `stage`,
`unstage`, `discard`, `restoreIndex`, `worktree`, `restoreIndexCheck`, and
`worktreeCheck`. The two `*Check` modes only test whether the reverse patch
already applies, so Shelf restoration can be retried after a partial failure.
It returns the normal Git process result. `restoreIndex` applies a saved
index patch to both the index and worktree; `worktree` applies only to the
worktree. Pathspecs must be workspace-relative and must not contain absolute
paths or `..` components. A `discard` patch is refused with
`GIT_HUNK_ROLLBACK_UNSAFE` when Git's attributes for any touched path name a
`filter` or `working-tree-encoding`, because those can rewrite bytes the patch
never saw.

`git.diff` with `includeFileSections` and a complete-file context splits each
file's single hunk into Git-default (3 context line) hunks. Each hunk carries
its own byte-faithful `patch` plus `lineStart` / `lineEnd` (end-exclusive
indices into the file's `lines`); a section that cannot be split yields no
hunks, so no writable hunk is offered. Hosts never build patch text.

`git.planDiffBlocks` accepts `{root, path, originalPath?, staged?}` and returns
`{token, blocks, worktree, index}`. `worktree` is the HEAD to worktree (or, with
`staged`, HEAD to index) complete-file section and `index` is HEAD to index,
both without patch text. Each block is `{id, checked, indeterminate, canToggle,
canRollback, wholeFile?}`; `id` is `line-<index>` into the section's unified
lines. `token` identifies the read. `git.applyDiffBlock` accepts the same
target plus `{blockId, action, token}` where `action` is `include`, `exclude`
or `rollback`. Core rebuilds the plan under the repository write lease and
refuses with `GIT_DIFF_BLOCK_STALE` when the token no longer matches,
`GIT_DIFF_BLOCK_UNAVAILABLE` for a block that cannot take the action, and
`GIT_HUNK_ROLLBACK_UNSAFE` for a rollback blocked by attributes.
`git.stageGutterChange` accepts `{root, path, originalStart, originalEnd,
modifiedStart, modifiedEnd, originalLines, modifiedLines}` (one-based,
end-exclusive) and stages exactly that change from the original bytes, or fails
with `GIT_GUTTER_CHANGE_STALE` when the index or saved file no longer shows the
compared lines. See `shared/fixtures/git/diff-blocks-v1.json`.

`git.remotes` returns `{remotes: [{name, url}]}` for fetch entries. `git.tags`
returns `{tags: [{name, objectId, targetId, message, date, isAnnotated}]}`;
names come from full `refs/tags/` identities even when a branch has the same
name, and `targetId` is the dereferenced object when Git reports one. These
commands own Git output parsing and return errors for malformed output.
`git.classifyMetadataChanges` accepts `{context, paths}` with at most 256 paths
per call. The context contains `repositoryRoot`, `gitDirectory`,
`gitCommonDirectory`, optional `workspaceRoot`, and optional `ruleDirectories`.
Each non-empty path is at most 131,068 bytes. Paths use the host's native
semantics and must already have the same resolved identity as the watch roots;
Core performs no IO. The ordered `events` array returns `kind` (`context`,
`ignoreRule`, `metadata`, `ignored`, or `other`) and `indexOnly`. Hosts retain
ownership of native loss flags, watch lifetimes, and workspace visibility; on
classification failure they must conservatively rescan. Native Rust callers can
use the same typed classifier without JSON. The shared fixture is
`shared/fixtures/git/metadata-classification-v1.json`.

`git.parseCheckoutMetadata` and `git.parseGitdirPointer` each accept `{text}`
of at most 4096 UTF-8 bytes and return `{branch}` or `{path}`, respectively;
the host reads files and resolves relative paths. Examples live in
`shared/fixtures/git/remote-tag-catalog-v1.json` and `checkout-metadata-v1.json`.

`git.history` accepts `root`, an optional full `reference`, and `limit` (the
core clamps it to `1...5000`). It remains the compatibility command that
combines `git.references` with the first `git.historyPage`. New clients use
`git.references` with `{ "root": string }` and request commits separately with
`git.historyPage` using `root`, optional full `reference`, nullable opaque
`cursor`, `limit`, and optional `order` (`"topo"` or `"date"`). Omitted
`order` preserves the original `git log --topo-order` behavior. `"date"` uses
`git log --date-order`: committer date descending whenever the child-before-
parent constraint permits, independently of the displayed author date. macOS
and Windows Git Log request date order for their pages and repository graph;
other clients that omit the field retain topology order. A cursor is bound to its root, reference, and order;
continuations must repeat the same order. A mismatched order returns
`invalid_request` without consuming the cursor. The portable request example is
`shared/fixtures/git/history-page-date-request-v1.json`.
The first request omits `cursor`; each later request
returns the prior page's `nextCursor`. Core keeps one bounded, backpressured
`git log` stream behind that cursor and clamps the stream to the first 5,000
commits, so later pages continue traversal instead of replaying earlier commits.
A history page returns `commits`, nullable `nextCursor`, and `hasMore`. Clients
call `git.historyCursorClose` with `root` and `cursor` when abandoning an
unfinished stream, and discard and close a late page when its repository,
selected reference, or owning `operationId` is stale. Core also expires idle
cursors and caps the number of live streams. Commit parents are explicit so
clients can render merge topology without re-parsing Git output. The optional
effective `userName` and `userEmail` returned by `git.references` let clients
implement a stable `me` filter without guessing from recent commits. Each
reference includes `peelsToCommit`; hosts use it to disable commit-only
actions for legal tree/blob tags before the user reaches a failing mutation.
Each local
reference with an upstream also returns numeric `ahead` and `behind` counts
against that fetched remote-tracking reference. A restricted remote fetch refspec
must not hide an explicitly configured `branch.<name>.remote` / `merge` relationship
when its conventional remote-tracking ref exists. The reference snapshot resolves
missing metadata using invocation-only Git configuration; it does not change
repository fetch settings, guess tracking from matching names, or fetch remotely.
References without an upstream,
remote references, and tags return zero for both fields. Portable examples are
`shared/fixtures/git/references-response-v1.json` and
`shared/fixtures/git/history-page-response-v1.json`.

For compatibility, a request that explicitly contains the deprecated numeric
`offset` field still uses the bounded offset implementation and returns
`nextOffset`; it honors the same optional `order`. New clients must omit
`offset`; repository size does not select
between the two protocols.

`git.historyLocate` accepts `root`, nullable `reference`, nullable opaque
`cursor`, optional `order` (`"topo"` or `"date"`), a complete 40-character
`target` commit hash, `limit` (`1..=500`, default `300`), and `maxPages`
(`1..=100`, default `20`). It reads pages from the platform's current window
cursor until `target` is found, the page budget is spent, or the history ends,
and returns `{ "found": boolean, "commits": GitCommitResponse[], "nextCursor":
string?, "hasMore": boolean, "pagesLoaded": number }`. `commits` lists every
commit read in reading order, including the complete page that contains
`target`, so hosts append them after hash deduplication without leaving a gap
before the returned cursor. A hit stops reading and returns that page's
`nextCursor` and `hasMore`. Exhausted history returns `found: false`, a null
cursor, and `hasMore: false`; a spent budget returns `found: false`, the last
page's cursor, and `hasMore: true` so the host can continue later. A `limit`,
`maxPages`, or `target` outside the contract fails with `invalid_request`
before any Git process starts. Git read failures keep their stable error codes
instead of becoming "not found". Core owns the intermediate stream and only
returns a cursor the host can continue; a failed read releases it. Requests
without a cursor start at the first page and continuations must repeat the same
`root`, `reference`, and `order`. Portable request and response examples are in
`shared/fixtures/git/history-locate-v1.json`.

`git.repositoryColorAssignments` accepts `{ offset, totalCount, repositoryIds }`.
IDs are the host's already normalized, unique repository identities in the full
ordered workspace list, before worktree visibility filtering. Each request carries
at most 128 IDs and their global offset; IDs are nonempty and at most 4,096 bytes.
Core rejects duplicates within a page and out-of-range offsets with
`invalid_request`. The response contains ordered `{ id, slot }` assignments,
`fallbackSlot` for unknown IDs, and `showColors` for multi-repository views.
Callers must keep pages from the same list generation together, cancel or discard
stale results, and never recompute the slots per row. Color palettes remain native
presentation. See `shared/fixtures/git/repository-colors-v1.json`.

`git.branchNamePreview` is pure: it never starts Git and only reads the
reference facts the host already loaded. It accepts `rawName` (at most 1,024
characters; longer input is `invalid_request`), `requireName` (`true` on submit,
where an empty name is an error, and `false` while typing), `references`
(loaded `{ "kind": "local" | "remote" | "tag", "shortName": string }` facts),
and an optional `reference` describing the base reference. The response is
`{ "typingCleanedName": string, "cleanedName": string, "initialName": string,
"error": null | { "code": string, "name"?: string, "branch"?: string } }`.
`typingCleanedName` mirrors IDEA's `GitRefNameValidator` typing cleanup: it
drops characters that cannot appear in a branch refname, drops a leading `.`,
`-`, or `/`, drops one slash of a doubled slash, keeps only the last dot of a
dot run, drops dots next to slashes and `@{` sequences, and replaces space runs
and ASCII control characters with `-`. `cleanedName` is the submit-time form:
the same cleanup plus removal of one trailing `.`, `/`, or `.lock`, trimmed at
the edges. `initialName` is the loaded base reference's short name, or that name
without its first remote segment when the reference is remote; it is empty
without a reference. `error.code` is one of `empty`, `head`,
`clashesWithRemote`, `clashesWithDirectory`, `alreadyExists`, or
`clashesWithBranchPrefix`, checked in IDEA's order; `empty` appears only when
`requireName` is true. The conflict codes carry the candidate `name`, and
`clashesWithBranchPrefix` also carries the existing local `branch` that occupies
one of the candidate's slash prefixes. Refname validity itself stays with
`git check-ref-format` when the branch is created. Portable examples are in
`shared/fixtures/git/branch-name-preview-v1.json`.

`git.commit` accepts `root` and a revision, returning one `commit` object with
the same fields as a history page entry and a `body` string. `body` is the
message after the subject paragraph (Git `%b`), keeps internal line breaks and
indentation, has trailing whitespace removed, and is empty for a subject-only
message. History pages carry only `subject`; a commit detail view reads the
body on demand with `git.commit`. See
`shared/fixtures/git/commit-lookup-response-v1.json`.
`git.blame` accepts `root` and a workspace-relative `path`; its line numbers
are one-based and author timestamps are Unix seconds.

`git.lineHistory` accepts `root`, a workspace-relative `path`, the editor
snapshot `content`, a one-based inclusive `startLine`/`endLine` range
addressing that snapshot, and an optional `limit` (default 50, capped at 200;
snapshots above 8 MiB are rejected). The snapshot is mapped onto the pinned
`baseCommit` through an isolated platform-temp comparison, so unsaved edits
stay answerable; the response echoes `baseCommit`, lists `unmappedLines`
(`kind` `new` for provably inserted lines, `unreliable` for rewritten ones),
and returns `commits` newest first with `hash`, `kind` (`commit` or
`merge-first-parent`), `authorName`, `authorTime` (Unix seconds), `subject`,
`pathAtCommit`, optional `previousPath` on renames, `compareBase` (the parent
the metadata diff was taken against; empty for the root commit whose base is
the empty tree), and `relevantRanges` hunks intersecting the traced lines.
Queries walk the first-parent chain only: branch-internal commits of a merge
are not listed separately, pure renames are not listed as content changes,
and `truncated` reports entries beyond the limit. Pure-deletion sides report
the boundary position as both start and end.

`workspace.search` accepts `maxResults` for a total result cap. Callers that
need separate buckets may also provide `maxFileResults` and
`maxContentResults`; each category is capped independently and the total cap
still applies.

Search index enumeration skips inaccessible or vanished descendant directories,
logging workspace-relative diagnostic paths without discarding unrelated results.
Workspace-root failures, cancellation, deadlines, and other errors still propagate.
This applies to both the content and file-name indexes.

macOS Search Everywhere funnel exclusions reuse `hiddenFilePatterns` only on
Search Everywhere requests. They are remembered across popup openings, have no
General Settings entry, and have a separately remembered enable toggle. Editing
happens in a dialog; saving does not enable a disabled rule. They do not affect
sidebar search, project replacement,
Agent completion, or workspace tree visibility. The existing
case-insensitive `*`/`?` matcher applies to a basename or root-relative path (`*`
can span `/`). A trailing `/` explicitly marks a root-relative directory glob:
match it before descending into a directory and against ancestors of directly
reported file updates. A leading `**/` stands for zero or more folders in the
matcher itself, so `**/dist/` covers a root-level `dist` as well as nested ones
(no client has to add the root form). An entry ending in
`/*` or `/**` is the same folder rule as one ending in `/`, so `.lithe/*` hides the
folder and everything below it rather than leaving an empty folder; ordinary file globs
and plain names (such as `.lithe`) retain their file-only semantics. macOS hides the
workspace-root `.lithe` folder by default with the built-in entry `.lithe/**`, like IDEA's
`.idea`; deleting that line (stored as `!.lithe/**`) shows it again. The macOS file
watcher is the one place that does not follow the hiding rules for the workspace-root `.lithe`
folder: hiding it removes it from the tree and listings, but its file events are still
delivered (except built-in noise such as `.lithe/run/local.json`) because editing its JSON
files reloads project services. Empty user exclusions preserve the
normal visibility rules. Search settings changes invalidate only the search
cache, not the workspace tree. Each root retains at most one content and one
names-only rule variant; superseded allocations are released when active
requests finish. Watcher updates refresh the retained variants.
Agent file completion uses project visibility and leaves generated names disabled;
only the Search Everywhere UI explicitly enables them. Directory-versus-file
matching examples are shared in `shared/fixtures/search/exclusions.json`.

`workspace.searchEverywhere` takes an optional `context: { openPaths, recentPaths }` (paths relative to `root`, `/` separators, recent first). It only breaks ties between equal file-name matches (open first, then recent by recency) and scales the returned `matchingDegree` by 1024 plus the tie-break, using the same code as `workspace.rankNames`; omit it and results are unchanged (fixture `shared/fixtures/search/search-everywhere-context-v1.json`).

`workspace.searchEverywhere` uses the same query options and visibility fields,
and additionally accepts `maxSymbolResults` and optional
`includeGeneratedFileNames` (default `false`). Ordinary name queries match
case-insensitive contiguous fragments and camel/word humps, rather than arbitrary
subsequences. Each file/type/symbol bucket is ranked before its requested cap;
the total cap still applies to the file, type, symbol, then content buckets.
A zero `maxFileResults` skips file-name result collection. Text-only queries use
a ready content index, or a names-only inventory with the content visibility rules
and the existing exact matcher while the content index is cold or warming.
Symbol queries still require the content/symbol index. All three zero caps produce
no index builds. Omitted caps retain their
existing defaults. macOS forwards the selected workspace sources through these
existing caps: Actions-only stays local, Text-only requests contents, Files and
Agent completion request names, and Classes/Symbols share the symbol index.
Search module activation does not eagerly build a content index.

Optional `pageSize` (1–200 per source), `cursor`, and `resultKinds`
(`file`, `type`, `symbol`, `content`) enable bounded keyset pages. The response
adds nullable `nextCursor`; absent/null means exhausted. macOS uses 50 per source
and loads another page near the scroll edge, with no 200-result total ceiling.
The opaque cursor binds the workspace/remote identity, query, options, source caps,
visibility rules and page size; clients must resend the same request options.
Each source retains at most pageSize + 1 ranked candidates, using the extra item
to detect exhaustion. No all-matches array or retained search session is created.
Name/symbol continuation scans the existing index to select the next ranked page;
text pages follow path/line order and stop after the lookahead match. Pages observe
the live index: edits inserting a match before the cursor require a fresh query.
Requests without pageSize retain the legacy capped response and schema.
Optional `includePathPatterns`, `excludePathPatterns`, and `pathFilterPrefix`
filter paths before the page limit. Patterns are case-insensitive glob fragments:
`*` excludes separators, `**` crosses them, and `?` matches one non-separator.
When `includeContentRanges` is true, content matches also return the original
`sourceLine` and `contentMatchRanges` in UTF-16 units; existing callers keep the
trimmed `preview` and do not pay for those fields.

Observed `workspace.searchEverywhere` calls may emit
`{ "type": "searchResults", "operationId": "…", "results": { "matches": […] } }`
on the existing request event channel. Each event replaces the previous snapshot;
never append its matches. File-name candidates are searched and published before
building the content/symbol index. The first candidate is sent immediately;
subsequent name/type/symbol candidates are merged for approximately 100 ms,
with a flush at source boundaries. Each snapshot keeps the same ranked per-source
and total caps as the final response, so a later better candidate may replace an
earlier one. Content matches and Git ignore metadata arrive with the authoritative
final response. A partial snapshot's absent `isIgnored` means unknown, not false.
Callbacks remain request-scoped, use the existing cancellation registration, and
finish before the final JSON returns. Calls without an observer retain the same
complete response schema. Cold name-index enumeration and pending index update/
invalidation barriers still precede candidates; this is not a 100 ms end-to-end
latency guarantee.

macOS consumes replaceable snapshots with a newest-only buffer, checks query
generation and cancellation for every update, and keeps selection by result ID
when ranking changes. Closing/resetting or replacing a query cancels its Core
operation; late callbacks cannot overwrite the next query or its loading state.
First-page snapshots remain replaceable; completed continuation pages append with
ID deduplication. macOS keeps each loaded page's order, including actions after the
first names page, so later pages do not insert above the visible viewport. Repeated
cursors or pages with no new IDs stop loading. Failure preserves rows/cursor and
pauses automatic loading until Retry. The input debounce remains 180 ms. Windows
continues to consume the legacy final response; this change does not claim
incremental or automatically paged Windows presentation.
Basename matches rank above relative-path fallback matches, even when the query
contains no slash (for example `src` matches `src/Foo.swift`). Path-only matches
have `matchingDegree: -1` and no basename ranges; literal basename hits use degree
zero when there is no fuzzy degree. See `shared/fixtures/search/path-fallback.json`.

Name matches include optional `matchingDegree` and `nameMatchRanges` entries
`{ start, length }`, measured in UTF-16 units in the displayed basename or
`symbolName`. Clients must not recompute different highlight fragments. Path-qualified
queries may have no basename fragments. Explicit case/whole-word/regex options and
content matches keep their literal search semantics.
Case-insensitive contiguous fallback preserves whole-string Unicode lowercase
matching, including expansions such as `İ` to `i` plus a combining dot. A partial
match inside an expansion highlights the complete original character, not folded
offsets. See `shared/fixtures/search/unicode-contiguous.json` (also used by Agent
completion regressions).

Returned Everywhere matches additionally expose optional `isIgnored`, resolved
by one read-only Git `check-ignore --stdin -z` call for the bounded result set.
`true` means ignored; `false` means Git answered but did not ignore this path;
absence means Git is unavailable, the workspace is not a repository, or the query
failed. Tracked files are never inferred ignored from a matching ignore pattern.
Git owns rule precedence, nested rules, negations, info/exclude and global excludes.
Clients may use this status for filename foreground; it does not change matching,
ranking, UTF-16 match backgrounds, or visibility. macOS uses the Islands editor
scheme's ignored-file color; Windows tolerates the optional status but does not
currently render this foreground.

`includeGeneratedFileNames` opts into a separate in-memory names-only index:
built-in build/dependency directory exclusions (including `.build` and `target`)
do not suppress names, even when callers pass the same default exclusions.
Git metadata and nested worktrees remain excluded; custom directory names and
file/path globs still apply. It does not enable generated-file content or symbol
indexing and does not change `workspace.search`, tree, watcher, or replacement
visibility. Names share index invalidation and reported file updates; changes
inside unwatched generated directories require workspace/index refresh. No index
files or resources are written to disk. macOS Search Everywhere requests pages of
50 matches per source; legacy synchronous consumers retain their requested caps.
Java type and method results still use the existing syntax index and include a
one-based line, `symbolName`, and source line in `preview`; language-provider
workspace-symbol integration and external-library search are not implied.
The shared name/range examples are in `shared/fixtures/search/name-matching.json`.

`workspace.replacePreview` accepts `root`, `query`, `replacement`, the same
query options, optional workspace-relative `paths`, optional `textOverrides`
keyed by relative path, and visibility fields. It returns `{ "files": [] }`
where each file contains replacement matches and the complete
`replacementText` to write. The command never writes files; callers can record
history before using `file.write` for the selected files.

`workspace.replaceText` accepts a host-captured `text`, `query`, `replacement`,
the same case, whole-word and regex options, and an optional one-based `{line,
column}` UTF-16 `from` position. It returns `{text, count}` after replacing all
matches or the first match at or after that position. Matching is per line, and
the command never writes. The host must verify the captured workspace and buffer
or disk identity before publishing a result. `workspace.searchTextBatch` applies
the same matcher to at most 32 host-read `{path, text}` snapshots (at most 2 MiB
per file and 16 MiB in total) and returns
unmodified paths, matching lines, UTF-16 ranges and requested surrounding lines.
The host owns provider I/O and controls continuation between batches.
Examples for these commands and filtered content pages live in
`shared/fixtures/search/text-snapshot-v1.json`.

`lsp.applyTextEdits` accepts `{ "text": string, "edits": [] }`, where each edit
has an LSP range with zero-based `line` and UTF-16 `utf16Column` fields plus
`newText`. Ranges are validated and overlapping edits return
`invalid_request` with details `overlappingEdits`; invalid positions return
details `invalidRange`. Successful responses return `{ "text": string }`.

Windows workspace edits and formatting use this command instead of calculating
text offsets locally. The cross-platform cases in
`shared/fixtures/lsp/text-edits-v1.json` use LSP wire `character` fields; the
Windows adapter maps those fields to Core `utf16Column` without changing their
zero-based values. Core retains its existing normalization: columns beyond a
line clamp before its line ending, and positions inside a UTF-16 surrogate pair
resolve to the character start. Missing/negative lines, negative columns,
reversed ranges and overlapping replacements are rejected.

The line index and batch rules are shared with `editor.planTextEdits`: `\r\n`,
`\n` and a lone `\r` each end one line (as in the LSP specification), and a
batch is applied in a stable order by start, end and then caller order.
Insertions at the same position keep the caller's order, and an insertion at
the boundary of a replaced range is adjacent regardless of where it appears in
the batch.

`lsp.plainSnippet` accepts `{ "value": string }` and returns `{ "text": string }`
after removing LSP tab stops and replacing simple placeholder defaults such as
`${1:name}` with `name`.


`editor.planTextEdits` accepts `{ text, edits, positions? }`. Each edit is
`{ range: { start, end }, text }` with one-based `line` and one-based UTF-16
`column`; `positions` lists extra one-based positions that must exist (for
example reported selection endpoints). It returns `{ lineEnding,
lineSeparator, edits, rejection }`. `lineEnding` is `lf`, `crlf`, `cr` or
`mixed`; `lineSeparator` is the text's first terminator, LF when there is
none. On success `edits` is the stable application order with `index` (caller
order), `utf16Offset`, `utf16Length`, `text` (line breaks rewritten to
`lineSeparator`) and `normalizedText` (LF), and `rejection` is null. Unlike
`lsp.applyTextEdits`, positions are strict: a missing line, column zero, a
column past the line content or a position inside a surrogate pair rejects the
batch. A rejected batch returns empty `edits` and `rejection: { reason,
editIndex, otherEditIndex }` with `reason` `rangeOutOfBounds`, `reversed`,
`splitsSurrogatePair` or `overlappingRanges`, or `{ reason, positionIndex }`
for a failed extra position. An empty batch still reports the line ending.
Malformed payloads return `invalid_request`. The host keeps document versions,
undo grouping and the editor surface. See
`shared/fixtures/editor/text-edit-plan-v1.json`.

`lsp.planWorkspaceEdit` accepts `{ platform, workspaceRoot, changes,
openDocuments? }`, where `changes` maps a file URI or absolute native path to
its text edits and `openDocuments` lists `{ path, isReadOnly? }` for open
editor documents. It returns `{ rejection, targets }`. Every target must be a
workspace file; otherwise `rejection` is `{ code: "outsideWorkspace" |
"readOnlyDocument", path }` and `targets` is empty. On success `rejection` is
null and each target is `{ path, relativePath, effect, edits }` with `effect`
`writeFile` (closed files first) or `updateDocument` (open documents), each
group ordered by `relativePath`; keys naming one file merge. The host reads and
writes files, owns buffers, stale-input checks and rollback, and applies each
target's edits with `lsp.applyTextEdits`. See
`shared/fixtures/lsp/workspace-edit-plan-v1.json`.

`lsp.classifyNavigationTarget` accepts `{ platform, workspaceRoot?,
resolvedWorkspaceRoot?, path, resolvedPath?, sourceLanguageID?, languageID?,
resolvedLanguageID?, isReadOnly? }`; the host supplies symlink resolution and
the path-to-language lookup as facts. It returns `{ classification,
isReadOnly }` where `classification` is `workspace`, `externalReadOnly` (a
source file of the language that produced the jump, opened read-only) or
`rejected`. See `shared/fixtures/lsp/navigation-target-v1.json`.

`editor.parseNavigationInput` accepts `{ text }` and returns `{ target }`.
`target` is null for invalid input, otherwise `{ line, column, selectsWholeLine }`
contains zero-based line and UTF-16 column. One-based positive decimal line and
optional column may have surrounding horizontal whitespace; line terminators,
extra characters, zero, negatives and values above JavaScript's maximum safe
integer are invalid. Text over 128 UTF-8 bytes is invalid. A line-only input
selects its content without the terminator; an explicit column places the caret.
Hosts clamp against the current document, not an old snapshot. See
`shared/fixtures/editor/navigation-input-v1.json`.

`editor.navigationHistory.reduce` accepts `{ state, event }` and returns
`{ state, destination }`. `state` is `{ back, forward }`, each ordered oldest
first, and each location is `{ document, line, column, context? }`. Identity is
`document`, `line` and `column`; coordinates are opaque to Core and `context` is
platform data (pane, scroll, read-only presentation) carried unchanged. Events
are `record { departure, destination? }`, `back { current }` and
`forward { current }`. Recording pushes the departure unless it equals the
destination and clears the forward branch; a repeated position replaces the top
entry so the newest context wins. Back and forward discard entries equal to the
live `current` location, return the next distinct one as `destination`, and
push `current` onto the opposite stack so caret movement since the last jump
survives a return trip. Each stack keeps the newest 100 entries. Platforms
decide which gestures record history and restore their previous state when the
destination cannot be opened. See
`shared/fixtures/editor/navigation-history-v1.json`.

`editor.lineEdit` applies one deterministic line-level transform. All offsets
are UTF-16 code units so both hosts can feed the result straight into their
text engines. The payload is `{ "operation": "toggleLineComment" |
"duplicateLine" | "deleteLine" | "moveLineUp" | "moveLineDown" | "copyLineUp" |
"copyLineDown", "source": string, "selectionStart": 0, "selectionLength": 0,
"commentToken": "//" }`. `selectionStart` and `selectionLength` are clamped
into the document. `commentToken` is required by `toggleLineComment` and
rejected with `invalid_request` otherwise. The response is
`{ "applied": true, "text": "...", "replacedStart": 0, "replacedLength": 9,
"selectionStart": 8, "selectionLength": 0 }` where `text` replaces
`[replacedStart, replacedStart + replacedLength)` and `selection` is the range
to restore. `applied: false` with every other field omitted marks a legitimate
no-op such as moving the first line up; callers must leave their text view
unchanged and must not consume the keyboard shortcut.

`editor.lineCommentToken` accepts `{ "identifier": "py" }` (case
insensitive; the identifier may be a file extension, a file name including
dotfiles such as `.env`, or a language id — extensions, dotfile basenames,
and language ids share one table) and returns `{ "token": "#" }` or
`{ "token": null }` for file types without a line comment token.

macOS consumes both commands today. Windows still uses its local TypeScript
implementations (`comment-toggle.ts`, `line-operations.ts`) and is expected
to adopt the same contract in a follow-up change; the fixture pins the
canonical behavior for that migration. Deterministic cases are pinned by
`shared/fixtures/editor/line-edit-v1.json`.

`network.proxyPolicy` normalizes the stored proxy settings into the policy a
network stack must apply. It accepts `{ "mode": "system" | "direct" |
"custom", "proxyType"?: "http" | "socks5", "host"?: string, "port"?: number,
"username"?: string, "password"?: string, "passwordIdentity"?: {
"proxyType": "http" | "socks5", "host": string, "port": number,
"username": string }, "exclusions"?: string[] }` (`port` must fit in 16 bits,
otherwise the request is rejected with `invalid_request`) and returns
`{ "policy": "system" | "direct" | "custom", "proxyType", "host", "port",
"username", "password", "exclusions", "configured" }`.

An optional `passwordIdentity` binds a restored password to its saved proxy
type, host, port and username; a mismatch removes the password. Host matching
is ASCII case-insensitive after trimming; usernames are case-sensitive after
trimming. Omit the identity only for a password explicitly entered for this
candidate, never for a restored secret. Hosts persist the identity together
with the secret in the OS credential vault, not as independently mutable
preferences. Legacy unscoped saved passwords require re-entry rather than
being rebound to the current endpoint.

Hosts and usernames are trimmed, empty exclusion entries are
dropped, and passwords keep every character. A custom server without a host
or port normalizes to `policy: "system"` with `configured: false`; system and
direct never carry credentials, so hosts can forward the plan to their network
stack without a second credential-scoping decision. Deterministic cases are
pinned by `shared/fixtures/network/proxy-policy-v1.json`.

The `debug.*` commands are the shared Debug Adapter Protocol boundary. Rust
owns DAP framing, request sequences, response correlation, initialization and
execution state, deterministic breakpoint sets, and normalized thread, stack,
scope, variable, evaluation, output, stop, continue, and termination events.
Platforms own adapter discovery, JDT LS activation, sockets or process pipes,
native process termination, persistence, and UI rendering.

`debug.validateAdapterEndpoint` accepts exactly `{ host, port }`. `host` is a
bare IPv4, unbracketed IPv6, or DNS name, not a URL, authority, credential,
path, or scoped address; `port` is an integer from 1 through 65535. It returns
`{ host, port, remote }`, preserving the input. `localhost` (case insensitive),
127.0.0.0/8 and `::1` are loopback; every other spelling requires remote
consent, without resolving DNS. Invalid inputs return `invalid_request`.
Compatibility cases live in `shared/fixtures/debug/adapter-endpoints-v1.json`.
The platform obtains approval before connecting a non-loopback endpoint, once
per connection with no remembered approval, and warns that plain TCP provides
neither authentication nor encryption. This endpoint is the **IDE-to-adapter**
address, not a `targetBindings.connection` debuggee address.

The macOS launch envelope may carry optional `adapterEndpoint: { host, port }`
beside `arguments`. Its session manager selects an already-running DAP server
instead of starting a local adapter. Missing platform support fails without a
local fallback. This host-only field is not forwarded as DAP arguments: Core's
launch configuration ignores it. `request` still independently chooses `launch`
or `attach`. The provider's language-server port source remains loopback-only.
Closing the byte stream never terminates the external server, shared language
server or user-managed tunnel. DAP disconnect retains its request-specific
ownership: an `attach` sends `terminateDebuggee: false`, while a `launch` can
terminate the debuggee it launched. On user stop, the TCP host makes a
bounded best-effort drain of queued frames (including disconnect) for up to one
second before closing; this is local write completion, not a remote acknowledgement.
Failure and explicit transport abort close immediately. There is no automatic reconnect or request
replay. Proxy/tunnel implementations and plugin `tcpPort` / `tcpAnnounced`
process hosting are not enabled by this API.

The `debug.transport.*` commands hold the lifecycle rules of that byte stream
so every platform network layer shares one rule set. They are separate from the
DAP session state: Core never opens a socket, resolves DNS, reads a clock or
sees the bytes. The platform keeps the socket, the DNS and system timers, and
the queued frames; only byte counts cross the JSON boundary.

`debug.transport.policy` ignores its payload and returns `{ limits,
initializationMilliseconds }`. `limits` holds `discoveryMilliseconds` (10000,
endpoint discovery such as a cold language-server start), `connectMilliseconds`
(10000), `writeMilliseconds` (10000, one stalled write, never the length of a
session), `bufferedBytes` (8 MiB), `bufferedWrites` (1024) and
`drainMilliseconds` (1000). `initializationMilliseconds` is the connect budget
plus 10000, the window a DAP `initialize` round trip gets, so a session never
gives up before its transport does.

`debug.transport.handle` accepts exactly `{ transportId, event }` and returns a
step `{ generation, phase, outcome, effects }`. `transportId` is a host-chosen
non-empty identifier of at most 512 bytes. Only a `start` event creates a
transport. A callback for an unknown or released one is `ignored`, and `send`
to it is `rejectedNotRunning`. `event.type` is one of:

- `start { limits? }` begins a lifecycle; `limits` overrides any of the six
  defaults with an integer from 1 through 2147483647, otherwise
  `invalid_request`. A repeat while running is `ignored`. A `start` while the
  previous lifecycle is draining replaces it.
- `send { bytes }` queues one frame of that size. The host keeps the bytes in
  first-in, first-out order. An empty frame is accepted and queued as nothing.
- `stop {}` is a user cancel: silent teardown, no termination.
- `finishSendingAndStop {}` flushes queued frames of a ready stream for at most
  `drainMilliseconds`, then closes silently; with nothing queued or before the
  stream is ready it closes at once. While draining, new `send` is
  `rejectedNotRunning`, received data is `ignored` and any failure is silent
  because the owner already released its session.
- `endpointResolved { generation, host, port }`, `connectionReady`,
  `dataReceived`, `peerClosed`, `failed { message }`, `writeCompleted {
  writeId }` and `timerFired { timerId }`, each carrying the `generation` the
  host captured when it started the work being answered. `port` is a signed
  integer so that an out-of-range provider value fails the transport
  (`invalidEndpoint`) instead of the request.

Every event field is checked strictly: an unknown event, an unknown field or a
missing field is `invalid_request`.

`generation` rises whenever outstanding work is invalidated (a start, a finish,
a stop). A callback whose generation is not the live one, or that arrives in
the wrong phase, is `ignored`. Timer and write ids are unique per transport and
never reused, so a timer the host failed to cancel and a write completion from
a replaced write are `ignored` too. `phase` is `stopped`, `discovering`,
`connecting`, `ready` or `draining`. `outcome` is `applied`, `ignored`,
`rejectedNotRunning` or `rejectedBufferLimit`. The last one means the queue went
over its byte or count budget: Core has already failed the transport and the host
rejects that one `send`.

`effects` is an ordered list the host runs top to bottom:

- `discoverEndpoint` asks for the endpoint and reports `endpointResolved` or `failed`.
- `armTimer { timerId, purpose, afterMilliseconds }` and `cancelTimer { timerId }`.
  `purpose` is `discovery`, `connect`, `write` or `drain`. The host reports
  `timerFired` when an armed timer elapses.
- `connect { host, port }` opens the socket; `port` is already 1 through 65535.
- `write { writeId, bytes }` sends the oldest queued frame, which has that size,
  and reports `writeCompleted` or `failed`. At most one write is in flight.
- `deliverData` forwards the received bytes to the owner.
- `close` cancels pending discovery, unhooks and stops the socket and drops
  queued frames.
- `reportFailure { reason, message? }` shows the failure on the owner's error
  output. `reason` is `startupTimedOut`, `writeTimedOut`, `bufferLimit`,
  `invalidEndpoint` or `host`. The platform owns the localized text of the first
  four; for `host` the message is the host's own upstream diagnostic, echoed
  back unchanged.
- `notifyTermination { exitCode }` ends the owner's session: 0 for a clean peer
  close, 1 after a failure. It comes last, after `reportFailure`.

A host that re-enters Core while it runs a step's effects, for example an error
observer that restarts the transport, compares the live generation with the
step's and abandons the remainder of the older step. `debug.transport.release`
accepts `{ transportId }` and returns `{ released }`; hosts call it after `stop`
once they dropped the socket. Releasing a registration resets its generation,
timer and write counters. A host that restarts after releasing Core state must
use a fresh `transportId` and reject callbacks from the previous registration
before dispatching them or touching native timer handles. Host-side Core call
failures must tear down native resources for `send` as well as callback events;
an error observer restarting the stream invalidates the old termination too.
Scripted scenarios, with the exact steps expected,
live in `shared/fixtures/debug/transport-lifecycle-v1.json`; platform adapter
tests can replay them.

`debug.createSession` accepts `{ sessionId, adapterId, rootPath,
supportsRunInTerminalRequest, disabledCapabilities? }`.
`disabledCapabilities` carries the plugin adapter's `capabilities.disabled`
from the launch plan; Core forces those DAP capabilities off in the session's
published capabilities, and a host that omits the field disables nothing. It does not
open a socket or launch a process. It returns a session update in
`initializing` state with an ordered `outboundFrames` array. Each frame is a
complete Content-Length-framed byte sequence encoded as base64. Every Debug
command returns the same update shape: `{ sessionId, state, outboundFrames,
events }`. The platform writes frames in array order and feeds received chunks
back through `debug.receive` as `{ sessionId, dataBase64 }`; partial and
consecutive messages are buffered and reduced in Rust.

When `supportsRunInTerminalRequest` is true, the initialize frame advertises
the native host's terminal capability. An adapter `runInTerminal` reverse
request becomes a deterministic `runInTerminalRequested` event containing a
Core-generated `requestId`, terminal kind, title, working directory, ordered
argument vector, sorted environment changes, and shell-interpretation flag.
The platform launches the process through its PTY/ConPTY adapter and calls
`debug.runInTerminalResponse` with `{ sessionId, requestId, success, processId?,
shellProcessId?, message? }`. Core validates process identifiers, emits the DAP
response, ignores duplicate or expired completions, and fails pending terminal
requests when the session disconnects. The shared compatibility cases are in
`shared/fixtures/debug/run-in-terminal-v1.json`.

`debug.launch` accepts an `operationId` and a language-neutral configuration
containing `name`, request kind (`launch` or `attach`), provider arguments, and
optional portable `steppingFilters`.
Test launches are not a Core command: a debug adapter plugin resolves test
selections to launch arguments in its own backend and submits them through
`debug.launch` like any other configuration.
Launch submitted during initialization is retained until the initialize
response. Core projects the stepping filters into the launch argument the
adapter declared in its `stepFilters` feature unless the provider arguments
already contain an explicit value; an adapter without that declaration never
receives invented launch arguments.
`debug.steppingFilters` accepts `{ adapterId, filters? }`; omission of `filters`
returns an unfiltered policy, while a supplied value is trimmed,
sorted, de-duplicated, and validated before persistence or launch. Omitted
fields inside a supplied value are empty or false, so adapters never inherit
another adapter's policy. Adapter defaults come from the plugin's declared
debug-adapter defaults, and class patterns are passed through to the adapter
unchanged, so an adapter may use its own placeholder and wildcard syntax.
The portable cases are in
`shared/fixtures/debug/stepping-filters-v1.json`.

Normalized stack frames include `isFiltered`. Core derives it from the active
class filters using the DAP frame name, source path, presentation hint, and
session root. This classification is presentation metadata only: Core returns
the complete ordered stack, while native UIs may collapse consecutive matching
frames and must allow users to expand them. `debug.setBreakpoints` accepts
one-based line and optional column,
enabled state, condition, hit condition, and log message values. Rust sorts and
de-duplicates the complete source set, retains disabled entries without sending
them to the adapter, waits for the DAP `initialized` event, then sends all
sources in deterministic path order followed by `configurationDone` when the
adapter supports it. This allows native products to mute or restore breakpoints
without maintaining a second protocol representation.

`debug.setExceptionBreakpoints` accepts adapter-defined filter identifiers,
enabled state, and an optional condition. Rust trims, sorts, and de-duplicates
the complete selection, retains disabled filters without sending them, and uses
DAP `filterOptions` only when the adapter negotiated that capability. Before a
native client has configured a selection, Rust adopts the adapter's declared
defaults so the first `initialized` flow sends exception filters before source
breakpoints and `configurationDone`.

`debug.setFunctionBreakpoints` accepts a method or function name, enabled
state, condition, and hit condition. Rust retains the complete sorted set,
omits disabled entries, and sends DAP `setFunctionBreakpoints` before source
breakpoints only when the adapter negotiated function-breakpoint support.

Data breakpoints use DAP's required two-step flow. The native client first calls
`debug.dataBreakpointInfo` with the selected variable name plus its parent
`variablesReference` and current frame. Rust Core correlates the response by
`operationId` and returns the adapter-owned `dataId`, display description,
allowed access modes, and `canPersist`. The client then calls
`debug.setDataBreakpoints`; Core keeps the complete deterministic set, omits
disabled entries, and sends access type, condition, and hit count only when the
adapter negotiated data-breakpoint support. Native clients must discard IDs
whose `canPersist` is false when the debug session ends.

`debug.setInstructionBreakpoints` replaces one session's instruction (address)
breakpoints. Each entry carries an opaque `instructionReference` (the address
string the adapter reported, never a JSON number, because a 64-bit address can
exceed the JavaScript safe integer range), an optional byte `offset`, `enabled`,
`condition`, and `hitCondition`. Core validates the reference text, sorts and
deduplicates by reference and offset, keeps the set in the session, and sends DAP
`setInstructionBreakpoints` only after the adapter advertised
`supportsInstructionBreakpoints` and sent `initialized`. Clients keep the set per
session and never persist or replay it: an address is only valid for one run of
one process.

`debug.execute` accepts an optional `granularity` of `statement`, `line`, or
`instruction` on `next`, `stepIn`, `stepOut`, and `stepBack`. Core forwards it as
the DAP `granularity` argument only when the adapter advertised
`supportsSteppingGranularity`; otherwise it omits the field and the adapter steps
by its default unit. Clients use `instruction` while a disassembly view is open.

`debug.inspect` also accepts the kinds `disassemble` and `readMemory`. Both take
an opaque `memoryReference` and are rejected unless the capability snapshot
reports them supported (`adapter` and registered extension and `authorized`) and
the session is paused. `disassemble` additionally takes `offset` (bytes),
`instructionOffset` (negative asks for instructions before the reference),
`instructionCount`, and `resolveSymbols` (default true), and returns
`instructions` with `address`, `instructionBytes`, `instruction`, an optional
`symbol` on the first instruction of a symbol, and an optional `sourcePath` and
`line`. `readMemory` takes `offset` and `count` and returns `address`,
`unreadableBytes`, and base64 `dataBase64`, like DAP. Core never does address
arithmetic and never opens `writeMemory`: reading is the only memory operation,
and writing would need its own authorization. Both results are tied to the
`stopGeneration` they were requested in, so a late reply after the debuggee
resumed is dropped as stale.

A stack frame without debug info has no usable file or line. When the adapter
sends neither a source path nor a `sourceReference`, Core reports
`line` 0 and no `sourcePath` for it, and carries the adapter's
`instructionPointerReference` so clients can anchor the disassembly on the frame
instead of showing a made-up file or line 1. A scope whose DAP
`presentationHint` is `registers` is passed through with that hint; the host has
no register table of its own, so register names, groups, and values are the
adapter's. The compatibility cases are in
`shared/fixtures/debug/projection-v2-examples.json`.

`debug.setVariable` accepts the selected variable's parent `variablesReference`,
name, and replacement text. Core permits mutation only while paused and after
the adapter advertises `supportsSetVariable`, then returns the adapter's
normalized replacement value and optional type through the caller's
`operationId`.

`debug.execute` covers continue, pause, step over, step in, step out, step back,
restart, terminate, and capability-gated single-thread execution. Rust Core rejects stepping unless the session is paused
and a thread is selected, and gates step back, restart, and terminate against
the adapter capabilities negotiated during initialization. Restart and
terminate are session-level requests and never receive a stale `threadId`.
Single-thread pause, continue, and stepping preserve the paused session when
the adapter reports that other threads remain stopped.

`debug.cancelOperation` removes the matching pending request before emitting a
terminal failure, so a late adapter response cannot mutate current UI state. If
the adapter advertises `supportsCancelRequest`, Core also sends DAP `cancel`
with the original request sequence. Native hosts own monotonic deadlines and
invoke this command with `cancelled` or `timedOut`; the macOS reference product
uses a bounded 10-second deadline for interactive inspections and mutations.

Smart step into and run to cursor keep DAP's target lookup explicit. Clients
use `debug.inspect` with `stepInTargets` and a frame, or `gotoTargets` with a
source path and one-based cursor coordinates. Core normalizes the returned
targets and correlates them to the caller's operation. The selected target is
then passed as `targetId` to `debug.execute` using `stepIn` or `goto`; both
flows are rejected unless the adapter advertised the matching capability.

The successful DAP initialize response emits a normalized `capabilities` event.
It includes conditional, hit-count, log, function, data, and exception
breakpoint support; variable mutation; restart and terminate requests; step
back; exception information; request cancellation; single-thread execution;
step-in targets; goto targets; console completions; and ordered exception filters. Native UIs
must treat capability state as unknown until this event arrives and hide or
disable unsupported actions after negotiation.

`debug.execute` correlates continue, pause, next, step-in, and step-out to the
caller's `operationId`. `debug.inspect` supports `threads`, `stackTrace`,
`scopes`, `variables`, `evaluate`, and capability-gated `exceptionInfo`;
required thread, frame, variable reference, and expression fields are validated
before a request is emitted. A `variables` inspection may additionally carry
`variableFilter` (`named` or `indexed`), zero-based `start`, and positive
`count`; Core maps them to DAP `filter`, `start`, and `count` and rejects those
fields for every other inspection kind. Normalized scopes, variables,
evaluations, and variable-mutation results include non-negative
`namedVariables` and `indexedVariables` counts, using zero when the adapter
omits or reports an invalid negative value. The compatibility cases are in
`shared/fixtures/debug/variable-paging-v1.json`.

An `evaluate` inspection may carry `context` (`watch`, `hover`, `repl`,
`clipboard`, or `variables`) and defaults to `watch`. Native consoles send
`repl`, which adapters such as lldb-dap use to run their own debugger commands
(`bt`, `p total`) and answer with plain text in the evaluation result. Other
inspection kinds ignore `context`; Core rejects any value outside that list.

A `completions` inspection asks the adapter for Debug Console proposals. It
carries the typed text in `expression`, an optional UTF-16 caret `column` that
counts from 1 and defaults to the end of the text (Core rejects a caret outside
the text), and an optional `frameId`. It is rejected unless the adapter
advertised `supportsCompletionsRequest`. The result lists items with `label`,
`text` (the label when the adapter sends none), optional `detail` and `kind`,
and an optional `start`/`length` range of the typed text the item replaces, in
zero-based UTF-16 units. Adapters such as lldb-dap send no range; the client
then replaces the word ending at the caret. Items without a label are dropped.

A normalized stack frame carries `sourceReference` when the adapter serves the
frame's source itself (a positive DAP `source.sourceReference`, for example
lldb-dap's `dyld\`start`). Such a frame has no file the editor can open, so
native clients must not treat its `source.path` as a workspace file.

Exception information is available only while
paused and normalizes the exception type, description, break mode, optional
stack trace, evaluation name, and nested exception details. The Java adapter
currently supplies the type, description, and break mode but no expandable
exception object reference, so native clients continue to inspect ordinary
frame scopes for local state.
Terminal operation events are exactly one of `operationCompleted` with a typed
result or `operationFailed` with the adapter command and safe message. Other
ordered events are `stateChanged`, `initialized`, `output`, `stopped`,
`continued`, `terminated`, and `breakpoint`. Source coordinates are one-based.
Source breakpoint confirmations include optional `requestedLine` alongside the
adapter-resolved `line`. Core retains their association by adapter breakpoint ID,
so later location-free `breakpoint` events preserve both the requested anchor and
resolved location. Responses to superseded per-file sets are discarded. Platforms
persist the requested anchor and may display the resolved line; placement alone
does not imply that bytecode was bound or that execution will suspend there.
The correlation fixture is `shared/fixtures/debug/breakpoint-binding-v1.json`.
The compatibility flow is captured in
`shared/fixtures/debug/dap-session-v1.json`; exception normalization cases are
captured in `shared/fixtures/debug/exception-info-v1.json`.

`debug.disconnect` emits the protocol handshake and enters `terminating`.
Core derives DAP `terminateDebuggee` from the session's request kind: `launch`
uses `true`, while `attach` and a session stopped before either request use
`false`. This prevents a remote detach from killing a JVM the IDE does not own.
The compatibility cases are in
`shared/fixtures/debug/disconnect-policy-v1.json`. The platform keeps the
socket or process alive long enough to flush the frame, then closes it and
calls `debug.destroySession`. A session allocates no process, socket, timer, or
background task, and no session exists until Debug is used.

A child session never outlives its parent. `debug.destroySession` removes every
descendant together with the parent and returns their IDs as
`destroyedChildSessionIds`, so the platform can close those transports instead
of leaving them attached to a session Core no longer knows.

`lsp.builtinCompletions`, `lsp.builtinHover`, and `lsp.builtinNavigation` are
the no-process lightweight language path. They accept current-file text, an
absolute `filePath`, and a zero-based LSP position. Completion returns
current-file identifiers with text edits for the active prefix. Hover returns
the current identifier as markdown. Navigation returns current-file locations;
definition prefers declaration-looking occurrences, while references returns
all matching identifier occurrences. These commands are deliberately
text-level fallbacks; precise type-aware behavior belongs to a started language
server.

`lsp.mergeCompletions` accepts `{ lists: [{ labels, isIncomplete }] }` ordered
from the highest-priority provider to the lowest and returns
`{ keep: [[index]], isIncomplete }`. A provider's own candidates are never
collapsed, so overloads that share a label stay visible; a lower-priority
candidate is dropped when a higher-priority provider already offered the same
label. Only labels cross the boundary and the platform applies the indices to
its full items. A host with a single completion provider (Windows today) keeps
that provider's list unchanged and does not call the command. Cases:
`shared/fixtures/lsp/completion-merge-v1.json`.

`lsp.activationPolicy` accepts `{ state, event, nowMs }` and returns
`{ state, decision, retryAfterMs }`. `event` is `automaticStart`,
`explicitStart`, `startFailed`, or `ready`; `decision` is `allow`, `wait`, or
`explicitRetryRequired`. The platform stores the returned `state` per server
identity (language or provider plus workspace root) and passes it back
verbatim; `null` means no failure history. After each failure automatic starts
wait 5000 ms, and after 3 consecutive failures only an explicit start (restart,
retry, or repair) may run. A ready session or an explicit start clears the
history. `nowMs` must come from a monotonic clock; a reading earlier than the
stored failure restarts the cooldown. Cases:
`shared/fixtures/lsp/activation-policy-v1.json`.

`lsp.problems.query` accepts the displayed diagnostics as
`{ fileKey, displayPath, line, column, severity, message, source, code }`
together with `groupBy` (`file` default, `severity`, `none`), `sortBy`
(`severity` default, `file`, `position`), and an optional `filter`
(`severities`, `fileKey`, `source`, `query`). It returns `groups` (each with a
stable `key`, `indices` into the submitted list, and per-severity `counts`),
`files` (file summaries in file order regardless of `groupBy`),
`visibleCounts`, and `totalCounts`. `fileKey` is the platform's native file
identity; `displayPath` is the workspace-relative path and orders files with
the Project view's natural file-name order. Severity is the LSP number;
missing or out-of-range values are unknown (`0`) and rank last. Cases:
`shared/fixtures/lsp/problems-query-v1.json`.

The LSP provider catalog is returned by `lithe_core_lsp_provider_catalog_json`.
Each provider descriptor may include `languageServerLaunch` with ordered
`executableNames` and `arguments`; Swift adapters use this metadata when they
need to discover a real language-server executable; the selected launch plan is
then submitted to the Rust-owned runtime. Built-in descriptors are merged by provider ID with the optional
`.lithe/lsp/language-providers.json` workspace document. See
[`.agents/notes/implemented/architecture/2026-09-13-language-tooling-and-lsp-runtime-ownership.md`](../../.agents/notes/implemented/architecture/2026-09-13-language-tooling-and-lsp-runtime-ownership.md)
for routing, discovery, lifecycle, and compatibility rules.

The `lsp.*Server`, `lsp.*Document`, `lsp.request`, `lsp.pollEvents`, and
`lsp.waitEvents`
commands are the semantic LSP runtime boundary. `lsp.startServer` accepts the
provider ID, selected executable/arguments/environment, root URI, working
directory, initialization options, optional runtime executable,
`jdtlsLaunchResources`, cache directory, `workspaceFingerprint`, and the
optional `pluginId` of the plugin that owns the process, its optional
`workspaceConfiguration` (an object, plugin-owned sessions only), its
optional `hostServices` (the launch plan's `backend.hostServices`;
plugin-owned sessions only; legacy service grants or full public host-method names Core defines),
its optional `hostOptions` (plugin-owned sessions only; `editor:{actionIcons,
actionSourceBytes, providerTypes}` declares the icons, collector source bound and
provider types the host implements, reported through `lithe/host/getCapabilities`
to sessions granted the matching editor methods), plus
initialize, post-initialize readiness, request, Java project build
(`javaBuildTimeoutMilliseconds`), and shutdown deadlines.
Java callers may also provide the versioned `mavenContext` accepted by
`maven.launchPlan`. Core validates its reactor and recursively declared modules,
publishes the user-level settings through
`java.configuration.maven.userSettings` and the selected installation's
`conf/settings.xml` through `java.configuration.maven.globalSettings`, and,
after `ServiceReady`, sends one
`java.project.updateSettings` command per Maven project with
`org.eclipse.m2e.core.selectedProfiles`. Maven Java, test, and generated source
roots are normalized to workspace-relative `java.project.sourcePaths` during
the same configuration flow, so JDT LS receives the selected reactor's source
model without platform-specific POM parsing. Both settings documents are passed as content-addressed copies inside the
session's JDT LS state directory (`<data>/.lithe/maven/`). The user-level copy
comes from `settingsPath`, else Maven's default `~/.m2/settings.xml`, else an
empty document when only `localRepositoryPath` is set, and carries that local
repository override. JDT LS detects settings changes by comparing paths, so a
content change must always produce a new path. An unreadable document is passed
by its original path with a session warning instead of failing startup.
Copies remain readable until JDT workspace cache eviction or index rebuilding;
notification delivery is not an acknowledgement that the server read them.

Gradle callers may also provide `javaGradle = { wrapperPresent, offline?, userHome? }`, where
`wrapperPresent` reports whether the root ships
`gradle/wrapper/gradle-wrapper.properties`. When present, Core states
`java.import.gradle.enabled` in `settings.java` and, if that descriptor exists,
`java.import.gradle.wrapper.enabled`. Both leaves equal JDT LS's own defaults,
so the section declares the import behavior Lithe relies on instead of changing
it; Buildship itself decides which distribution to use, honoring the wrapper only
when the project ships that descriptor. Settings that require reading the build
script (`java.home`, `version`) are never guessed. `offline` and `userHome`
are the user's own build options, as `build.languageImport` maps them from the
plugin that declares the Gradle build system; Core sends
`java.import.gradle.offline.enabled` and `java.import.gradle.user.home` only
when they are set, and the session keeps them until it restarts. A workspace
whose root declares no Gradle build file sends no `javaGradle` and therefore
receives no `java.import` settings.

`lsp.updateMavenConfiguration` accepts `{ sessionId, mavenContext,
reloadProjects? }` for a running Java session started with a `mavenContext`,
and returns `{ settingsChanged, projectsReloaded, profilesUpdating }`. When the
settings copies differ from the ones JDT LS holds, Core sends
`workspace/didChangeConfiguration` and JDT LS force-updates every Maven project
itself. When they are unchanged and `reloadProjects` is `true`, Core sends
`java/projectConfigurationsUpdate` for the reactor's project URIs, which
re-resolves dependencies even though no `pom.xml` changed. Changed profiles
restart the profile task once the session is ready. Before the `initialized`
handshake, the new configuration replaces the one the pending settings
notification sends. Explicit reloads received before `ServiceReady` are coalesced
and sent once projects are ready, even when settings are unchanged. Response
booleans describe actions sent immediately, not queued work. A newer profile
selection is applied after the preceding batch terminates, including failed
batches; timed-out requests must all drain before that follow-up can start.
The same failed selection is not automatically retried.
A stopped or failed session returns `invalidRequest`.
Resolution problems are not part of the response; JDT LS reports them as
`pom.xml` diagnostics.

Maven profile application is a
bounded background task: at most eight project commands are in flight, remaining
projects are queued, and each project reports `running`, `succeeded`, or
`failed` with optional error details. Project results use a redacted stable
`projectUri` identifier; they never expose the user's absolute workspace path.
The runtime event also carries the aggregate Maven task status (`running`,
`succeeded`, `partiallySucceeded`, `failed`, `timedOut`, or `cancelled`) so hosts
do not need to infer task completion from log text. A project failure or task timeout does not
terminate an otherwise usable JDT LS session; the host receives a partial-failure
event and may retry. The session reaches `ready` after JDT LS `ServiceReady`.
Core only accepts retries for a ready Java session. A timeout sends `$/cancelRequest`
but retains each in-flight slot until its terminal response arrives. Retry is
rejected while the previous batch is still stopping; if JDT LS never responds,
the user must restart the Java session. Late responses release those slots
without changing the timed-out results.
Hosts reset project results on the structured `mavenProfileTask: "running"`
event and consume `mavenProfileProject` updates directly, scoped to the current
session. Java import completion and Maven task completion use separate UI
notifications so service readiness cannot overwrite a Maven failure.
The session continues to expose profile progress independently. `initializeTimeoutMilliseconds`
only bounds the standard LSP handshake. For a provider such as JDT LS that has
a later readiness signal,
the profile task records a deterministic digest of Maven settings, selected
profiles, project URIs, and source paths; an unchanged successful digest skips
reapplying the same settings, while an explicit retry invalidates that digest.
Hosts may consume lifecycle events for the shared `serverConnected`,
`projectImporting`, `profileApplying`, and `fullyReady` phases.
`serviceReadyIdleTimeoutMilliseconds` retains its wire name but now sets the
quiet-progress **warning** threshold (45 seconds by default). A quiet interval
emits one warning with the last progress snapshot; changed progress rearms the
warning, while duplicate progress does not. JDT progress is not a heartbeat:
silence must not fail the session or terminate its process.
`serviceReadyAbsoluteTimeoutMilliseconds` remains the sole post-initialize
readiness deadline (10 minutes by default), regardless of progress activity. `jdtlsLaunchResources`, when present,
contains `launcherJarPath`, `configurationDirectory`, `lombokAgentPath`, the
legacy optional `javaDebugBundlePath`, and ordered
`javaExtensionBundlePaths`. It is valid only for the Java provider and requires
`runtimeExecutablePath`. Rust loads the legacy Debug bundle first when present,
then appends the extension bundle paths with stable de-duplication. Rust
then uses `runtimeExecutablePath` as the process executable and constructs the
complete deterministic JDT LS JVM argument list. `configurationDirectory` names
the packaged, read-only configuration; Rust never passes it to Equinox, which
writes framework state into its `-configuration` directory. Rust copies the
directory's `config.ini` into
`cacheDirectory/jdtls-configuration/<config.ini SHA-256>/configuration`,
rewrites a missing or damaged copy, and passes that directory instead. A
`cacheDirectory` that resolves inside the JDT LS installation, including
through a symbolic link, fails with `invalid_request` before anything is written;
a missing `config.ini` fails with `process_start_failed`. Areas of other digests
unused for the JDT cache retention period are removed after the area is
prepared, and a removal failure is logged without failing the start. When the structured object is
absent, the selected `executablePath` and legacy wrapper arguments remain the
compatibility path. Rust owns the returned
session's child process, stdin/stdout/stderr, framing buffer, JSON-RPC request
IDs, document versions, pending deadlines, capabilities, diagnostics, and
graceful/forced termination.

If ordinary `lsp.startServer` fails after process creation, Core retains any
incomplete disposal in an internal cleanup backlog, since no session identity
was returned to the caller. A subsequent explicit startup attempt retries at
most one bounded disposal and refuses to launch another process while cleanup
remains incomplete. The original startup error is preserved. Native owners
using the in-process registration callback retain their registered identity
even when startup returns an error and retry `lsp.destroyServer` themselves.

JDT LS remains `initializing` until `language/status: ServiceReady`. During this
phase Rust reduces changed `$/progress` notifications into throttled JSON log
details containing the current phase, percentage, project, observed project
count, artifact name, repository host, downloaded/total bytes, calculated
throughput, elapsed/idle durations, and cache disposition. Progress parsing is
observability-only and never substitutes for `ServiceReady`. Absolute readiness failures use `serviceReadyTimeout` at stage `serviceReady`
and retain the final diagnostic snapshot in `underlyingMessage` with
`timeoutKind: "absolute"`. Classification still describes observed silence or
transfer activity; it does not prove a JVM deadlock. Quiet warnings preserve the
initializing/preparation state. Explicit server errors and exits still fail
immediately. Shared timing examples live in
`shared/fixtures/lsp/jdt-readiness-v1.json`.

Platform adapters own filesystem discovery and validate that packaged JDT LS
contains the Equinox launcher, platform configuration directory, Lombok agent,
Java Debug Server, and bundled Java. Java Test-capable hosts additionally
validate their extension bundles and runner. They do not construct JVM commands.
Packaged macOS and Windows plans always use structured direct launch, so runtime
startup has no shell, PowerShell, or user-`PATH` dependency. Wrapper launch
remains optional only for external or older plans.

For JDT LS, platform adapters observe which root Maven/Gradle descriptors
exist, names of direct Maven module directories, the Gradle wrapper's
`distributionUrl` when the workspace has one, and the selected JDT LS version. They submit those raw observations to `java.jdtWorkspaceFingerprint`;
Rust Core validates, sorts, de-duplicates, and constructs the sole portable
fingerprint representation. Core then hashes the normalized workspace identity
followed by a null separator and that opaque fingerprint to select
`cacheDirectory/jdtls/<workspaceKey>`.
Omitting the fingerprint preserves the legacy path-only key for older clients.
Changing structure selects a new directory without deleting the old one, so a
later switch back can reuse it. Editing a descriptor is not a structural change:
JDT LS compares each POM and Gradle file's timestamp with the state it saved and
updates only the changed projects on restart, and running sessions receive the
edit through `lsp.workspaceFilesChanged`. Keying the directory on descriptor
timestamps would discard the whole index after any touch of the file. The Gradle
version is the exception: JDT LS does not check the wrapper descriptor, so the
wrapper's `distributionUrl` takes part in the fingerprint and a version change
selects a fresh directory.

Core starts JDT LS with
`-Djava.import.generatesMetadataFilesAtProjectRoot=false`, so the Eclipse
project files JDT LS maintains (`.project`, `.classpath`, `.factorypath`, and
`.settings/*.prefs`) live in that state directory instead of the user's
modules. Before launch, Core removes such files that earlier versions left in a
Maven or Gradle module directory when the enclosing Git repository does not
track them; tracked files and workspaces outside Git are left alone because JDT
LS keeps honoring files that already exist at a module root. Tracking is decided
by the repository that owns each module, located through its `.git` entry, with
one batched `git ls-files` query per repository; modules outside Git start no Git
process. When any file is removed, Core also deletes the current state directory
so the launch imports the modules afresh instead of reusing a model that points
at the removed files, and records the removed workspace-relative paths in the
session's `info` log event.

`java.jdtWorkspaceFingerprint` accepts
`{ buildFiles, directMavenModules, gradleWrapperDistribution?, jdtlsVersion }`.
Each build-file observation contains only a workspace-relative `path`;
`gradleWrapperDistribution`, when sent, must not be blank. It returns `{ workspaceFingerprint }`; platforms must not recreate
or parse this opaque string. Compatibility cases are in
`shared/fixtures/lsp/jdt-workspace-fingerprint-v1.json`.

`lsp.jdtWorkspaceKey` accepts `{ workspaceRoot, workspaceFingerprint? }` and
returns `{ workspaceKey }` through the same normalization and SHA-256 algorithm
used by `lsp.startServer`. Platform cache-maintenance actions use it to remove
only the current workspace/fingerprint directory; they do not clear sibling
workspaces or older structural states.

`java.runMarkers` accepts `{ mainMethods, testItems, testCases }`: the
`methods` of one file's `javaMainMethods` answer, the `items` of its
`javaTestItems` answer (empty when the platform cannot run tests for the file),
and canonical build-provider report cases (`suite`, `case`, `status`). The older
`className`/`method` field names remain accepted for Windows compatibility.
It returns `{ markers }` ordered by
zero-based `line`, then `kind` (`main`, `testClass`, `testMethod`). `endLine`
is the last line of the declaration as reported upstream: the end of the body for
test classes and methods, and the name line for `main`. Each marker
has a `label` for menus (`App.main()`, `OrderTest`, `OrderTest.creates`), the
launch target (`mainClass`/`projectName`, or `testClass`/`testMethod` and the
Java Test `testItemId`), and `status`: `none`, `passed`, `failed` (failure or
error), or `skipped`. Test cases match a method by class and method name, with
nested-class `$` and `.` treated alike. A class is `failed` when any recorded
method under it (including nested classes) failed and `passed` when at least
one passed and none failed. Items without a source range, such as inherited
test methods, get no marker. The command is pure and never reads the file
system. `shared/fixtures/java/run-markers-v1.json` is the compatibility fixture.

`java.workspacePolicy` accepts `workspacePaths` and `changedPaths` as
workspace-relative paths. It starts Java tooling when a non-ignored `.java`
source exists and the workspace shows evidence of being a Java project: a build
descriptor (`pom.xml`, `build.gradle[.kts]`, `settings.gradle[.kts]`, a Maven or
Gradle wrapper) no more than two directories below the root, or a `.java` source
no more than two directories below the root for projects that have no build
system. A Java sample or fixture checked into a repository of another ecosystem
therefore does not activate Java tooling; hosts still start a language server on
demand when the user opens a `.java` file. The command chooses one deterministic
representative source and classifies changes as `ignored`, `source`,
`buildConfiguration`, or `other`. The compatibility examples are in
`shared/fixtures/lsp/java-workspace-policy-v1.json`.

`java.jdtCacheRetention` accepts platform-observed cache directory metadata as
`{ nowUnixSeconds, activeWorkspaceKey?, entries }`. Each entry contains a
lowercase 64-character SHA-256 `workspaceKey` and
`lastModifiedUnixSeconds`. Core ignores invalid candidate names, de-duplicates
observations using the newest timestamp, never selects the active key, and
returns deterministically sorted `expiredWorkspaceKeys` older than the fixed
30-day retention period. Platform adapters own the last-used marker, directory
enumeration, revalidation, deletion, and error logging; Core performs no cache
filesystem I/O. See `shared/fixtures/lsp/jdt-cache-retention-v1.json`.

`lsp.documentUri` accepts `{ path, platform }` and returns `{ uri }`. `platform`
is `posix`, `windows`, or `auto`; `auto` recognizes drive and UNC paths and
otherwise treats an absolute path as POSIX. Paths must be absolute, contain no
NUL and fit within 131,068 UTF-8 bytes. Windows extended drive and UNC prefixes
are accepted. Core resolves lexical dot segments, preserves a trailing directory
separator, and percent-encodes reserved characters and UTF-8. Invalid paths
return `invalid_request`. See `shared/fixtures/lsp/document-uri-v1.json`.

The `rootUri` of `lsp.startServer` and the `uri` fields of `lsp.syncDocument`,
`lsp.saveDocument`, `lsp.closeDocument`, `lsp.request`, `java.navigationMarkers`,
`java.resolveNavigation`, and each `lsp.workspaceFilesChanged` change accept
either an existing URI string or `{ path, platform }`. The related diagnostic
location URIs in `lsp.request` accept the same shape. Core converts path inputs
inside the existing request; virtual URI strings and opaque server data are not
rewritten. This does not add an IPC request for each document edit. When
matching published diagnostics, Core normalizes escape spelling and Windows
drive letters without treating an encoded `#`, `?`, or `/` as a URI separator.

`lsp.syncDocument` accepts `{ sessionId, uri, languageId, text?, contentChanges? }`.
The first sync emits `didOpen` at version 1. Later syncs emit `didChange` with
increasing versions. `contentChanges` follow LSP `didChange` semantics: they
apply in array order and each range is relative to the result of the previous
change, so a host that accumulates edits between syncs appends them in the order
they happened and sends the ranges of one simultaneous edit end to start.
Core replays them over the text it holds. `text` may be omitted alongside
`contentChanges`, which keeps a large document off the wire for every keystroke;
when it is present and disagrees with the replay, `text` replaces the document
and the notification is a full-text replacement. When the server advertised
incremental `textDocumentSync`, a successful replay is sent as range-based edits;
otherwise the replayed text is sent whole. Ranged edits without `text` fail with
`InvalidRequest` when they cannot be replayed, and with details
`documentNotSynchronized` when Core has never received the document; the host
then resends the full text. The response is `{ documentVersion, changed, uri }`;
`uri` is the exact resolved document identity used by the session.
submitting identical full text returns `changed: false`, preserves the version,
and emits no LSP notification.

`lsp.saveDocument` accepts `{ sessionId, uri, text }` after a successful native
save and returns `{ sent }`. The text is the exact saved snapshot, not the latest
possibly dirty buffer. Core sends `textDocument/didSave` only for an open,
ready document when the server advertised `textDocumentSync.save`; it includes
text only when `includeText` was requested. Unsupported saves, unopened documents
and snapshots superseded by newer synchronized edits return `sent: false` without
changing the document version or contents. Failed native saves never call this
operation. The host flushes current editor text before the save, including
edits made while the native write was in flight. Before launch, hosts retry
save notifications for clean open buffers and propagate transport failures
instead of treating disk persistence alone as launch readiness.
This is distinct from `didChange`: JDT reloads its on-disk working copy on save,
which makes a subsequent Java launch build observe saved dependency edits.
Shared cases: `shared/fixtures/lsp/document-save-v1.json`.

`lsp.workspaceFilesChanged` accepts a session ID and ordered file URI changes
whose `kind` is `created`, `changed`, or `deleted`. It emits one
`workspace/didChangeWatchedFiles` notification. Open documents remain owned by
versioned `lsp.syncDocument`; adapters must not duplicate those edits as watcher
events.

`java.navigationMarkers` accepts
`{ sessionId, operationId?, uri, documentVersion? }` and completes with
`{ documentVersion, markers }`. Rust combines JDT LS implementation CodeLens,
`textDocument/implementation`, and `java/findLinks` results with parser-selected
Java declaration candidates. Work is capped at 64 semantic tasks, individual
task failures preserve other verified markers, stale document versions cancel
the batch, and the latest completed version is cached per URI. Markers are
sorted by line, UTF-16 column, and relation. A marker contains `direction`
(`up` or `down`) and `relation` (`interface` or `inheritance`); zero-target
declarations are omitted. The cross-platform examples are in
`shared/fixtures/lsp/java-navigation-v1.json`.

`java.resolveNavigation` accepts the marker position, direction, relation, and
document version. Downward markers use `textDocument/implementation`; upward
markers use JDT LS `java/findLinks` with `superImplementation`. Its terminal
result is `{ documentVersion, locations }`, using the same normalized physical
and virtual-location representation as ordinary navigation.

`lsp.buildRequest` accepts `{ sessionId, operationId?, method, params,
timeoutMilliseconds? }` and returns `{ operationId }`. `method` and `params`
are the `provider` field of a `build.modelPlan`, `build.dependencyPlan` or
provider-sourced `build.taskPlan`/`build.testPlan`, `build.testDiscoveryPlan`, or
`build.prepareRunPlan` result. Version 1 accepts
`lithe/build/model` and `lithe/build/dependencies`; version 2 adds
`lithe/build/execute`, version 3 adds `lithe/build/test` with the same bounded
execution lifecycle and `lithe/build/discoverTests` with the raw result lifecycle.
Version 4 adds `lithe/build/prepareRun`, with execution progress but a raw launch
plan passed to `build.decodeRunPreparation` before native process startup. Version 5 adds `lithe/build/prepareDebug`: raw native executable facts pass through `build.decodeDebugPreparation` and the existing DebugAdapter Registry, not private functions or a second DAP engine.
Version 10 adds typed `launchOptions` for this run method and host-owned service/task
preparation. These options require explicit version-10 negotiation before a
request is written. The decoder accepts a workspace cwd outside the instance
only when it matches the same host-validated explicit option. Native debug
preparation retains its existing application contract.
Other methods are `invalid_request`; tasks on version 1
and tests on versions 1/2 or run preparation on versions 1/2/3 are `not_supported`.
Every session offers
`capabilities.experimental.litheBuild: { versions: [4, 3, 2, 1] }` in `initialize`; a
session whose process did not answer one of those versions rejects the request
with `not_supported`, so a shared provider that does not speak the protocol
still serves its language. `timeoutMilliseconds` replaces the session's request
timeout for this request and is capped at one hour. The `requestCompleted`
event carries the provider's reply unchanged as `result.value`, which the host
passes to `build.decodeModel` or `build.decodeDependencies` as `result`;
cancellation and late results follow `lsp.cancelOperation`. Execution replies
are validated as `{exitCode: Int32, output: string}` and progress is mapped
from a Core-owned wire request ID to `requestProgress` for the still-pending
operation. See the [provider execution contract](plugins/v1/README.md#provider-task-execution-buildproviders-2).

`lsp.toolchainRequest` accepts `{ sessionId, operationId?, params,
timeoutMilliseconds? }` and returns `{ operationId }`. `lsp.startServer` takes
`toolchainProviders`, the manifest's provider IDs; only a plugin-owned session
with some offers `capabilities.experimental.litheToolchains: { versions: [1],
providers }`. A backend that answers `{ version: 1, providers }` with a non-empty,
duplicate-free subset of the offer emits a `toolchainProviders` runtime event
with `result: { providers }`; any other answer enables none. A request whose
`params.providerID` was not negotiated is `not_supported` with details
`plugin.toolchain.providerUnavailable`, and nothing is written. The
`requestCompleted` event carries `result.value: { id, response }`: the JSON-RPC
ID and the complete, unvalidated response, error replies included, which the host
passes to `toolchains.decodeReply` with the same `params`. The timeout is capped
at 60 seconds; cancellation and late results follow `lsp.buildRequest`.

`lsp.vcsRequest` accepts `{ sessionId, operationId?, vcs, operation, root,
tool?, arguments?, timeoutMilliseconds? }` and returns `{ operationId }`.
`operation` is a [VCS provider contract](vcs-provider-v1.md#lspvcsrequest)
operation name, never a method; Core checks `arguments`, adds the absolute
`root` and `tool` paths, and writes the operation's `lithe/vcs/*` request.
Only plugin-owned sessions offer `capabilities.experimental.litheVcs:
{ versions: [1] }`; a session whose process did not answer with a VCS ID and
every required capability, or answered another VCS than `vcs`, refuses the
request with `not_supported` and details `vcs.provider.unavailable`, and an
operation whose capability was not negotiated is `not_supported` with details
`vcs.capability.unsupported`. A successful negotiation emits a `vcsProvider`
runtime event whose `result` is `{ vcs, capabilities }`. The
`requestCompleted` event carries the provider's reply as `result.value`, which
the host passes to `vcs.decodeReply`; a failed request carries a `vcs.*`
`error.code` (the provider's own code only when the contract lists it).
Timeout, cancellation, and late results follow `lsp.buildRequest`.

A plugin-owned session started with `workspaceConfiguration` answers each
`workspace/configuration` item from it by `section` (an exact key wins over
a dotted path; no section returns the whole object, a missing one `null`) and
sends `workspace/didChangeConfiguration` with it after `initialized`.
`lsp.updateWorkspaceConfiguration` accepts `{ sessionId, configuration }`
(an object) and returns `{ sent }`: the new value replaces the stored one,
and is announced at once when the client is initialized or with
`initialized` otherwise. Host-owned sessions and stopping, stopped, or failed
sessions refuse it with `invalid_request`.

`lsp.functionRequest` accepts `{ sessionId, operationId?, function: { pluginID,
functionID }, params?, timeoutMilliseconds? }` and returns `{ operationId }`.
It sends `lithe/function/invoke` to a session started with
`lsp.startServer.pluginId` equal to `function.pluginID` that negotiated
`capabilities.experimental.litheFunctions` version 1 or 2 and registered
the function. `params` must be a JSON object and defaults to `{}`. Refusals are
`invalid_request`, `not_supported`, or `permission_denied` with a
`plugin.function.*` code in `details`, in the order the
[plugin contract](plugins/v1/README.md#plugin-functions) defines. The
`requestCompleted` event carries the backend result as `result.value`; a
failed call carries `error.code` `plugin.function.failed`, `invalidResult`, or
`revoked` and, when the backend supplied one, `error.pluginErrorCode`.
Timeout, cancellation, and late results follow `lsp.buildRequest`. Core gives
each backend invocation a unique, opaque `operationID`; the backend echoes
that value in progress notifications. It is distinct from the host's
`operationId`, which may be reused after a previous call ends. Core only
forwards progress belonging to the current pending function request and
translates its ID to the host's ID: `requestProgress` has
`method: "lithe/function/invoke"` and `result: { operationID, message?,
percentage? }`, with both event and result referring to the host operation.
Every terminal path discards the function/request association, so late
progress or unregister requests cannot affect a later operation reusing that
host ID, including a build request.

A plugin-owned session publishes its initialized registry as `functionsChanged`
with `result: { functions, removed: [] }` after successful `initialize`
negotiation, including an empty negotiated registry. Subsequent register and
unregister requests publish
`functionsChanged` with `result: { functions, removed }`; the current registry
is `pluginFunctions` in the session's client state. Sessions without
`lsp.startServer.pluginId` neither offer nor accept `litheFunctions`, retain no
registry, and publish no function-discovery events.

A session that negotiated `litheFunctions` version 2 may send the
[host-service requests](plugins/v1/README.md#host-services-protocol-version-2)
its `hostServices` grant. Core checks method, grant, and params, then
publishes the runtime event `hostRequest` with `method` and `result: {
hostRequestID, service, params }`; refusals go back to the backend without an
event. `lsp.hostResponse` accepts `{ sessionId, hostRequestID, result? }` or
`{ sessionId, hostRequestID, error: { message } }`, returns `{}`, and sends
`result` (default `null`) or `-32603` with `data.code: "plugin.host.failed"`
to the backend. An unknown or already answered `hostRequestID` is
`invalid_request`. At most 16 host requests are unanswered per session; more
are refused with `plugin.host.failed`. From version 3 the error may also be
`{ message, code?, details? }`: a host code reaches the backend with its own
JSON-RPC number, and `details`, an object of at most 4 KiB, as
`error.data.details`
([failure codes](plugins/v1/README.md#workspace-contexts-and-capability-discovery-protocol-version-3)).

The macOS public document/file/window adapters use method-level grants for new
permissions. Core intersects grants with its method table for capability discovery;
macOS first intersects them with actual registered handlers. Legacy `workspace`
never authorizes file methods. Host request/result JSON is bounded to 1 MiB;
oversized v3 results return `plugin.host.limitExceeded`. See the plugin contract's
public document, file and window method table for exact shapes and cancellation
semantics. The underlying `PluginFunctionRequest` context and legacy SDK wire
shapes remain compatible.

`lsp.hostNotify` accepts `{ sessionId, method, params }` for a ready
plugin-owned session and returns `{ delivered }`. Core sends the
[host notification](plugins/v1/README.md#host-notifications-protocol-version-3)
when the session negotiated version 3 and is granted its service, and returns
`delivered: false` without sending for an older version. Another method, an
ungranted service, malformed or oversized params, a session that is not
plugin-owned, or one that is not ready is `invalid_request` with the
`plugin.host.*` code in `details`.

`lsp.pluginServerRequest` accepts `{ sessionId, operationId?, pluginId,
serverID, method, params?, timeoutMilliseconds? }` and returns `{ operationId }`;
`params` defaults to `{}` and the deadline to 60000 milliseconds (at most
300000). The host resolves `{context, serverID}` of a backend's
`lithe/host/languageServer/request` to the session and calls this command; Core
checks that the session belongs to `pluginId` and `serverID` and enforces the
server's declared session policy: the `requestMethods` whitelist, the
`commands` of `workspace/executeCommand`, `serializedCommands` (a request for a
command already running joins it), and `gates` (a request waits, in order, until
every gate has seen its notification; at most 128 wait, then the request fails
as `plugin.host.busy`). The answer arrives as a `requestCompleted` event whose
`result.value` is the server's result. A failure carries its `plugin.host.*`
code as the event's `error.code` and its details as `error.details`; the host
returns both to the backend unchanged. The codes are
`plugin.host.languageServerUnavailable` (-32022: the session is not ready or
has stopped), `plugin.host.languageServerError` (-32023: the server answered
with an error, in `details.code` and `details.message`),
`plugin.host.methodNotDeclared` (-32024), `plugin.host.foreignContribution`
(-32026), `plugin.host.timeout`, `plugin.host.cancelled`, `plugin.host.busy`,
and `plugin.host.limitExceeded`. The
[plugin contract](plugins/v1/README.md#language-server-host-methods) owns their
meaning.

`lsp.pluginServerNotify` accepts `{ sessionId, pluginId, serverID, method,
params? }` and returns `{ delivered }`. It sends `workspace/didChangeConfiguration`
and every declared `requestMethods` entry except `workspace/executeCommand`; a
notification is never held behind a gate. `delivered: false` means the server
was not initialized yet and receives the stored configuration with its
`initialized` notification instead. A notification the server sends and
`forwardNotifications` lists is queued as a `pluginServerNotification` event
with `result: { serverID, method, params? }` for the host to relay as
`lithe/host/languageServer/didReceiveNotification`.

`lsp.startServer` for a plugin-owned server whose manifest declares
`remote: "unsupported"` fails with `not_supported` when the workspace is
remote, before any process is started.

A session that negotiated `litheFunctions` version 4 and holds the `functions`
grant may call another plugin's exported function through the
[plugin-to-plugin relay](plugins/v1/README.md#cross-plugin-calls-protocol-version-4).
Core runs the whole relay: it checks the declarations, keeps the call chain,
writes the forwarded request, and answers the caller. `lsp.configureFunctionRelay`
accepts the host's complete view and returns `{}`; every call replaces the
previous view, and a call in flight that the new view forbids ends with an
explicit `plugin.function.*` error.

```json
{
  "plugins": [
    {
      "pluginID": "dev.example.formatter",
      "exports": [{ "id": "document.format", "version": 1, "context": "workspace" }],
      "calls": []
    }
  ],
  "contexts": [{ "contextID": "w-1", "generation": 1, "authority": "local" }]
}
```

- `plugins` lists the enabled plugins that declare `pluginFunctions`, and each
  `exports` and `calls` is the normalized manifest's own list. The host
  copies them and does not interpret them. A plugin that is disabled,
  replaced, or removed is left out, which ends its calls.
- `contexts` lists the live workspace contexts; `authority` is `local` or
  `remote`, and a call in a remote workspace is refused.
- A malformed snapshot (an unknown field, a bad plugin or function ID, a
  duplicate plugin, more than 4096 plugins) is `invalid_request`.
- Core publishes the runtime event `functionProviderStartRequired` with
  `result: { pluginID }` on the calling plugin's session when a call waits for
  a callee whose backend is not running. The host starts that backend as plain
  I/O; Core ends the call with `plugin.function.providerUnavailable` if the
  callee does not register the function within 30 seconds.

`lsp.request` accepts a semantic `operation` plus
the operation-specific URI, position, range, diagnostics, item, action, or
command fields, and returns `{ operationId }`. Supported operations include
completion and resolve, hover, definition/declaration/type-definition, references,
implementation, rename, formatting, code actions and resolve, execute command,
inlay hints, full-document semantic tokens, folding ranges, code lens, provider
virtual documents, `javaEntrypoints`, `javaTestItems`, and `javaMainMethods`.
For code actions, `diagnostics` contains the original `LspClientDiagnostic`
objects returned by Core: nullable integer `severity`, `tags`, and
`relatedInformation` remain intact, and every range uses zero-based `line` /
`utf16Column` positions. A platform's display severity or marker projection is
not a diagnostic request model. Non-LSP markers may request actions with a range
and an empty diagnostic context. The round-trip fixture is
`shared/fixtures/lsp/diagnostic-code-actions-v1.json`.
`javaEntrypoints` invokes Java Debug Server's
`vscode.java.resolveMainClass` for the session workspace and returns schema
version 1 with deterministic workspace-relative `{ sourcePath, mainClass,
projectName? }` entries plus diagnostics for unusable upstream records.
Discovery queries all entries in the owned JDT session, then filters source
paths against the opened workspace and its resolved location. This includes
plain folders represented by invisible projects in JDT's writable cache;
unrelated workspace sources remain excluded. Discovery
waits behind pending Maven profile updates and JDT project-configuration jobs,
using the same configuration barrier as the following Java build. Up to 128
waiting discovery operations are allowed per session. Their deadlines include
configuration waiting and the eventual upstream query, bounded by the session's
Java build timeout. Cancellation before dispatch completes that operation without
writing a JSON-RPC discovery request or cancellation; shutdown/failure settles
every waiter. A completed profile update must precede discovery of source roots
introduced by that profile.

`javaTestItems` requires a file URI, invokes Java Test's
`vscode.java.test.findTestTypesAndMethods`, and returns schema version 1 with a
typed class/method tree. Each item carries the upstream identity, label, fully
qualified name, project, test kind/level, optional JDT handler and sort text,
optional zero-based UTF-16 range, and children. A `null` upstream result means
the file has no tests (Java Test leaves its root's children unset) and yields an
empty item list; any other non-list top-level result is an
`invalidServerResult`, never an empty semantic answer.
`javaMainMethods` requires a file URI, invokes Java Debug Server's
`vscode.java.resolveMainMethod`, and returns schema version 1 with
`{ methods: [{ range, mainClass, projectName? }], diagnostics }`. `range` is the
zero-based UTF-16 range of the method name, and methods are ordered by source
position. `mainClass` matches the `javaEntrypoints` entry generated for the same
file, so editors can launch the workspace configuration for that entry. A `null`
upstream result means no launchable method; any other non-list result is an
`invalidServerResult`. Core does not infer Java entry points or tests from
source syntax.
For the Java provider, an `executeCommand` whose command is
`vscode.java.buildWorkspace` is coordinated by Core instead of being written
immediately. Core writes it only when no earlier build is awaiting its JDT
response, the Maven profile task is not `running`, and no JDT work-done
progress job named `Update project …`, `Updating project configurations`,
`Applying the selected build files…`, or `Updating workspace folders` is open;
a job without progress for 120 seconds stops blocking. Identical queued build
commands share one JDT request, while a running build is never shared. Each
caller is bounded by `javaBuildTimeoutMilliseconds` from `lsp.startServer`
(default 600000), measured from submission; its `requestTimeout` error has stage
`javaBuild` and an `underlyingMessage` naming the reached phase
(`building`, `waitingForPreviousBuild`, `waitingForMavenProfiles`, or
`waitingForProjectConfiguration`). Cancellation or timeout sends
`$/cancelRequest` only when no running or queued caller still needs a build,
and the build keeps its slot until JDT answers. A successful build completes
with the unchanged `{ value: 1 }` result. Other JDT `BuildWorkspaceStatus`
values complete with stage `javaBuild` and code `javaBuildCompilationErrors`
(`WITH_ERROR`), `javaBuildFailed` (`FAILED`), `javaBuildCancelled`
(`CANCELLED`), or `invalidServerResult`. `javaBuildCompilationErrors` and
`javaBuildFailed` additionally carry `javaBuildReport` with `markerScope`
(`launchTarget` or `workspace`), `builderFailedEarlier`,
`elapsedMilliseconds`, and `recovery` (`none` or `rebuildJavaIndex`). The marker
scope is inferred from the dispatched command: `launchTarget` means the request
named a project, not that Core observed Java Debug Server's final project
selection. Elapsed time is evidence only and must not become a heuristic gate.
The versioned examples are in
`shared/fixtures/lsp/java-build-report-v1.json`.

Hosts treat these two terminal build outcomes as evidence rather than an
irrevocable launch veto. After resolving the usable runtime paths, they may let
the user continue that same launch attempt without issuing another build. A
cancelled, timed-out, rejected, or unrecognized build has no usable verdict and
must be retried instead of overridden. Hosts present Core's message and report
instead of inferring a cause. Core logs `Java project build is waiting` (with `reason`),
`Java project build started`, and `Java project build finished` (with
`outcome`, `errorCode`, `elapsedMilliseconds`, and `waiterCount`).
Background build retries and deadline cancellations are written by a separate
session-owned worker. The deadline monitor never writes to stdin. A background
write that exceeds `requestTimeoutMilliseconds` fails the session with
`transportFailed` at stage `outboundMaintenance` and terminates the server to
release the stalled pipe; the Java build deadline still bounds queue and build time.
`java.prepareLaunch` accepts `{ sessionId, operationId?, sourcePath, mainClass? }`.
`sourcePath` is the absolute saved source path at the native boundary.
Core owns one operation across JDT entry-point discovery, the existing serialized
build coordinator, and classpath resolution. The source must be inside the session
workspace; an optional configured class disambiguates multiple entries in that
exact file (including JDT's module prefix). Core does not infer entry points or paths.
Discovery and classpath each use the session request deadline; the build retains
its independent queue-inclusive deadline. The host fallback deadline covers all
three phases plus event-delivery grace.

Only the final `requestCompleted` event is published to the host, with either
`{ kind: "ready", target: { mainClass, projectName?, modulePaths, classPaths } }`
or `{ kind: "buildFailed", target, failure: { code, message, report } }`.
Only the two terminal build failures above can produce the latter.
Cancellation, timeout, invalid replies and transport failures remain operation
errors. Cancelling the operation cancels its current phase; a late build answer
retains the existing coordinator semantics and never starts classpath resolution.
Runtime path groups must contain nonblank strings, with at least one path overall.
Hosts save documents before submitting and own the final launch decision, JDK
discovery and native process. Run plan/toolchain selection remain in existing Core
operations. See `shared/fixtures/lsp/java-launch-preparation-v1.json`.

The `semanticTokens` operation uses the open document URI and normal version,
timeout, and cancellation rules. Its result is
`{ tokenTypes, tokenModifiers, tokens: [{ line, startChar, length, tokenType, tokenModifiers }] }`.
Token positions use zero-based LSP lines and UTF-16 columns; `tokenType` indexes
the returned legend and `tokenModifiers` is a UInt32 bitset. Core decodes the
server's relative positions with the legend captured when the request was sent.
Range-only providers are not advertised as supporting this operation. No delta
result ID crosses the boundary. See `shared/fixtures/lsp/semantic-tokens-v1.json`.
The `semanticTokensRefresh` event invalidates the host's semantic color cache
when the server requests `workspace/semanticTokens/refresh`; the request receives
a JSON-RPC null acknowledgment. Windows maps `lsp_get_semantic_tokens` to this
existing operation and forwards refresh events as `lsp://semantic-tokens-refresh`
with `{ sessionId, workspacePath }`; only the owning frontend session invalidates
its Monaco provider. The shared payload and legend remain unchanged.
The `virtualDocument` operation accepts `{ sessionId, operation,
virtualUri }` without a document `uri`. Its terminal `requestCompleted` event
returns `{ text }`, where `text` is the provider-resolved UTF-8 source for the
opaque virtual URI.

`lsp.pollEvents` drains events ordered by per-session `sequence`. `lsp.waitEvents`
accepts `{ sessionId, timeoutMilliseconds }` and waits on a session event
channel until events are queued or the timeout elapses, then drains the same
typed events. Hosts should use `waitEvents` so idle sessions do not poll.
Event types
include `stateChanged`, `featuresChanged`, `diagnostics`,
`requestCompleted`, `requestProgress`, `functionsChanged`, `hostRequest`,
`serverInfoChanged`, and `log`. Every request completes at
most once with either `result` or a structured runtime error containing
provider/session, stage, optional method/document/request, stable code, and
optional process-exit detail. Late responses after cancellation or deadline
are ignored. Diagnostics are accepted only for documents open in the current
session, and versioned diagnostics must match the current document version.

The client reducer, raw JSON-RPC message, frame, and parser functions are
internal Rust implementation seams; they are not public application commands.
Completion, hover, navigation, edit, hint, folding, and code-lens responses are
normalized by Rust before they cross the application boundary. Unknown server
requests receive JSON-RPC `Method not found` instead of being silently ignored.

The `history.*` commands accept an adapter-selected `storageRoot`; history
metadata never stores an absolute workspace or storage path. `history.record`
accepts `workspaceRoot`, a relative `path`, a `reason`, and optional UTF-8
`content`; when content is omitted the core reads the workspace file. Records
are versioned, de-duplicated against the latest snapshot, capped at 100 entries
per file, and pruned after 30 days. `history.record` and `history.entries` apply
the same `hiddenDirectoryNames` / `hiddenFilePatterns` matcher as the workspace
tree, so a hidden path (including folder patterns such as `**/generated/` or
`.lithe/*`) is neither recorded nor listed. Invalid metadata and missing snapshot files
are ignored. `history.entries` returns Unix-second timestamps and relative
`contentPath` values. `history.content` rejects traversal,
`history.relocate` updates metadata and storage paths for the exact `sourcePath`
and its `/`-delimited descendants, preserving each suffix under `destinationPath`.
It enumerates retained history metadata independently of workspace indexing and
current visibility rules; similarly prefixed siblings are unchanged. Equal paths
are a no-op; overlapping ancestor/descendant paths are rejected. `history.rename` and
`history.delete` validate both the relative file path and entry ID before
changing stored metadata.
File and subtree relocation cases are defined in `shared/fixtures/history/relocation-v1.json`.

A `hiddenFilePatterns` entry starting with `!` turns a rule off instead of
adding one: `!**/name/` or `!name` removes that hidden folder (built-in or not),
and `!pattern` removes an equal file pattern. `!` entries never match a path.

`history.record` also accepts optional `ignoreRules: { pathPatterns, pathRegexes }`
and an optional `storageLimitBytes` (default
100 MiB, clamped to 10 MiB–100 GiB); baselines stop at half of that cap.
Patterns use the hidden-path glob syntax; regexes use Rust `regex` syntax,
case-insensitive, matched unanchored against the `/`-separated relative path.
A matching file is not recorded, existing entries stay listed, and an invalid
or empty regex never matches. Built-in dependency, cache and build output
folders (such as `node_modules`, `.venv`, `target`) also apply as `**/name/`
patterns, for baselines and edits alike; a `!**/name/` or `!name` pattern turns
one off, and saving drops baselines the current rules reject. `history.ignorePreview` accepts the
same `ignoreRules`, optional `hiddenFilePatterns`, an optional relative
`path` and an optional `workspaceRoot`, and returns `regexErrors` (`{ index, message }` per rejected regex), the
built-in patterns as `builtInIgnorePatterns`, and `matched`: `null` or an object tagged by
`kind` — `hidden`, `pattern` (the matching `pattern`, built-in or the user's) or
`regex` (`index` into its list), plus `gitIgnored`: whether `git check-ignore` ignores
`path` under `workspaceRoot`, or `null` without a path, workspace or repository.
It is informational; local history does not follow Git ignore rules. `history.usage` and `history.clear` accept
`storageRoot`, and `history.usage` also the optional `storageLimitBytes` it
reports back as `limitBytes`; usage rescans the disk and returns `{ usedBytes, limitBytes }` in
allocated bytes, and clear removes every snapshot directory while keeping the
storage root, returning `{ "cleared": true }`.

`diff.compareTexts` accepts `{ oldText, newText }` (each at most 16 MiB of
UTF-8; larger input is `invalid_request`) and never reads files: hosts pass the
snapshot, buffer, or proposal they already hold. `\r\n`, `\r`, and `\n` all end
a line and are not part of its content, one final terminator does not add an
empty line, and empty text has no lines, so texts that differ only in line
endings compare as identical. Lines are matched with the patience algorithm;
each block of removed and added lines is then aligned by character-bigram
similarity (the same pairing `git.diff` uses), so an unrelated delete and
insert stay separate rows. The response is `{ rows, lines, oldLineCount,
newLineCount, additions, deletions }`. `rows` are side-by-side
`{ oldLine, newLine, left, right?, kind }` with one-based line numbers and
`kind` of `context`, `changed`, `addition`, or `removal`; `context` rows omit
`right` because both sides equal `left`. `lines` are unified
`{ kind, content, oldLine, newLine }` with `kind` of `context`, `removed`, or
`added`, each changed block listing its removals before its additions. See
`shared/fixtures/diff/compare-texts-v1.json`.

`maven.scan` accepts `{ "root": string, "paths"?: string[] }` and returns
`null` when neither the root nor the supplied visible workspace-relative paths
contain a readable `pom.xml`. Candidates are tried in shallowest-first order,
with `/`-normalized lexical paths breaking ties, until one parses successfully;
a malformed candidate does not hide a valid nested project. A project response
contains its workspace `relativePath`,
`groupId`, `artifactId`, `version`, `packaging`, recursive `modules`, `profiles`,
and `hasWrapper`. The root project and every recursive module also contain a
`sourceRoots` list. Each entry has a module-relative `/`-normalized `path` and
a `kind` of `mainJava`, `mainResources`, `testJava`, `testResources`,
`generatedMain`, or `generatedTest`. Standard Maven roots are returned before
their directories exist; explicit `<build>` source/resource directories and
`maven-compiler-plugin` generated-source directories or
`build-helper-maven-plugin` source lists replace the corresponding defaults,
whether configured directly on the plugin or within an execution.
`${project.build.directory}` resolves from `<build><directory>` and defaults to
`target` only when that element is absent; unresolved or invalid explicit
values do not silently fall back.
Absolute, unresolved-property, and parent-traversal paths are omitted so one
module cannot claim another module's source root. Entries are de-duplicated and
ordered by the documented kind order, then path. Aggregator-only `pom` modules
have no default roots. Module paths are relative to the selected Maven root and
use `/` separators. Malformed XML returns `parse_failed`. Source-root examples
are in `shared/fixtures/maven/source-roots-v1.json`.

`maven.launchPlan` accepts a workspace `root`, a versioned `context`, an
optional reactor-relative `module`, and an ordered `goals` array whose first
entry is a lifecycle or custom goal. Later entries may be ordinary Maven CLI
arguments such as `-Dname=value` or `-q`. They remain separate process arguments
and are never interpreted by a shell. Context version 1 contains the
workspace-relative `reactorPath`,
selected `profiles`, optional platform-local `settingsPath` and
`localRepositoryPath`, `skipTests`, and optional Maven/JDK paths used only for
the configuration fingerprint. The response contains the `project-maven`
toolchain reference, an argument array, the workspace-relative reactor working
directory, and a deterministic SHA-256 configuration fingerprint. Profiles are
sorted and de-duplicated. Module plans from `maven.launchPlan` and Maven-backed
Run and Debug plans use `-pl <module> -am`. Settings use `-s`; a local
repository override uses `-Dmaven.repo.local=<path>`; skipped tests use
`-DskipTests`. Explicit Run `cwd`, Profiles, and `extensions.maven.skipTests`
values override the project context, including `skipTests: false`. The core
never reads `settings.xml` and never copies its path into a portable project
document. Maven itself continues to read `.mvn/maven.config`; the plan does not
expand or duplicate that file's arguments. Fixtures are in
`shared/fixtures/maven/launch-plan-v1.json`.

`maven.dependencyPlan` accepts the same workspace `root`, versioned `context`,
optional reactor-relative `module`, and a required absolute `outputFile`. It
returns a launch plan for the fixed `maven-dependency-plugin:3.8.1:tree` goal
that writes the verbose text tree to `outputFile` in UTF-8 with standard tree
tokens, disabled color, and an English locale. Exactly one project runs because
every project in the session would overwrite the same file: module queries use
`-pl <module>` without `-am`, and reactor-root queries use `-N`. The read-only
query does not build reactor dependencies. Platform adapters own the child
process, apply a bounded timeout, and keep it independent from an ordinary Maven
build session. They also own `outputFile`: each invocation receives a fresh
path in a platform scratch directory, and the platform removes it after the
result, cancellation, timeout, or failure. The process's console output is log
text only and is never parsed as dependency data.

`maven.dependencies` accepts `{ "modulePath": string, "outputFile": string }`
after the plan's process exits successfully and returns the normalized module
path plus a recursively nested `dependencies` array. Each node contains
`modulePath`, `groupId`, `artifactId`, `version`, `type`, nullable `classifier`,
`scope`, `resolution`, nullable `selectedVersion`, nullable
`premanagedVersion` and `premanagedScope` (values before dependency
management), nullable `originalScope` (declared scope before mediation widened
it), nullable `ignoredScope` (a wider scope mediation did not apply), and
`children`. Resolution is `resolved`, `omittedDuplicate`, or `omittedConflict`;
`selectedVersion` is the winning version of an omitted conflict. Every level is
sorted deterministically.

The first line of the file must name the module and every later line must be a
node with only the annotations the pinned plugin writes; any other content,
invalid UTF-8, a line over 4 KiB, more than 10,000 nodes, 64 levels, or a file
over the byte limit derived from those bounds returns `parse_failed` instead of
a partial tree. A missing file returns `process_failed`. The compatibility
fixture is `shared/fixtures/maven/dependency-tree-v2.json`.

`maven.diagnostics` accepts `{ "root": string, "output": string }` and returns
`{ "issues": [] }`. Diagnostic paths may be absolute or workspace-relative;
the response preserves the path text, uses one-based line and column values,
and normalizes severity to `error` or `warning`. Duplicate issue lines are
removed deterministically.

`runConfig.selectJava` uses the toolchain requirements of the workspace's latest
`runConfig.generate` in this process; before any generation it derives them from
the project's own declarations (`pom.xml`, `.java-version`, the Maven wrapper).
Its request contains optional
`root`, `candidates` (`id`, probed `version`, numeric source `priority`), and
`fallbackId`. IDs are opaque machine-local identities, never persisted or opened
by this operation. Lower priority wins; equal-priority candidates use descending
numeric Java versions (including legacy `1.8`), then ascending ID.

When `project-jdk.minimumVersion` exists, selection first filters using the same
Java version comparison as run-configuration diagnostics. Among the compatible
candidates, the one whose Java feature version equals the declared one wins, else
the oldest newer feature version; source priority only breaks ties within a feature
version. A Java 8 project therefore runs on an installed JDK 8 even when `JAVA_HOME`
points at JDK 21, matching IDEA and OpenIDEA. The response is
`{ id, warning }`: the compatible candidate, or the supplied usable fallback
with an actionable warning if none qualifies. Missing requirements retain the
platform's unconstrained choice; a malformed or unsupported `requirements`
snapshot returns the parse/version error. Explicit configured paths bypass automatic
selection. The operation never generates requirements or probes executables.
The cross-platform examples are in
`shared/fixtures/run-configuration/automatic-java-selection.json`.

Windows `run_resolve_toolchains` includes an optional `warning` on resolved
JDKs, including inherited Maven JDKs. This warning remains visible even when no
run configuration exists to carry a scoped `toolchainVersionMismatch` diagnostic.

`runConfig.projectToolchain` reads `{root,path,localDocument?,configurationId?}` and returns
`{toolchain:{javaHomePath,mavenExecutablePath,mavenJavaHomePath,runtimeExecutablePaths}}`, even without
generated Run configurations. `path` is the current Provider's normalized,
workspace-relative project/reactor root (`.` for the workspace). The nearest
`toolchain.pathOverrides` entry owns all three fields; its empty/missing fields
inherit workspace defaults, not another ancestor override. Matching uses path
segments, so `app` never owns `app2`. Malformed stored paths/documents fail
without changing source bytes. The command does not discover, probe or run any
tool, inspect project descriptors, or write files. `runtimeExecutablePaths`
comes from the existing `.lithe/toolchains/local.json`; platforms resolve the selected
paths through their existing toolchain adapters. Shared examples are in
`shared/fixtures/run-configuration/project-toolchain-selection.json`.
When `configurationId` is supplied, explicit Java/Maven paths from that current
Run configuration override the canonical project/reactor selection. Core reuses
the existing team/local configuration merge without projecting global defaults
as explicit configuration choices. Empty configuration fields inherit the
canonical selection; missing, disabled, mismatched-root or malformed choices fail
instead of falling back. No generated layer is required for an explicitly saved
Provider reference. Shared cases are in
`shared/fixtures/run-configuration/configuration-toolchain-selection.json`.

`runConfig.inspect` also returns the local document-level `toolchain`, including
when no generated configuration exists (`status: "missing"`). Settings,
toolchain-only callers, and initial run-panel presentation may send
`checkFingerprint: false` to validate documents without traversing or hashing
project sources. Omission preserves full inspection. The Windows run panel
publishes readable configurations first, then performs full inspection and
reports freshness failures without discarding those configurations.
The input fingerprint covers what generation reads: build and tool files and
the sources of generated Java entries by content (`sha256:<hex>` in
`generator.inputs`), and every other Java source by path only (`path`), so
editing a class body is not a staleness. When the stored inputs no longer
reproduce the stored fingerprint, the document came from another generator
revision and the diagnostic says so instead of listing modified files.
Automatic run discovery, fingerprint traversal, Node manifest discovery and the
Windows Java source list use Core's shared scan policy. Known caches/build outputs
are pruned before descending; other hidden source directories remain visible and
symlinks are not followed. Failure to read the workspace root is an error. An
unreadable optional child or fingerprint input is recorded in
`generator.unreadablePaths`; generation retains previous configurations and input
hashes beneath those unknown paths. Inspection returns `incompleteProjectScan`
instead of claiming fingerprint freshness or inferred removals when either the
current scan or saved baseline is incomplete. The persisted diagnostic also appears
with `checkFingerprint: false`; a successful complete regeneration clears it.
This does not replace declared build-system modules or JDT's entrypoint facts.
The bounded Java source list stops opening further directories once its source
limit is reached, retains only collected Java paths, and returns them sorted.
Full fingerprint scans remain uncapped by this list limit and keep reporting
unreadable inputs independently.

`runConfig.inspect` also accepts optional schema-versioned `javaEntrypoints`
from the current `lsp.request` result, independent of `checkFingerprint`. Core
then compares JDT's `(sourcePath, mainClass)` pairs, with a `module/` prefix
removed and nested checkouts excluded, against the generated Java entries and
reports a difference as a `staleFingerprint` diagnostic. Platforms send it
after a project load once the Java service has prepared the project, never
start that service for this check, and skip it while a regeneration already
waits for the service.
Project environment saves use the existing local `runConfig.updateOptions`
toolchain payload with an empty `configurationId`; service overrides are untouched.

The `runConfig.*` commands implement the versioned project protocol described
by the JSON Schemas in this directory. `runConfig.inspect` accepts `root` and
never writes files. `runConfig.generate` accepts `root`, relative Java `paths`,
relative `modulePaths`, optional schema-versioned `javaEntrypoints` from the
current `lsp.request` result, and optional `projectOwnership`. The latter is a
host projection of current enabled Provider projects: `{ path,
name?, build?: { pluginID, buildSystemID, root, projectID }, minimumJavaVersion?, contentRoots: [{ path, kind }] }`, using workspace-relative
paths and the model's `source`/`testSource`/generated-source roles. Core validates
project/root containment, unique project paths, roles and bounds (2,000 projects,
10,000 content roots). When supplied, including `[]`, these facts own Java
project membership and source sets: `modulePaths` and ancestor POM inference
do not supplement them. `build` is an exact current model identity, not a build
semantic tag. Generated Java entries store it under `extensions.java.build`,
with Java-owned `module` and `mainClass`; they contain no Maven extension or
Maven tool binding. Its root stays independent of editable cwd and document
layers cannot replace generated build ownership. An omitted snapshot retains the current
Windows generator's legacy ownership path. A supplied ownership snapshot disables
legacy Maven framework detection. Framework selection is not an ownership field;
run discovery uses the independent generic snapshot described below.
`minimumJavaVersion` is an optional normalized Java feature version (1–999),
owned by the upstream compiler model, including before entrypoint discovery
returns any sources. When the snapshot is supplied, Core uses
the highest known project floor and never parses POM compiler properties; a
platform Java version file can raise but cannot lower that floor. Missing means
unknown, not permission to infer. Build-tool versions and wrapper paths are not
ownership fields. With provider ownership Core emits no Maven requirement and
never reads wrapper properties or scripts to supplement it. Installed tool
definitions/providers own these choices. Native Java preparation routes by the
exact enabled package, declaration, instance and project identity. Legacy
consumers that omit provider ownership retain their old Maven launch path until
they migrate; those fields are not accepted in the new ownership projection. See `fixtures/run-configuration/provider-project-ownership.json`.
The generated document records optional `generator.providerFingerprint`, a
SHA-256 identity of the validated projection, with projects and roots sorted.
It covers project labels, ownership, source roles and requirement
facts, but never environment values or native configuration secrets.
`runConfig.inspect` accepts the same optional `projectOwnership` and emits
`staleProviderModel` when current facts differ or a legacy generated document
has no provider identity. `checkFingerprint: false` skips file hashing only;
this model comparison remains active. Explicit `[]` represents disabled/missing
providers, while omission preserves existing Windows callers. A return to the
same semantic facts matches again; asynchronous host publication still needs
its independent monotonic operation revision to reject ABA replies.

`runConfig.generate` and `runConfig.inspect` also accept optional `providerRuns`:
a complete list of `{projectPath,name,reference}`. The native host matches current
model targets against enabled public run declarations; `reference` has exactly the
`extensions.build` selector shape below, with empty model `userArguments`. This
snapshot is independent of Java entrypoints and language imports. Core validates
at most 10,000 unique selectors, provider-root/project containment and bounded labels,
then creates `build.provider` entries without interpreting target IDs, tool names,
frameworks, commands or debug adapters. An explicit `[]` withdraws generated runs;
omission preserves older callers. It also disables the legacy framework detector.
IDs hash plugin/build/root/run/project/target identity, so changed labels or execution
kind retain user overrides. Current declarations still validate the execution kind
before preparation. `generator.providerRunFingerprint` hashes the complete sorted
snapshot; changed or missing metadata yields `staleProviderModel`, including when
file fingerprinting is disabled. Withdrawn entries cannot be restored from cached
configurations; unmatched overrides stay in their user-owned layer and are diagnosed.
See `fixtures/run-configuration/provider-project-ownership.json`. macOS supplies this
snapshot; Windows retains its existing generator until its Provider host is migrated.

Java configurations with the same class and module name in independent reactors
remain distinct; a common reactor retains its existing configuration IDs.
 When Java tooling is still preparing, omission
retains the previous generated entrypoint facts instead of running a local
scanner or replacing them with an empty list. Those previous facts come from
this process's last generation, else from the optional `cacheDirectory` (an
application cache root where generation records its result under
`run-configurations/`), else read-only from a `.lithe/run/generated.json` that
older versions wrote. It returns the generated configuration and toolchain
requirement documents and keeps them in memory as the workspace's detected
layer for `inspect`, `resolve`, and `selectJava`; nothing is written into the
workspace. `inspect` returns `requiresGeneration: true` while this process has
no detected layer. Hosts identify the workspace when this flag is true or the
status is `missing`; a saved provider task can make `status` be `ready` before
detection, and must not suppress discovery of the remaining entries. Without
`projectOwnership`, legacy Maven root
discovery checks `pom.xml` along each supplied path's ancestor chain, so a

reactor nested below the opened workspace does not depend on the platform
including build descriptors in `paths`. Maven ownership is resolved per Java
entry: standalone sources keep the JDK launch path, while entries from
independent nested reactors retain their own reactor working directory and
module selector. Generated fingerprints include both project inputs and the
detector revision; either changing marks the detected layer stale and requires
regeneration.

`runConfig.selectContextConfiguration` accepts a provider-supplied `sourcePath`
and opaque `symbol`, a `preferredId`, platform path-comparison policy, and an
ordered list of effective candidate IDs, identities, disabled state, and
generated state. It returns `{configurationId}` (null when none match).
Disabled or differently identified entries never match; an existing preferred
match wins, followed by an edited configuration, with input order breaking ties.
Windows compares paths case-insensitively and treats both separators alike;
case-sensitive hosts compare the supplied path exactly. Discovery remains with
the provider, and clients must reject results made stale by workspace changes.

`runConfig.resolve` accepts `root`, optional local `toolchainCandidates`, and
optional `localDocument` / `teamDocument`. A supplied document replaces that layer
for this read-only resolution; omitted layers come from `.lithe/run/local.json` /
`.lithe/run/configurations.json`. Hosts can preflight a complete two-file transaction
against the current detected layer without publishing either file. Core never writes
these documents; hosts still own source-identity checks, cancellation, conditional
publication and readback. It merges
configurations by stable ID using this precedence:
`local.json > configurations.json > detected layer`. Scalars and arrays are
replaced by the higher layer, while toolchain maps merge by key. It returns
effective configurations, their source, the default (the team default from
`.lithe/project.json`, else the first detected service, else the first
detected entry other than Current File), structured
diagnostics for stale, orphaned, missing, disabled, and toolchain mismatch
states, the effective global `toolchain`, and the machine-local
`localToolchains` document. Toolchain diagnostics carry the affected run
configuration ID when a requirement is consumed by one or more configurations;
requirements with no configuration consumer do not emit a blocking diagnostic.
For detected Maven configurations, resolved `extensions.maven.reactorPath`
contains the workspace-relative reactor from the generated layer, independently
of an overridden effective `cwd`. Core derives this read-only ownership value
when resolving existing generated documents as well; regeneration is not
required. Overrides cannot move a configuration to another reactor. Current
File and configurations without detected Maven ownership omit this field.
Resolution checks that `extensions.maven.module` exists relative to this
reactor, or relative to `root` when the field is absent, and never relative to
an overridden `cwd`: setting a module's own directory as the working directory
keeps the configuration available.
Module menus first match reactor and module, then apply the default preference;
they must not infer ownership from an overridden working directory. The shared
`run-configuration/maven-module-ownership.json` fixture covers independent
reactors, cwd overrides, and the ordinary Java main / Current File capabilities.

Each configuration carries a `category` of `project` or `infrastructure`.
Docker Compose detections are `infrastructure`: a Compose file in an application
repository declares the databases and brokers the project runs against, not the
project itself. The field is omitted for `project`, which is the default, so
existing generated documents keep their exact shape. Hosts present
infrastructure apart from the project's own services and must not include it in
"run all services" or in the default service selection.

Windows implements this grouping. During the macOS transition, Compose entries
remain in its execution-based Services scope; category-based grouping and service
selection filtering are pending there.

Display names that repeat are qualified by Core, because hosts show the name
alone: the first candidate that separates every entry in the group wins, trying
the Maven module, then the working directory, then the source manifest. Three
Compose files each declaring `compose up` become `compose up (script/docker)`
and so on, while a name that occurs once is never decorated. Ids are unaffected.

Java entry points are read from the Java syntax tree rather than matched as
text, so a `static void main` or `@SpringBootApplication` inside a string
literal or comment — common in test fixtures and documentation samples — does
not become a run configuration. A declared `main` under `src/test` remains a
valid entry and keeps the test classpath; see
`shared/fixtures/execution/maven-java-main-source-sets-v1.json`.

A process detector declares a runtime binding only when that command genuinely
consumes the runtime. npm, pnpm, and Yarn scripts consume `project-node`; Bun
scripts keep their independent `bun` command and do not acquire a Node
requirement. Go, Python, Cargo, and Gradle remain command-based until every host
provides the corresponding configurable runtime registry, so their PATH-based
launch behavior is not blocked by an unavailable platform selector.
During resolution, Core also reconciles npm, pnpm, and Yarn commands from older
v2 generated documents with the same `project-node` binding. This compatibility
normalization is based on the effective command, does not mutate the stored
document, and keeps legacy hybrid projects scoped without requiring regeneration.
A document-level `toolchain`
object in the local layer (e.g.
`{ "java": { "homePath": ... }, "maven": { "executablePath": ..., "javaHomePath": ... } }`)
provides defaults for every configuration's `extensions.java.*`. A non-empty
per-configuration toolchain path overrides the corresponding project default.

Provider applications can be explicitly saved with `runConfig.createUserConfiguration`
using `{root,scope:"local",name,type:"buildProvider",build:{pluginID,buildSystemID,
root,run,projectID,targetID,userArguments?,execution?}}`. Core upserts the existing local
reference by selector identity and retains its existing ID (new references use `user:` IDs), unrelated configurations
and project toolchain defaults. `extensions.build` in Run v2 holds the typed
reference; optional execution is application/service/task and must match the current
declaration before preparing (omitted older references mean application). The saved
configuration retains that execution kind when reopened. Process commands, toolchain
bindings and cached debug adapters are refused for `build.provider`. Generic args,
environment and cwd overrides are user choices forwarded through typed launch options;
explicit args replace older reference userArguments, including an empty array.
An implicit selector-root cwd remains omitted from launch options for v4 compatibility. Current model membership is revalidated by the
native build workflow before every preparation. No generated document is needed:
`runConfig.inspect` recognizes explicit saved team/local references and `runConfig.resolve`
merges them against an empty generated layer. A workspace without generated data
or an explicit saved Provider reference retains the existing missing state.
Complete saved `build.provider` entries (name, provider, selector and matching execution)
can retain any existing Run ID, including IDs imported from older formats; a prefix
does not grant launch authority. Sparse unknown-ID patches remain orphaned. Such an
entry also makes a team-only workspace runnable before generation, while still returning
`requiresGeneration: true`. Current declaration/target validation remains mandatory.
When generation contains that selector, resolution suppresses its duplicate automatic
entry, retains all explicitly saved configurations, and resolves defaults through the
same effective selector. Local selector patches update the effective claim, so an
older team target does not accidentally hide a different auto entry. Detection
fingerprints and the detected document remain unchanged by user-layer resolution.
See `fixtures/run-configuration/build-provider-stable-identities.json`.

The platform guards the source snapshot, atomically writes only the local layer,
then re-reads the result. `shared/fixtures/run-configuration/build-provider.json`
is the canonical persistence example.

`extensions.build-run` stores portable user choices separately from the selector:
`{runtimeArguments?: string[], entrypoint?: string, options?: object, tools?: object}`. Runtime arguments
retain exact argv boundaries (at most 1,024 elements, each at most 65,536 UTF-8 bytes).
The opaque entrypoint is at most 4,096 bytes; an empty string explicitly clears an
inherited entrypoint. `options` holds at most 64 declared Build option values, within
64 KiB of UTF-8 JSON; keys are bounded portable identifiers. Core does not interpret
the values. The native Build service validates every value against the current
selected declaration/model before preparation, including explicit `false` and `[]`.
`tools` maps at most 64 definition IDs to `{home:absolutePath}` or
`{executable:absolutePath}`, or null. Its total UTF-8 JSON is bounded to 64 KiB;
paths are at most 4,096 bytes, with the toolchain lexical path checks. Entries merge
by tool ID across team/local layers. Null clears an inherited Run choice and resumes
directory policy; omission or an empty map preserves existing tool entries. The
native host resolves each active choice against an enabled, referenced definition,
current filesystem facts and version probes. It never changes a directory pin.
Commands, cached executable evidence and debug adapters are not fields in this namespace.

`runConfig.updateOptions` and `runConfig.saveEditorChanges` accept optional
`providerRunOptions` in this shape for a `build.provider` configuration. Omission
preserves that namespace for older callers; explicit null is rejected. A supplied
snapshot replaces each of its fields in the selected layer, normalizing omitted fields
to `runtimeArguments:[]`, `entrypoint:""`, `options:{}` so reset can clear inherited
choices. `tools` instead uses the per-entry inheritance and null-clearing rules above.
Other extension namespaces and the selector remain intact. Re-saving the
same selector preserves its working-directory override and portable choices.
The production macOS store, Windows editor and preference copies carry the typed snapshot unchanged.
See `fixtures/run-configuration/build-provider-options.json`; no new Provider RPC or
SDK protocol version is needed, because preparation reuses accepted v10 launch options. Editor argument text uses quoting/escaping without expansion or execution; empty quoted tokens remain empty argv items. `fixtures/run-configuration/argument-text.json` is shared by Core and both editors.

`runConfig.providerLaunchInputs` takes `{root,configurationId,providerRoot,localDocument?}`
and requires a complete `build.provider` selector. Unmigrated tool-specific records are rejected; only an isolated host import may translate their retired format. It resolves the same document layers for one preparation. It returns bounded typed
`launchOptions`, explicit build-option overrides and project identity without planning
a tool command. For `build.provider`, `extensions.build-run.runtimeArguments` and its
non-empty entrypoint populate launch options, and its `options` populate optionOverrides.
Active fixed choices are returned separately in `tools`, and in `definedTools` by
`runConfig.projectToolchain` for the matching configuration/provider root. They are
host-only resolution inputs and are never forwarded as Provider launch options.
Saved selectors additionally return the exact typed `reference`; the native Build service revalidates its plugin, instance, run, project,
target and execution against the current enabled model. Parameters must be read again
before process launch, and an invalidated configuration or operation rejects late replies.


`runConfig.updateOptions` and `runConfig.createUserConfiguration` are pure
document transformations. They validate scope, paths, supported types, stable
IDs, main classes, modules, and argument parsing, then return UTF-8 JSON in the
`document` field. The platform adapter selects the target project or local
file and performs the atomic write. These commands never write files. An empty
`workingDirectory` removes the layer's `cwd` override. A non-empty value must
name an existing directory inside `root`, given relative to it or as an
absolute path, and is stored project-relative. Values are literal paths; editor
variables such as `${workspaceFolder}` are rejected rather than stored, because
resolution disables and omits a configuration whose `cwd` does not exist. Optional
`mavenSkipTests` writes `extensions.maven.skipTests`; omission removes the
override so the project Maven context is inherited, while explicit `false`
continues to run tests even when the project default skips them.
For project-scoped option updates, selected toolchain paths must resolve inside
`root` and are persisted with `/`-separated project-relative paths. Local-scoped
updates may carry host absolute paths. `runConfig.updateOptions` and
`runConfig.inspect` accept the same optional `localDocument` override.
When `updateOptions` carries a `toolchain` object (`javaHomePath`,
`mavenExecutablePath`, `mavenJavaHomePath`), it writes the document-level
global toolchain into the local layer instead of patching a configuration;
project scope rejects this payload because toolchain paths are machine-local.

The project toolchain may also carry `pathOverrides`, a map of normalized
workspace-relative subproject roots to `{ javaHomePath?, mavenExecutablePath?,
mavenJavaHomePath? }`. The map has at most 256 entries; roots reject absolute,
parent, dot, empty-segment, drive, backslash and control-character forms. Empty
fields inherit project defaults. This map lives only in `.lithe/run/local.json`
and is returned by inspection/resolution; hosts preserve it when saving a run
configuration or project defaults. An absent map identifies a document predating
subproject migration; a saved empty map is an explicit choice. Old platform
preferences are copied and read back before cleanup, with already saved choices
remaining authoritative. See `shared/fixtures/run-configuration/subproject-toolchains.json`.


`execution.resolveSearchPath` accepts already-split `existing` directories and
`candidates` carrying `priority`, opaque `id`, and `path`; lower priority sorts
first, then ID and path. The result appends candidates after existing directories,
omits empty entries, and deduplicates exactly or with ASCII case folding when
`caseInsensitive` is true. The host owns path splitting, joining, discovery, and
filesystem trust. See `shared/fixtures/execution/search-path-v1.json`.

`runConfig.argumentText` accepts `{ "argumentLists": [["--name", "Alice Smith"], []] }`
and returns one editor string per input vector in the same order. Quoting and escaping
are reversible by the existing run-configuration option parser; there is no shell
expansion or execution. Empty arguments remain explicit. The shared cases are in
`shared/fixtures/run-configuration/argument-text.json`.

`runConfig.saveEditorChanges` accepts the normal option-edit payload plus the
required `toolchain` object. In addition to Java and Maven paths, that object
may contain `runtimeExecutablePaths`, keyed by stable generic toolchain ID. It
applies the global toolchain and configuration override edits together,
returning `localDocument`, either a `projectDocument` string or `null`, and
either a `toolchainDocument` string or `null`. The latter updates
`.lithe/toolchains/local.json`, preserves unrelated toolchain IDs, and removes
an entry when its supplied executable path is empty. Local scope combines the
run-option edits in the local run document. Project scope returns the local
defaults and team options as separate fully prepared documents; the platform
adapter writes all returned documents as one transaction with rollback. Empty
per-configuration toolchain paths remove the
corresponding override keys while preserving unrelated extension fields.
Platform clients report the editor save as successful only after the written
documents resolve again. Failures identify whether preparation, document
writing, or post-save reload failed; a reload failure keeps the last usable UI
snapshot and states that the documents were already saved.

Automatic runtime discovery produces an effective executable path for the
current session. Platforms use that same path both to construct
`toolchainCandidates` and to resolve the launch command. An automatic path is
not a persisted user selection and is written to `.lithe/toolchains/local.json`
only after an explicit editor save.
On Windows, Node-backed commands resolve their package-manager shim from the
selected Node installation. They do not fall back to a PATH shim from another
installation, and Windows executable extensions take precedence over extensionless
shell scripts.

Automatic Spring service generation requires both an applied Maven plugin and
exactly one JDT-confirmed, Spring-classified non-test entry in the same module.
An inherited plugin alone cannot promote a library to a runnable service.
Nested-module entries do not promote their parent. Ambiguous, utility and test
mains remain independently selectable Java entries. Module assignment consumes
the confirmed source set even when the caller supplies no editor paths.
Absent discovery may reuse previously confirmed entries; an explicit empty result
removes automatic services. Existing service IDs and user-authored Maven-goal
compatibility configurations retain their established meaning.

`runConfig.createLaunchPlan` accepts `root`, `configurationId`, optional
`currentFile` and `classPath`, optional `debugPort`, and optional
`localDocument`. Maven-backed Run and Debug callers may also supply the same
versioned `mavenContext` accepted by `maven.launchPlan`. Explicit profiles in
the resolved Run Configuration replace the context profiles; otherwise the
project profiles are inherited. Explicit `extensions.maven.skipTests` and
`cwd` values also replace the context values. Core applies the shared settings,
module, Skip Tests, and reactor-working-directory rules to the generated
framework arguments, including `-am` for selected reactor modules. A
project-owned `java.main` caller, or a `spring-boot.maven` caller whose generated
configuration records a Java entry source, instead supplies `javaLaunch` with
the exact JDT LS-selected `mainClass` plus structured `classPaths` and
`modulePaths`. An optional `javaLaunch.buildPrepared: true` is a host receipt
that the current build provider resource task completed before JDT launch
resolution. Core then omits its legacy Maven resource pre-launch step and does
not inspect POMs for that step. The host must recheck workspace/configuration
generation and cancellation before handing off the launch; it cannot reuse a
receipt from another operation. Missing/false retains compatibility for current
Windows callers. See `fixtures/run-configuration/provider-prepared-java.json`. Core then produces a direct `project-jdk` launch; it never
projects those Java entry points into a reactor-wide Maven launch goal. A Spring
Boot configuration without a resolved Java entry source retains its Maven-goal
compatibility path. It
returns a toolchain
reference, argument array, project-relative working directory, and structured
environment references. It does not return a shell command or platform
executable path. All project paths use `/`, reject absolute paths and `..`
traversal, and remain relative to `root`.

The plan may also carry three optional envelope fields. `preLaunchSteps` is an
ordered array of `{ executable, arguments, classpath?, workingDirectory? }` steps
the host runs to completion, in order, before the main process; a non-zero exit
aborts the run and surfaces that step's diagnostics. Each step's `executable`
reuses the plan's
`{ toolchain }` shape plus an optional `tool` selector (`"javac"` resolves the
sibling compiler in the toolchain's `bin` directory; absent means the default
launcher). `classpath` is a structured array of project-relative or host-absolute
entries the host joins with the platform path separator (`:` on POSIX, `;` on
Windows) and prepends as `["-cp", joined]` to the relevant argument list; core
never joins classpath entries because the separator is platform-specific.
`modulepath` follows the same rule and is emitted as `--module-path` by the
host. A JDT main identity in `module/name.Type` form is projected as
`-m module/name.Type` for the direct Java launcher. Empty fields are omitted,
so existing single-process Maven, Gradle, and Node
plans are unchanged. A step shares the plan-level `environment` and, unless it
declares its own project-relative `workingDirectory`, the plan-level
`workingDirectory`. A step that declares one resolves its toolchain from that
directory and runs there, so a resource step still finds the project wrapper
next to its reactor POM when the application working directory is a user
override.

Direct Maven-project Java launches also carry a `project-maven` resource step:
`resources:resources`, plus `resources:testResources` for test-source entrypoints.
The step inherits Maven profiles, settings, repository and module/dependency
selection. Its absolute `-f` POM argument anchors the generated reactor even when
the application working directory is overridden, and its own `workingDirectory`
names that reactor as the step's run directory and toolchain resolution root. A
child POM not declared in
that reactor is processed as its own Maven project, without `-pl`. Resource
filtering and custom resource directories remain Maven-owned; no Java compilation
or application launch goal is added. Hosts must finish these steps successfully
before starting the JVM. Both hosts scope pre-launch execution to the
window/session/execution and stop the owned process tree on Stop, window close or
replacement. They apply the same ten-minute deadline with bounded pipe draining
and cleanup, and a step that reaches its deadline fails the run with
`Pre-launch step timed out after 600 seconds.`. macOS runs the steps before both
the application launch and a Run-panel service session, and cancels a session's
running step when that session stops, restarts, or is dropped by reconciliation.
Independent DAP launches that do
not consume this plan are not covered by this resource-step contract.

A Maven-project `java.main` launch must first ask JDT LS/Java Debug
Server to resolve the exact source target, build its owning project, and return
the runtime classpath/module path. Missing project launch metadata is a launch
error rather than permission to fall back to `mvn exec:java`; reactor-wide Exec
would attempt the same main class in parent and dependency modules.

A `java.main` configuration without a
Maven toolchain launches through `project-jdk` and the configuration's Java
source path only when that source has no Maven ancestor. An older configuration
that omitted the Maven binding is rejected with an instruction to regenerate.
Standalone Java (`java.main` without Maven, and `java.current-file`) compiles
before running: core emits a `javac` pre-launch step writing `.class` files to
`.lithe/run/classes/<configurationId>`, puts that directory on the run
`classpath`, and launches by the qualified class name rather than the source
file. This keeps one-click Run working on JDK 8, which lacks the JEP 330
single-file source launcher (`java File.java`) that only exists on JDK 11+. The
`java.current-file` main class is derived from the file's `package` and declared
class; when the host supplies a project `classPath`, the compiled output leads
the run classpath and the project classes feed the compile step.

`java.codeVision` accepts a workspace root, a target Java path, and Java source
paths. It returns declaration locations and usage counts; Git blame attribution
is joined by the UI from the shared Git result. `java.className` accepts Java
source text and a file simple name and returns the fully qualified runtime class
name.

`java.sourceDefinition` accepts `source`, `declarationName`, an optional
`memberName`, an optional `declarationsOnly`, and an optional `reference`
(`line`, `utf16Column`), returning zero-based `line` and UTF-16 `utf16Column` or
`null` when no declaration is found. A member is looked up as a syntax-tree
method, field, or enum-constant declaration that the `declarationName` type
declares directly. With `reference`, the member is instead resolved from that
position: the identifier must be a plain name or a `this.` access, the innermost
type is searched first and then the enclosing ones, and the result is `null` when
a type on the way may inherit the name or a local may shadow a field.
Without `declarationsOnly`, text that merely resembles a declaration, such as a
call, is accepted next, and then the `declarationName` type; with it, a missing
member returns `null`.

`java.structure` accepts Java `source` and optional `declarationSources`. It
returns `foldRegions`, `inlayHints`, and `syntaxHighlights`.
Fold and inlay line numbers are zero-based because these values are editor
offsets; UTF-16 columns and hidden ranges match the native text editor coordinate
system. Syntax highlights contain document-relative `utf16Start`,
`utf16Length`, and a role from the shared editor syntax-theme contract. They
are sorted and non-overlapping, so native renderers can apply semantic colors
without maintaining another Java parser. The parser is platform-independent
and does not start a Java process or contact JDT.

`spring.index` accepts `root`, workspace-relative `paths`, optional trusted
absolute `metadataRepositories` (and the legacy singular `metadataRepository`),
optional `textOverrides` keyed by relative path, and
`refreshDependencyMetadata`. The command reads Spring configuration
metadata from workspace JSON files and dependency JARs, indexes application
configuration documents and Java source, and returns deterministically ordered
`properties`, `values`, `propertyReferences`, `diagnostics`, `beans`,
`injections`, and `endpoints` collections. Locations use relative paths and
one-based lines and columns.

`properties` include type, documentation, default value, and an optional Java
declaration. `values` include profile/override state and an optional declaration
target. `propertyReferences` represent Java `@Value` uses. Bean resolution
accounts for component names, `@Bean` aliases, interfaces, `@Qualifier`,
`@Resource`, `@Primary`, field injection, and constructor injection. Endpoint
entries expand multiple controller/method paths and retain the exact declared
HTTP method set.

Dependency metadata is cached in the Rust process. Project-open indexing sets
`refreshDependencyMetadata` to `true`; debounced unsaved-buffer indexing leaves
it `false`, so editing Java or configuration files does not repeatedly traverse
and open the local dependency repository. The repository path is selected by
the platform composition layer and is never persisted in shared results.

`mybatis.index` accepts `root`, workspace-relative `paths`, and optional
`textOverrides` keyed by relative path. It pairs Java mapper types with XML
`<mapper namespace>` documents and returns only statements that have both a
Java method and a matching XML `select`/`insert`/`update`/`delete` `id`.
Results are deterministically ordered by namespace, statement id, XML path,
and line. Locations use relative paths and one-based lines and columns.
`javaLine`/`javaColumn` point at the method name; `javaEndColumn` is the
exclusive UTF-16 column after that name. `javaEndLine` is the signature
terminator. `xmlLine`/`xmlColumn`/`xmlEndColumn` bound the statement `id`
value the same way. Hosts intercept go-to-definition only when the caret
is inside those name ranges; return types and parameters keep LSP
navigation. Java methods are collected from `tree-sitter-java` syntax
nodes, so nested generics, split signatures, and commented-out methods
are not mistaken for declarations. XML comments are ignored. Methods with
a method body, including `default` methods, are omitted from the Java
side of the index. Paths are indexed only when they are regular `.java`
or mapper `.xml` files no larger than 2 MiB; `pom.xml` and other
extensions are skipped before content is read.

`diagnostics.redactText` accepts `text` and returns `redacted` with
credentials, tokens, and home-directory paths replaced by stable placeholders
(`<redacted>` for secrets, `<HOME>` for a macOS/Linux `Users`/`home` path or a
Windows drive-letter `Users` path). Hosts run every diagnostic-bundle log
line, panic report, and other free-form text through this command before it
is staged for export; the command never reads the filesystem itself.
Re-running it over already-redacted text is a no-op.

`diagnostics.prepareLogEvent` accepts `{scope,message,fields}` and returns
`{category,scope,message,fields}`. The fixed categories are `application`,
`language`, `run`, `git`, `plugins`, and `performance`; unknown scopes route to
`application`. Recursive field redaction precedes JSON escaping, bounds nesting
and collection sizes, and excludes credential, source-content, buffer, history,
and environment fields. Hosts attach schema version 1, UTC RFC3339 timestamp,
severity, opaque process/session/operation/window identities and sequence numbers.
Native queues, filesystem access, directory fallback and write ownership remain
in platform adapters. See `fixtures/diagnostics/logging-v1.json` for budgets.

`diagnostics.queryLogs` accepts bounded `{sources:[{category,text}],category?,
minimumLevel?,sessionId?,search?,since?,until?,limit?}`. It returns
`{content,truncated,matchedLines}`: a stable merged timeline, inclusive severity
and UTC time bounds, exact session filter, case-insensitive text search, and the
last 1–10000 matching lines. Hosts resolve current/previous session selection,
apply the module/session filters before the file-count cap, read bounded file tails,
discard partial first lines, and report both native
collection truncation and Core query truncation, including files omitted by the cap.
Time comparisons use parsed RFC3339 instants, so fractional precision and equivalent
UTC offsets do not change ordering or inclusive boundaries. Missing filters include all.

Structured logging v2 adds pure opt-in commands. The v1 APIs and commands above
retain their behavior and public Rust signatures. Native adapters own writable
log roots, I/O, clocks, queues, and file lifecycle operations. Core never resolves
logs under installed application resources. Executable cases and numeric errors
are in [`logging-v2.json`](../fixtures/diagnostics/logging-v2.json).

All commands use the existing `{id?,command,payload}` Core request/response
envelope. Malformed payload shapes return outer `invalid_request` without raw
input. Channel, query, and retention domain results are the union
`data:{result:...}` or `data:{error:{code,reason}}`; callers inspect that union even
when outer `ok` is true. Batch encoding returns
`data:{results:[{line}|{error:{code,reason}}]}` in input order. Reasons are safe
parser diagnostics; hosts localize codes for presentation.

- `diagnostics.resolveEngineLogSubject` accepts
  `{role,providerId,pluginId?,logSubject?}` and returns direct
  `data:{channel,segment}` (no nested domain result). `role` is required and is
  `language_server|vcs|build|toolchain|backend`; `providerId` is a required string.
  It calls the same `SessionLogIdentity::new` as engine startup, including the
  stable `invalid-<first 32 lowercase SHA-256 hex digits>` fallback for unsafe or
  absent routing identities. This pure command does no I/O and can run before
  startup. Malformed shapes and unknown roles use outer `invalid_request`, with
  no new numeric or domain code. macOS caches its result by provider ID for
  host-owned stages, cache cleanup, degradation and issue facts; a resolution
  failure skips only that structured host fact and preserves startup/v1 behavior.
- `diagnostics.resolveLogChannel` accepts
  `{channel,rotationIndex?:0,existingChannels?:[]}` and returns
  `{result:{relativePath,category,pluginFilesPath?}}` or `{error}`. The category maps app/update/remote/agent
  and overflow to application, editor/lsp to language, vcs to git, perf to performance,
  run/debug/terminal to run, and plugins to plugins. The optional plugin files
  path is returned only for `plugins/<id>/host` using `plugin_files_path`. Roots are `app`, `editor`, `perf`,
  `lsp`, `vcs`, `run`, `debug`, `terminal`, `remote`, `agent`, `update`, `plugins`.
  Channels are `root`, non-plugin `root/segment`, or `plugins/<id>/host`. Segments match
  `[a-z0-9][a-z0-9._-]{0,63}`, excluding trailing dots and Windows device
  basenames (`con`, `prn`, `aux`, `nul`, `com1`–`com9`, `lpt1`–`lpt9`,
  including those followed by an extension). Paths are `app.log`, `vcs/git.log`, or
  `plugins/<id>/host.log`; positive rotation indices produce `git~1.log` siblings. The `~` delimiter
  cannot occur in a channel, so rotations never alias dotted channel IDs.
  After 128 admitted channels a new identity maps to `_overflow.log`; existing
  channels retain their paths. The overflow sink rotates as `_overflow~1.log`
  and its header uses the channel `_overflow`. Rust `plugin_files_path` returns
  `plugins/<id>/files/`. `session_directory_name`,
  `parse_session_directory_name`, and `session_relative_path` convert explicit
  RFC3339 start time/full UUID to `sessions/YYYY-MM-DDTHH-MM-SS_<8 lowercase
  hex>`. Native adapters join these relative paths only to platform-owned
  writable storage, never a bundle or installation directory.
- `diagnostics.encodeLogBatch` accepts `{validateCatalog?:false,deduplicate?:false,previousEvent?:event,headers?:[],events:[{ts,level,seq,event,op?,msg,
  fields?:{key:scalar}}]}`. `level` is `DEBUG|INFO|WARN|ERROR`, `seq` is `u64`,
  and `ts` is RFC3339 normalized to UTC milliseconds. Scalars become text;
  arrays and objects fail per item. Malformed event shapes also fail per item.
  Disk order is timestamp, level, `seq`, `event`, optional `op`, `msg`, then
  lexical context keys (the truncation marker is last). Keys match
  `[a-z][a-z0-9_]{0,63}` and cannot repeat or reuse reserved keys
  (`ts`, `level`, `seq`, `event`, `op`, `msg`). Event/op
  identities are nonempty bare tokens. Shared redaction runs before escaping,
  including prefixed credential-key fields such as `client_secret` and
  `auth_token`; the same structured-field redactor runs on queried v1/v2
  evidence. Bare values match `[A-Za-z0-9._:/@+-]+`;
  other values use double quotes, escaping quote, backslash, newline, carriage
  return, tab, and other controls as `\u{XX}`. Each result excludes a newline
  and reserves one byte for it within 8192 bytes. Oversized lines shorten the
  longest non-reserved context values first and append `truncated=1`.
  If needed, the message is shortened next; mandatory identity/key overhead
  that still cannot fit returns `-32046`. No context keys are silently dropped.
  Rust `encode_header`/`decode_line` support
  `#lithe-log v2 session=<uuid> pid=<u32> app=<bare version> channel=<channel> started=<UTC milliseconds>`.
  `decode_line` returns a typed header or record and rejects invalid lines with
  reasons. `repeated_event` and `dropped_event` create ordinary `log.repeated`
  records with `count,first,last,of`, and `log.dropped` records with `count`.
  With `deduplicate:true`, adjacent facts with equal event ID, fields, channel,
  level, message and op merge within a batch into `log.repeated`; structural hashing
  is followed by equality comparison. Results then correspond to retained records,
  and the repeated record uses the last omitted event sequence. `previousEvent`
  carries the prior batch’s last input for bounded cross-batch comparison; it is
  validated again and never emitted by itself.
  With `validateCatalog:true`, every ordinary event must exist in `catalog::EVENTS`;
  required/unknown/invalid fields and a mismatched level fail before encoding.
  Messages and channels are derived from the catalog, never trusted from input.
  Before strict field validation, Core redacts declared error/text messages, removes
  control characters, and truncates to at most 1024 bytes at a UTF-8 boundary.
  `catalog::validate_fields` still rejects unnormalized strings, invalid types, unknown
  keys, incomplete error components, and invalid code/domain tokens.
  Path fields are redacted before template interpolation; unrecognized absolute
  paths become `<PATH>`. Item results additionally contain `channel` on success.
  Codes: `-32053` unknown event, `-32054` missing field, `-32055` invalid field,
  `-32056` unknown field, `-32057` catalog level mismatch.
  Catalog validation rejects `event:legacy` as an unknown event. macOS collects only v2
  session files; its v1 files participate solely in age retention. The public v1
  APIs, old commands and shared v1 query compatibility remain available to Windows.
  `log.dropped` and `log.repeated` accept only their documented field shapes and
  an optional validated `channel`. No other identity bypasses catalog validation.
  Optional `headers:[{session,pid,app,channel,started}]` returns ordered `headers`
  results and `sessionPath`, using the same Core header/session grammar. These
  fields are additive; the default generic PR1 batch remains compatible.
  Overflow rotation paths are `_overflow~1.log` and `_overflow~2.log`.
- `diagnostics.queryLogsV2` accepts `{sources:[{relativePath,text,
  startsMidLine?:false,firstLineNumber?:1}],channelPrefixes?:[],minimumLevel?,levels?:[],
  since?,until?,search?,fields?:{key:value},op?,limit?,expression?,histogramBuckets?}`. The adapter marks a
  tail beginning inside a line with `startsMidLine:true`; Core discards its
  first fragment without counting it as invalid. Complete first lines stay.
  Paths are session-relative v2 paths, `sessions/<name>/<path>`, or legacy
  `<category>/lithe.*.log`. Channel prefixes match slash boundaries; severity
  and parsed RFC3339 time bounds are inclusive; `levels` is an exact severity set
  (intersected with `minimumLevel`; an empty array matches nothing); search is case-insensitive;
  field/op filters match exactly, including reserved `ts` and `level` fields. Returns `{result:{records:[{channel,
  relativePath,lineNumber,ts,level,seq,event,op?,msg,fields}],channelCounts:
  {channel:{warn,error}},truncated,skippedInvalidLines}}` or `{error}`.
  Counts reflect all filtered matches before the newest 1–10000 limit (default
  2000). Records sort ascending by parsed timestamp, seq, file, line, then
  source order. The aggregate native-tail byte budget is 10 MiB. Omitted bytes,
  partial first lines, or output limits set `truncated`. Invalid physical lines
  are skipped and counted. V1 records use `event:legacy`, preserve available
  sequence/op/context, and map application→app, language→lsp, git→vcs,
  performance→perf, run→run, plugins→plugins. Queries redact decoded evidence.
  Each returned record also includes `line`, the canonical, redacted v2 line for
  presentation and frozen export (without a newline).
- `diagnostics.planLogCollection` accepts `{files:[{relativePath,sizeBytes,modifiedAt}],
  currentSession,session,category?,recentSessions?,since?}`. Inventory is raw log-root-relative native
  metadata; no contents are read before planning. `session` is `all|current|previous`,
  and category is one of the existing six product categories. Returns
  `{result:{reads:[{relativePath,offset,maxBytes}],truncated,estimatedBytes,sessions}}` or `{error}`.
  Only validated v2 session log files are selected; plugin-owned `files/` and legacy
  files remain retention inputs. Filters run before budgets. Order is newest session,
  active before rotation 1 before rotation 2, descending native modification instant,
  then lexical path. Session ties use descending basename. Previous means the newest
  session other than current. Reads are capped at 200 files, 2 MiB per file and 10 MiB
  aggregate. Any omitted eligible bytes/files set truncated. Duplicate paths or invalid
  selections return -32058; invalid selected timestamps return -32035. Exact native
  offsets and read sizes belong to Core; adapters validate containment and report I/O errors.
- `diagnostics.planLogRetention` accepts `{sessions:[{name,files:[{
  relativePath,sizeBytes,modifiedAt}]}],legacyFiles?:[same file shape],
  currentSession,now,limits?:{maxAgeMs,totalBytes,perfBytes,pluginFilesBytes},
  startupCleanup?:false}`. Timestamps are explicit RFC3339. Defaults are 30
  days, 100 MiB combined, 20 MiB perf, 20 MiB per plugin files directory per
  session. Returns `{result:{deletions:[{relativePath,directory,reason}],
  warnings:[{session,pluginId,relativePath,sizeBytes,limitBytes}]}}` or `{error}`.
  Paths are relative to the writable log root and sorted lexically. Whole
  sessions expire first, combined pressure removes oldest whole sessions,
  then perf files are removed from oldest surviving sessions and startup
  cleanup removes oldest plugin files. Whole-session removal supersedes child
  deletion. Reasons are `expired|totalBudget|perfBudget|pluginFilesBudget`.
  The current session and all its files are always protected, even if budgets
  cannot be satisfied. Runtime plugin overages emit warnings; startup may also
  delete files in inactive sessions. Legacy files count toward the total but
  only age can delete them. `should_rotate(size)` is true above 10 MiB;
  `rotation_indices_to_delete` returns existing indices >=2 to remove before
  shifting active→1 and 1→2, retaining three segments including active;
  `rotation_paths_to_delete` resolves those indices to session-relative paths.
  Unsafe paths, duplicate inventories, and negative age limits are rejected.

#### Log-window pure APIs (PR4 stage A)

These additions do not change any v1 public item or the bytes of v1
`level/message/detail` evidence. All new request fields are optional. Standard
Core envelopes remain `{ok:true,data:...}`; domain failures of compose, format,
query and collection are `data:{error:{code,message}}`, and their successes are
`data:{result:...}`. Parse succeeds directly as `data:{terms,errors}` because an
incomplete draft is an expected editing state. Malformed JSON payload shapes use
the existing outer InvalidRequest failure.

`diagnostics.parseLogFilter` accepts `{expression}` (at most 1024 UTF-8 bytes).
Returns `{terms:[{kind,key?,value,negate,start,end}],errors:[{start,end,code,message}]}`.
Ranges are half-open **UTF-16 code-unit offsets**, including negation and quotes,
for native text highlighting. For an over-budget expression, the sole
`expressionTooLong` diagnostic has `[0,0)` to avoid scanning unbounded input.
Kinds: `level_at_least|level|op|event|channel|regex|field|text`.
All terms intersect; a leading `-` negates a term, while `-` alone is text.
Whitespace separates terms except inside quotes or `/regex/`. Quoted values
support `\\` and `\"` escapes; other quoted escapes fail. A quoted bare token
always means text, including a leading hyphen or reserved-looking syntax.

- `level>=debug|info|warn|error` is inclusive; `level:<value>` is exact.
  Aliases `dbg/inf/wrn/err` and operator names are case-insensitive. Parsed level
  values normalize to the full lowercase label. Unknown levels are errors.
- `op:`, `event:`, `channel:` perform case-insensitive string prefix matching.
  Expression channel prefixes intentionally do not require a slash boundary;
  the existing `channelPrefixes` argument retains its boundary semantics.
- `/pattern/` matches the message case-insensitively using the existing Rust regex
  engine: at most 256 Unicode characters, 1 MiB compiled size and DFA cache limits.
  Whitespace inside regex delimiters is allowed; escaped slashes remain regex text.
- `key:value` / `key=value`, for `[A-Za-z0-9_.]+` keys other than reserved
  operators above, match case-insensitive substrings in the field's string form.
  Reserved record fields `ts/seq/msg` and context fields `server/plugin` are supported.
  Keys compare case-insensitively. Reserved operators require `:`, not `=`.
- Other bare words use the existing search scope: channel/event/op/message/context.
  Empty values, malformed quotes, unsupported escapes and invalid regexes are errors.

Diagnostic codes: `expressionTooLong`, `regexTooLong`, `invalidRegex`,
`invalidLevel`, `emptyValue`, `unterminatedRegex`, `unterminatedQuote`,
`invalidEscape`, `invalidOperator`, `invalidQuote`. Messages are fixed technical
English; hosts localize by code. `queryLogsV2` rejects any erroneous expression
with **-32060, "Invalid log filter expression"**; hosts retain the prior results
and use parse diagnostics for the draft.

`diagnostics.composeLogFilter` accepts `{expression,term:{kind,key?,value,negate?:false}}`
and returns `{expression}` in `result`. Positive predicates replace all existing
positive predicates of the same kind (field predicates additionally require the
same key), placing the new token at the first replaced position. Negative
predicates append unless an identical negative predicate exists. Non-regex values
compare case-insensitively for deduplication; regex patterns compare exactly because
inline flags can affect semantics. Other source tokens, whitespace and order remain
unchanged. Values are quoted/escaped as needed; text is always quoted. Invalid drafts,
invalid terms or a composed expression over 1024 bytes return -32060.

`queryLogsV2` adds these fields in `result`:

```json
{
  "records": [{"line":"...", "channel":"app", "relativePath":"app.log", "lineNumber":1,
    "ts":"2026-11-03T00:00:00.000Z", "level":"WARN", "seq":1,
    "event":"app.failed", "op":"one", "msg":"failed", "fields":{},
    "foldKey":"c4d60ef213ff7102", "epochMs":1793664000000, "opOffsetMs":0}],
  "foldMinimumRun":3,
  "channels":{"app":{"total":1,"warn":1,"error":0}},
  "channelCounts":{"app":{"warn":1,"error":0}},
  "histogram":{"startEpochMs":1793664000000,"endEpochMs":1793664000001,
    "bucketMs":1,"buckets":[{"debug":0,"info":0,"warn":1,"error":0}]},
  "opSummary":{"op":"one","count":1,"firstEpochMs":1793664000000,
    "lastEpochMs":1793664000000,"durationMs":0},
  "truncated":false,"skippedInvalidLines":0
}
```

`queryLogsV2` additionally accepts optional `filterSince` / `filterUntil` RFC3339
bounds, intersected with `since` / `until`. Each pair must be ordered (-32052 otherwise);
a disjoint intersection succeeds with zero records. This lets an export range and a
window time selection share Core's exact instant comparison.

Optional `afterSequences:{sessionBasename:u64}` excludes records at or below the
specified session's sequence. Keys use the session directory grammar; the empty key
represents session-relative sources without a `sessions/<name>/` prefix. Sequences
from different sessions are never compared. The response's `sessionSequences` maps
each supplied session to its highest decoded sequence, before filters and limits.
Native live sources should carry their current session prefix so historical and
live queries use the same identity. Missing fields preserve existing queries.

`foldKey` is lowercase 16-digit FNV-1a 64 hex over channel, canonical uppercase
level, event, message in that order; each UTF-8 value is preceded by its byte length
as a little-endian u64. This encoding is stable across versions/architectures.
Hosts group adjacent equal keys and collapse only runs of at least 3.
`epochMs` parses the record timestamp; submillisecond ordering still uses the full
instant. `channels` counts all decoded records before filters, within supplied input
and its byte budget. Existing `channelCounts` retains filtered-before-limit semantics.

`histogramBuckets` must be 1..240 (else -32061). Histogram uses every predicate
**except since/until**, before output limiting. `histogram` is null when absent or
empty. Exactly the requested number of buckets is returned, including empty trailing
buckets; width is `ceil((maxEpochMs-minEpochMs+1)/count)`, at least 1 ms, and end is
exclusive `start + width*count`. The maximum event is always included.
`opSummary` and per-record `opOffsetMs` appear only with the existing explicit `op`
argument. Summary includes all matches of all query predicates before limit;
offset is relative to its earliest instant. An empty op result has count/instants/
duration zero. Filtering op through expression alone does not add these fields.

`diagnostics.formatLogRecords` accepts
`{lines:[String],format:"json"|"markdown",environment?:{appVersion,osVersion,architecture,plugins:[String]}}`
and returns `{text}` in `result`. Limits: 10000 lines and 4 MiB including one separator
byte per line; environment strings total at most 64 KiB and at most 1000 plugin IDs.
Budget violations use -32062. Each line is decoded again: decoder failures keep their
precise codes, headers/noncanonical/nonredacted lines use -32063. JSON without an
environment is one pretty object for one line, otherwise an array (including empty).
With environment it is `{environment:{...},records:[...]}`. Markdown is
`**Lithe**` plus optional version/OS/architecture JSON strings separated by ` · `,
optional `Plugins: [JSON strings]`, a blank line and an `ndjson` fenced block of
unchanged canonical lines followed by a newline. The fence grows if evidence contains
backticks. The evidence grammar remains canonical v2 even though the technical fence
label is `ndjson`. Keys/headings are fixed English report syntax, not UI copy.

Collection inventory is bounded to 10000 entries. `recentSessions` must be 1..10,
otherwise -32058. It includes current (even with no eligible files or a skewed clock), then selects
the newest remaining sessions to fill N slots, **before** intersecting `session:all|current|previous`, category
and since. `since` is
inclusive RFC3339 (-32035 if invalid): a file qualifies if its session directory start
**or** its modification instant reaches the cutoff. Previous still means the newest
inventory session other than current, independent of category/time. Budgets apply last.
`sessions` lists eligible session names before read budgets, newest first, excluding
sessions with no eligible files; `estimatedBytes` sums selected `maxBytes` (already
bounded by each file size), before compression. Crash collection remains host-owned
and passes through `diagnostics.redactText`.

Each v2 numeric domain code has one meaning. Existing outer Core string codes
are unchanged:

| Code | Meaning |
| --- | --- |
| -32031 | Unknown channel root |
| -32032 | Unsupported channel shape |
| -32033 | Invalid channel/plugin segment |
| -32034 | Invalid full session UUID |
| -32035 | Invalid timestamp |
| -32036 | Invalid session directory basename |
| -32037 | Invalid context field key |
| -32038 | Reserved key reused as context |
| -32039 | Duplicate context key |
| -32040 | Invalid file header |
| -32041 | Invalid line grammar |
| -32042 | Invalid value escape |
| -32043 | Missing or misordered reserved fields |
| -32044 | Invalid unpadded u64 sequence |
| -32045 | Invalid log level |
| -32046 | Line cannot fit the byte budget |
| -32047 | Non-scalar context value |
| -32048 | Invalid event or operation identity |
| -32049 | Invalid retention inventory or limits |
| -32050 | Invalid query source path or line origin |
| -32051 | Invalid structured event JSON shape |
| -32052 | Reversed query time range |
| -32053 | Unknown catalog event |
| -32054 | Missing catalog field |
| -32055 | Invalid catalog field |
| -32056 | Unknown catalog field |
| -32057 | Catalog level mismatch |
| -32058 | Invalid collection inventory or selection |
| -32059 | Core event owner mismatch |
| -32060 | Invalid log filter expression |
| -32061 | Invalid histogram bucket count |
| -32062 | Log copy input exceeds budget |
| -32063 | Expected canonical redacted log record |
| -32064 | Invalid host plugin operation |

Diagnostic previews freeze the selected redacted bytes before confirmation.
Windows returns a `snapshotId` from `preview_diagnostic_bundle`; export consumes
that exact ID once. Discard releases it on cancel; at most four previews remain
in memory for five minutes. macOS retains the staged files until export/cancel.
Both exports include `collection-status.txt` with truncation, dropped-event and
write-failure counts. Legacy flat logs remain available with the all-session
selection; native adapters never scan arbitrary workspace or terminal files.
Detailed diagnostics are limited to the selected category and expire after
15 minutes; warnings/errors remain enabled in installed builds.

The native settings entry is Tools → Logs and Diagnostics on both platforms;
persisted category identities remain `Diagnostics` (macOS) and `logs` (Windows).
The timeline, diagnostics, locations, retention/cleanup and export sections follow
`fixtures/diagnostics/logging-ui-v1.json`. Clearing explicitly affects all managed
modules/sessions in the effective directory regardless of display filters.
Preview confirmation shows its frozen module/session/level selection. Native
views retain platform styling and present actual diagnostic scope and collection
health, rather than inferring them from the currently selected view filter.

`diagnostics.buildManifest` accepts an `environment` object
(`appVersion`, `osName`, `osVersion`, `cpuCoreCount`, `memoryRssBytes`,
`diskFreeBytes`), a `files` array of already-staged, already-redacted entries
(`relativePath`, `sizeBytes`, `description`), and
`generatedAtEpochMilliseconds`. It returns a `schemaVersion`ed manifest with
`files` sorted by `relativePath` so the listing shown to the user before they
confirm a diagnostic export — and the zip's contents — are deterministic
across runs and across platforms. Hosts gather the environment and file facts
natively; this command only shapes and sorts them. The additive top-level
`redaction:"core-v2"` identifies the shared redaction boundary; schemaVersion remains 1.
Windows consumes the original fields and may ignore this marker.

### Declarative plugins

The `plugins.declarative.*` commands implement
[`plugins/v1`](plugins/v1/README.md). They are pure: they never read the
package or the workspace, so hosts pass the parsed `plugin.json` and the
relevant facts with every call.

`plugins.declarative.validate` accepts
`{ "manifest": object, "hostCapabilities"?: { "<capability>": [integer] } }`
and returns `{ "status": "ok", "plugin": object }` with the normalized
manifest (names lowercased and sorted, argument order preserved), or
`{ "status": "rejected", "error": { "code", "message", "field"? } }` with a
stable `plugin.*` code. When the host sends the capability versions it runs,
a level 3 manifest that requires another one is `plugin.api.unsupported`;
levels 1 and 2 are unaffected. See Capability versions in
[`plugins/v1`](plugins/v1/README.md).

`plugins.declarative.runPlan`, `plugins.declarative.discoverTests`, and
`plugins.declarative.testPlan` accept
`{ "manifest": object, "languageID": string, "request": object }` and
revalidate the manifest first. Their requests are respectively
`{ relativeFilePath, arguments? }`, `{ relativeProjectFilePaths }`, and
`{ scope: { kind: "workspace" } | { kind: "file", relativeFilePath } |
{ kind: "testCase", identifier, relativeFilePath? }, relativeProjectFilePaths }`.
Success returns `plan` (`executable`, `arguments`, `workingDirectory`, plus
`label` and `frameworkID` for tests) or `items`; refusals use the same
`rejected` shape. Only a malformed payload is an `invalid_request` failure.
`shared/contracts/plugins/v1/fixtures/` holds the golden cases.

`plugins.declarative.languageServerLaunchPlan` accepts
`{ "manifest": object, "languageID"?: string, "buildSystemID"?: string,
"request": object }` with exactly one of `languageID` (a language server) and
`buildSystemID` (a build provider); naming neither or both is an
`invalid_request` failure. The request is `{ pluginDirectory, stateDirectory,
workspaceStateDirectory, architecture, settings?, projectSettings? }`. The directories are absolute host paths used only
as substitution text; the command does not read or create them. `settings` maps
setting IDs to the values the user stored for every project, and
`projectSettings` to the open project's overrides; a project value counts only
for a `scope: "project"` setting, and a missing, unknown, or no longer
acceptable value falls back to the next layer and then the declared default. Success returns
`plan` with `launch`, `arguments`, `validationArguments`,
`runtimeRequirements`, `requiredDirectories`, `requiredPackagePaths`, and
`initializationOptions`, `hostIntegration`, `settings` (the effective
values), and `workspaceConfiguration` (the server's expanded
`workspaceConfiguration`, `languageServers` 2) when the plugin declares them. A `buildSystemID` plan adds
`buildProvider: { buildSystemID, executesProjectCode, mayUseNetwork,
languageServer? }`; with `languageServer` the plan is that language server's
and the host reuses its session. An unknown
architecture or an empty directory is refused with
`plugin.launch.invalidRequest`; a language without a server, an undeclared
build system, and a build system without a provider with
`plugin.launch.unavailable`.

A language server declared with `launch.kind: "backend"` (`serverProcess` 3) has
no command line in its manifest; the plugin's backend chooses it. The plan this
command returns is then only the first step: `launch` is `{ kind: "backend",
function, timeoutMilliseconds }` (30000 when absent) and `resolveParams` is the
params the host sends to that backend function, `{ serverID, platform: { os,
arch }, stateDirectory, workspaceStateDirectory, logDirectory,
temporaryDirectory, settings }`; the host adds `context` and, when the plugin
declares tool definitions, `tools`. The request must carry all four of
`stateDirectory`, `workspaceStateDirectory`, `logDirectory`, and
`temporaryDirectory`, and the plan lists them in `requiredDirectories`. A server
below `languageServers` 3 has no `sessionPolicy`; a version 3 plan carries it
(`serverID`, `requestMethods`, `commands`, `serializedCommands`,
`forwardNotifications`, `remote`, `gates`, `state`) for the engine to enforce.

`plugins.languageServers.decodeLaunch` is the second step. It accepts
`{ manifest, languageID, request, result }`, where `request` is the first
step's request and `result` is what the backend function returned, and answers
`{ status: "ok", plan }` with the plan the host starts like any other (launch
`packaged` or `tool`, `arguments`, `environment`, `writablePaths`,
`requiredDirectories`, `initializationOptions?`, `workspaceConfiguration?`, and
`sessionPolicy` with the answer's `gates`) or `{ status: "rejected", error }`.
Refusals are `plugin.launch.unavailable` (no such server),
`plugin.launch.notBackend` (the server is not launched by a backend),
`plugin.launch.invalidRequest` (a missing directory), and
`plugin.launch.invalidResult`, `plugin.launch.outsidePackage`,
`plugin.launch.undeclaredTool`, and `plugin.launch.unwritablePath` for the
answer. The golden cases are
`shared/contracts/plugins/v1/fixtures/languages/language-server-launch-resolution.json`.

`plugins.languageServers.stateRetention` accepts `{ retention: { maxEntries,
maxAgeDays }, nowUnixSeconds, entries: [{ name, lastModifiedUnixSeconds }],
activeNames }` and returns `{ expiredNames }`: the inactive per-workspace state
directories the host deletes. Directories used by a running session
(`activeNames`) are never listed and count against `maxEntries`; of the others,
those older than `maxAgeDays` and those beyond the newest that fit are listed.
The host lists and deletes only directories under its own state storage, never
inside an app bundle or installation directory.

`plugins.contentProviders.decode` accepts `{ result }`, the value a plugin
function returned for a document of its content scheme, and returns
`{ content }`. `result` is a string, or an object whose only member is
`content: string`; anything else is `invalid_request`, and so is text of more
than 1 MiB (1,048,576 UTF-8 bytes). The host opens `content` as a read-only
document and never interprets it.

A `debugAdapterID` selects a `debugAdapters[]` entry with a `serverProcess`
or a `tcpLanguageServer` transport (naming it together with another selector is
the same `invalid_request` failure); the plan adds `debugAdapter: { id,
providerID, displayName, adapterID, requests, selectors, configurationTypes,
transport, endpoint?, disabledCapabilities }`. An adapter that starts on the
selected runtime is refused with `plugin.launch.unavailable`. A
`tcpLanguageServer` adapter has no process of its own: its plan is the launch
plan of the plugin language server that `endpoint.languageID` names, so the
host starts that server as for editing, then sends `workspace/executeCommand`
with `endpoint.command` and connects to the loopback port the server answers
with (an integer or a numeric string from 1 to 65535). When that server's
launch is resolved by the plugin backend (`serverProcess` 3), the plan names
only `launch: { kind: "backend", function, timeoutMilliseconds }` with empty
`requiredDirectories` and no `resolveParams`: the server's own session asks
the backend with the directories of its start, so resolving the adapter needs
no `workspaceStateDirectory`, `logDirectory` or `temporaryDirectory`. Core validates every declared
`transport`, but a host starts only the transports it implements: the macOS host
runs `stdio` and refuses `tcpPort` and `tcpAnnounced` before starting the
process, with `plugin.launch.unsupportedTransport`.

`debug.adapters.startArguments` accepts `{ manifest, adapterID, request:
"launch" | "attach", facts: { registration: { generation, currentGeneration },
runtimeSelection?, target: { kind, path?, processID?, workingDirectory?,
executable?, host?, port?, pathMappings? } } }`
and returns `{ status: "ok", arguments, connection? }`: the request's configured
`arguments` with each `targetBindings` name filled from the target unless the
configuration already sets it. `program` is filled from `target.path`, or from
`target.executable` (an absolute path the host found) when the configuration
binds it to `target.executable`. Refusals use the `rejected` shape with
`debug.provider.stale`, `debug.request.unsupported`, `debug.runtime.stale`, or
`debug.target.invalid`.

A target of `kind: "connection"` attaches to a debuggee on a host and port:
`host` is a DNS name or IP literal, `port` is 1–65535, and `pathMappings` is up
to 16 `{ local, remote }` source-root pairs whose `local` is an absolute path on
the host's platform. It is accepted only for `attach` and only by an adapter
whose attach configuration declares a `connection` binding; the binding names
the argument paths that receive each fact, so Core writes `hostName`,
`connect.host`, or a joined `host:port` string as that adapter reads it. A bad
`host`, `port`, or `pathMappings` entry is `debug.target.invalid` with the field
`target.host`, `target.port`, or `target.pathMappings`; so is
`pathMappings` sent to an adapter that declares no mapping argument, and a
`connection` target for a `launch` or an adapter without the binding
(`target.kind`). The response then carries `connection: { host, port, remote }`.
`remote` is `false` only for `localhost`, `127.0.0.0/8`, and `::1` read from the
text; every other host is `true`, including `0.0.0.0` and `::ffff:127.0.0.1`.
Core does not resolve names and opens no socket; the host asks the user before it
connects to a `remote` endpoint and does not remember the answer by default. The
launch plan's `debugAdapter.remoteAttach` is `{ pathMappings, maxPathMappings }`
for an adapter that takes a connection and `null` otherwise. The mappings reach
the adapter in the shape its binding declares (`objects`, `first`, `dictionary`,
or `pairs`); a shape that cannot hold them all (`first` takes one, a
`dictionary` takes each root once on its keyed side) refuses the target with
`target.pathMappings` instead of dropping some.

`debug.adapters.executablePlan` accepts `{ manifest, adapterID, settings?,
projectSettings?, workspace?, targetPath? }` and returns `{ status: "ok",
plan }`. `plan` is `null` when the adapter's launch configuration declares no
`executable` lookup; otherwise `{ setting, configured, candidates }`.
`configured` is `{ path, source }` when the lookup's `file` setting has a
non-empty effective value (`source` being `project`, `global`, or `default`)
and `null` otherwise. `candidates` are the absolute paths to try in order,
expanded from `workspace` and `targetPath`; a candidate that needs a variable
the host did not send is left out. Core never touches the file system: the host
checks `configured` first, and a configured path that is not a runnable file is
an error, not a reason to try the candidates.

`plugins.declarative.resolveSettings` accepts
`{ manifest, settings?, projectSettings? }` and returns `settings`: one
`{ id, value, source }` per declared setting, `source` being `project`,
`global`, or `default`. `plugins.declarative.workspaceConfiguration` accepts
the same payload plus a required `languageID` and returns `configuration`,
the expanded object, or `null` when that server declares none; a language
without a server of the plugin is refused with `plugin.launch.unavailable`.
Hosts never merge layers themselves.

`plugins.declarative.checkRuntimeVersion` accepts
`{ tool, minimumVersion, output }`, where `output` is what the runtime printed
for the plan's `launch.versionArguments`, and returns
`{ "status": "ok", "check": { "satisfied": bool, "version"?: string } }`.
`version` is absent when the output contains none. It takes no manifest.

`plugins.declarative.decodeGrammar` accepts `{ manifest, languageID, grammar }`,
where `grammar` is the text the host read from the language's `grammar.path`
inside the installed package, and returns `language: { id, fileExtensions,
fileNames, grammar: { kind, source }, configuration }`. `source` is the
validated original JSON text, kept opaque through host dictionaries so Monarch's
ordered `cases` retain their precedence. Only the terminable worker parses and
compiles it, explicitly using `root` when `start` is absent. A grammar Core
refuses is `plugin.grammar.invalid` with the failing `field`; a language
without static editor resources is `plugin.grammar.unavailable`. Configuration-only
languages return `grammar:null` and require no file read. Core reads no files.

`plugins.hostApi.describe` accepts `{}` and returns `{methods:[{method,service,grant,coreServed}]}`.
`grant` is null for implicit methods, a service name for legacy aggregate grants, or the
exact method for individual grants. `coreServed` identifies methods dispatched inside
Core rather than by a native handler. The host admits a requested grant only when all of
its non-Core methods have registered handlers.

`plugins.hostApi.authorize` accepts `{method,service,grants}` and returns `{allowed:true}`
or `{allowed:false,code}`. It uses Core's method catalog and capability rules; unknown or
mismatched methods return `plugin.host.unavailable`, and missing grants return
`plugin.host.permissionDenied`. This decision does not replace negotiated-version,
parameter, current-session, workspace-context, or resource-ownership checks. Hosts must
deny access if the Core call fails.
Shared cases are in `shared/fixtures/plugins/host-api-v1.json`.

`plugins.editorActions.decode` accepts `{kind:"registration",value}` or
`{kind:"actions",value,text}` and returns `{registration}` or `{actions}`.
Core validates literal selectors, one-based UTF-16 ranges and bounded opaque
function bindings. Version 1 (the default) admits the icons `run` and
`run-all` and a 128 KiB source. `version: 2` with the host's `icons` and
`sourceBytes` also admits `alternatives` and `{kind:"invokeResult",value}`,
which returns `{}` or `{reveal:{locations}}` for a clicked action. Hosts enforce
permission, live document versions and session ownership; HTTP/SQL business
semantics stay with plugins. See the plugin contract's independent editor
actions section.

`plugins.editorProviders.decode` accepts `{kind:"registration",value,types}`
(the provider types the host routes) and returns `{registration}` with
lowercased literal selectors and Core's per-type `budgetMs`; a type outside
`types` is `not_supported` with details `providers.<type>`. It also accepts
`{kind:"result",type,value,legend?}` (one provider function's LSP 3.17 shaped
result; semantic tokens need the registered legend) and returns `{result}`
normalized to `{locations}`, `{contents,range?}`, `{isIncomplete,items}`,
`{lenses}`, `{ranges}`, `{data}` or `{links}`. Hosts own calls, budgets,
stale-version drops and the merge after language-server answers; see the
plugin contract's editor language-feature providers section. The definition
merge is Core's too: `{kind:"mergeDefinitions",value:{documentUri,position,server,plugin}}`
takes the language server's and the plugins' validated `Location[]` and returns
the indices each side keeps as `{server,plugin}`. The server's answer comes
first; a plugin location equal to one already kept is dropped, and a server
location that covers the requested position itself (the caret already sits on
the declaration) yields when a plugin answered.

`toolchains.instantiateLaunch` accepts `{ registry, tool, executable, home?,
entry?, runtimeArguments, arguments }` and returns `{ status: "ok", launch:
{ executable, arguments, versionArguments } }`. See
[Launching a tool definition](plugins/v1/toolchains/README.md#launching-a-tool-definition).

`run.decodeStart` accepts `{ manifest, workspaceRoot, temporaryDirectory?,
params }`, where `params` are those of `lithe/host/run/start` as the backend sent
them. It returns `{ status: "ok", start }` with `start` being `{ label,
executable: { kind: "toolchain" | "packaged", value }, arguments,
workingDirectory, environment, temporaryFiles: [{ path, contents }], debug?,
rerun? }`. The tool must be listed in the manifest's `requiresTools`, and the
working directory must be a relative path of an existing directory inside
`workspaceRoot`, which Core checks read-only the way it does for run preparation.
`${temporaryFile:<name>}` in arguments and environment becomes a file path under
`temporaryDirectory`, which the host supplies when the start has temporary files;
Core writes nothing, the host writes `temporaryFiles`. A start Core refuses is
`{ status: "rejected", error }` with `plugin.run.invalidStart` and the failing
`field`. See the plugin contract's
[run and debug sessions](plugins/v1/README.md#run-and-debug-sessions-protocol-version-3).

`debug.decodeBackendConfiguration` accepts `{ manifest, params }` with the
params of `lithe/host/debug/start` and returns `{ status: "ok", start }` with
`start` being `{ adapterID, request, label, configuration }`, `adapterID` the
qualified ID. A start Core refuses is `{ status: "rejected", error }` with
`plugin.debug.invalidStart`, `plugin.debug.unknownAdapter`,
`plugin.debug.foreignAdapter`, or `plugin.debug.limitExceeded`.

`outputLinks.match` accepts `{ scope, platform, caseSensitive?, workspaceRoots,
sources: [{ pluginID, matchers }], lines }` and returns `{ links }`;
`outputLinks.decodeResolution` accepts `{ reply }` and returns the location
`{ path, line?, column? }` or `null`. Neither takes a manifest: the host passes
the matchers of each enabled plugin as `plugins.declarative.validate` returned
them. A request Core cannot accept is `invalid_request`, not a policy outcome.
See the plugin contract's
[output link matchers](plugins/v1/README.md#output-link-matchers-outputlinkmatchers-1).


The `plugins.marketplace.*` commands are equally pure: hosts fetch indexes and
archives and pass the parsed JSON. `validateIndex` accepts
`{ index, sourceKind: "official" | "thirdParty", platform, hostCapabilities? }`
and returns `{ status: "ok", index: { plugins, rejected } }` with per-entry
`availability`; a level 3 version is available only when every capability it
requires is in `hostCapabilities`; `resolveSource` accepts `{ url }` and returns
`{ status: "ok", source: { indexURL, repository, displayName } }`;
`installReview` accepts `{ manifest, expectedID?, expectedVersion?,
approvedPrograms?, hostCapabilities? }` and returns `{ status: "ok", review: { id, version,
permissions, programs, newPrograms } }`. Content problems use the same
`rejected` shape; see the Marketplace section of
[`plugins/v1`](plugins/v1/README.md) and `fixtures/marketplace/`.

### Build systems

The `build.*` commands implement API level 3 `buildSystems` of
[`plugins/v1`](plugins/v1/README.md). Every build tool shares them, so a host
has one build workflow and never branches on a build-system ID: Core plans
each process, the host runs it with the discovered executable, and Core
decodes what it printed or wrote.

A build system with a `provider` requires `buildProviders: 1`, version 2 when
a task uses `source: "provider"`, version 3 when tests do, or version 4 for
provider application run preparation, version 5 for native debug preparation, and
version 6 for optional read-only model inputs. Core validates and plans all six versions;
a host advertises each only after implementing its lifecycle and requests.
macOS advertises all six and routes provider tasks, tests and run preparation through
the existing workspace session. Prepared applications use the existing native Run host. Windows does not yet advertise Provider lifecycle support.

Except `build.detect`, `build.projectOptions` and `build.resolveStoredOptions`, every command accepts
`{ manifest, buildSystemID, request }`, revalidates the manifest, and answers
`plugin.build.unavailable` for an undeclared build system or operation.
Results use the `plugins.declarative.*` envelope under the key named below;
selections the declaration does not allow are `plugin.build.invalidSelection`,
output that does not fit its decoder is `plugin.build.invalidOutput`, and a
malformed payload is an `invalid_request` failure.

Executable candidates are normalized by the shared plugin executable-resolution
mechanism before platform filtering. A `setting` candidate emits
`{kind: "setting", settingID, path: absolutePath | null}` in the same `executables`
list; null skips, invalid stored values reject the plan, and native validation
failure is terminal. There is no separate `configuredExecutable` result.
See the plugin contract's **Shared executable candidates** section for ordering,
capability negotiation and the compatibility adapter for published v2 previews.

Host-managed runtime probes use `java -version` (including Java 8),
`node --version`, and `go version`. Hosts execute the returned arguments and
pass combined stdout and stderr as `build.checkToolVersion.request.output`:
Java normally prints its version to stderr. Core normalizes legacy Java
`1.8.0_…` output to major version 8 before comparing the declared minimum,
and ignores `Picked up …` environment-option notices preceding the version.

Paths in requests are workspace-relative with `/` unless named absolute.
`root` is the instance root from detection. Selected entities are
`{ name, path?, tags?, execution?, properties? }` as the decoded model
returned them. Plan requests share `{ root, options?, pluginDirectory?,
workspaceStateDirectory?, modelInputs? }`; `options` are the stored values by option ID,
and the directories are absolute host paths used only as substitution text.

| Command | Request | Result |
| --- | --- | --- |
| `build.detect` | `{ workspaceRoot, plugins: [{ manifest }], options?: { <buildSystemID>: { <optionID>: value } }, instanceOptions?: { <buildSystemID>: { <root>: { <optionID>: value } } }, instanceDefaults?: { <buildSystemID>: { <optionID>: value } }, emptySelections?: { <buildSystemID>: { <root>: [optionID] } } }` | `detection`: `{ instances, rejected: [{ index, error }], shadowed: [{ pluginID, buildSystemID, by }] }`; each instance is `{ id, pluginID, buildSystemID, displayName, root, markers, modelSource, optionFingerprint, options, droppedOptions }` plus `model` or `modelError` for `static` and `hostIntegration` sources; a `provider` source has neither. `options` contains accepted stored values after Core scope/root merging, including explicit empty selections; `droppedOptions` names rejected stored values without rewriting the source document. |
| `build.projectOptions` | `{ document }`, host-read persisted v1 Build options, without a manifest | `document`: validated storage with version 1 and systems; options, instance defaults, root values, explicit empty selections and saved custom choices are retained. Missing system fields normalize to empty maps; malformed, unsupported or oversized documents reject with `plugin.build.invalidOptionsDocument`. This pure operation never reads or writes a file and does not replace declared option resolution. |
| `build.invocationPlan` | `{ root, platform: "macos" \| "linux" \| "windows" }` | `invocation`: `{ buildSystemID, root, executables, environmentInputs, runtimeDependencies, version, minimumVersion }` with project-file paths joined to `root`; every runtime dependency with a known probe, host-managed ones included, carries `version: { arguments }` |
| `build.checkToolVersion` | `{ runtime?, output }` | `version`: `{ satisfied, version? }`; `runtime` checks that runtime dependency instead of the tool |
| `build.resolveModelInputs` | `{revision, sources: [{manifest, instances: [{buildSystemID, root, state, model?, options?}]}]}` from installed enabled current-workspace sources | `modelInputs`: version 1 public snapshot with exact optional producer slots, state, normalized projects/targets/content roots, configuration fingerprint and explicitly shared options; no tasks/run/settings/private functions; see the [plugin contract](https://github.com/1lck/Lithe-IDEA/blob/preview/shared/contracts/plugins/v1/README.md#optional-read-only-model-inputs-buildmodelinputs-1) |
| `build.resolveOptions` | `{ options, modelValues? }` | `options`: `{ options: [{ id, displayName, kind, scope?, value, source, choices, allowCustom }], dropped, fingerprint }` |
| `build.configurationPlan` | plan fields and optional host-selected `tool` | `plan.provider` for `lithe/build/configuration` (v7); no mutation, project or output-file parameters |
| `build.decodeConfiguration` | `{ result }` | `configuration`: bounded `litheBuildConfiguration` v1 native sources/fields; see the plugin contract |
| `build.configurationEditPlan` | `{ root, options?, workspaceStateDirectory, outputFile, snapshot, edits: { sourceID, revision, values }, tool? }` | Provider request `lithe/build/editConfiguration`; existing private staging only, no document bytes |
| `build.decodeConfigurationEdit` | `{ snapshot, edits, result }` | `edit: { sourceID, revision, changed }`; validates bounded receipt and exact draft/source identity; native adapter verifies staged hash and publishes atomically |
| `build.modelPlan`, `build.dependencyPlan` | plan fields plus `project?` (dependencies), `outputFile?`, and for provider sources `refresh?` (boolean) and `tool?: { executable }` (absolute path) | `plan`: `{ buildSystemID, root, arguments, environment, workingDirectory, execution, optionFingerprint, output, decoder, executesProjectCode, mayUseNetwork }`; for a `provider` source `{ buildSystemID, root, provider: { method, params }, decoder, executesProjectCode, mayUseNetwork, optionFingerprint }`, where `method` is `lithe/build/model` or `lithe/build/dependencies` and `params` is `{ buildSystemID, root, options, optionArguments, environment, project?, refresh?, tool? }`; `refresh` appears only when `true` and `tool` only when the host sent it |
| `build.taskPlan` | plan fields plus `task`, `project?`, `target?`, `modelTask?`, `userArguments?` | command `plan` with `arguments`, `environment`, `workingDirectory`, `execution`, and `optionFingerprint`; a provider task instead returns `provider: {method: "lithe/build/execute", params}` with effective options, selected task/entities, user arguments and effect metadata |
| `build.testPlan` | plan fields plus `project?`, `target?`, `suite?`, `case?`, `userArguments?`, `projects?` (the model's project directories) | command plan or `provider: {method: "lithe/build/test", params}` (buildProviders 3), plus `results`: `null`, `{ decoder, reports }` with workspace-relative globs (for the selected project, or for the root and every listed project when none is selected), or command-only `{ decoder: "hostIntegration" }`. Command filters that templates cannot place, such as a case without its suite when the tool only addresses `Suite#case`, are `plugin.build.invalidSelection`; Provider filters remain separate typed values and must be declared supported |
| `build.testDiscoveryPlan` | common plan fields plus `refresh?`, `tool?`; no project/output file | `plan.provider` for `lithe/build/discoverTests`, only with `test.discovery: true` (Provider v3), using the same effective options and effect metadata |
| `build.decodeTestDiscovery` | common plan fields plus canonical `result` | `discovery.tests` with validated `{id, suite, case, project?, target?}` selectors; bounded at 10,000 items/32 MiB, deterministic and exactly runnable; malformed replies reject in full |
| `build.prepareRunPlan` | common plan fields, `run`, required `project`/`target`, `userArguments?`, `launchOptions?`, `workspaceRoot?` (required for an explicit launch cwd); no output file | `plan.provider` for `lithe/build/prepareRun` (Provider v4), selected declaration/tags/paths/options validated; typed launch options and service/task execution require v10 |
| `build.decodeRunPreparation` | `workspaceRoot`, instance `root`, raw `result`, same optional `launchOptions` | `launch` with portable `{executable:{kind,value},arguments,workingDirectory,environment}`; bounded strings and workspace directory containment, `plugin.build.invalidOutput` on invalid result |
| `build.prepareDebugPlan` | same selected fields as `build.prepareRunPlan`; run declares same-plugin `debug.adapter` | `plan.provider` for `lithe/build/prepareDebug` (v5); no cross-package reference |
| `build.decodeDebugPreparation` | `workspaceRoot`, instance `root`, selected `run`, raw `result` | `preparation` with declaration-owned `adapter`, normalized `root`, `program`, `arguments`, `workingDirectory`, `environment`; program is an existing regular file contained in the instance after canonicalization |
| `build.decodeModel` | `{ workspaceRoot, root, output?, outputFile?, result?, options? }`; `result` is the provider's JSON answer | `model`: `{ projects, targets, tasks, contentRoots, optionValues, run }`; `run` entries carry `buildSystem: { id, root, projectID, targetID?, optionFingerprint }` |
| `build.decodeTestResults` | `{ workspaceRoot, root, project?, projects?, output, notBeforeMillis?, suite? }`; without `project` the reports of the root and every listed model project are read | `results`: `{ tests: [{ suite, case, status, message?, durationMillis?, path?, line?, invocations }], summary: { total, passed, failed, errors, skipped }, success }`; repeated invocations of one case merge into the most severe status |
| `build.decodeDiagnostics` | `{ workspaceRoot, root, output }` | `diagnostics`: `[{ path, line, column?, severity, message }]`, deduplicated, inside the workspace only |
| `build.decodeDependencies` | `{ workspaceRoot, root, project?, output?, outputFile?, result? }` | `dependencies`: `{ project, dependencies: [{ name, group?, version?, scope?, properties?, children }], truncated }` |
| `build.syncFingerprint` | `{ workspaceRoot, root, projects, options? }` | `sync`: `{ fingerprint, watch }` |
| `build.languageImport` | `{ workspaceRoot, root, options?, executablePath? }` | `languageImport`: `null` without a `languageImport` declaration; `{ kind: "maven", mavenContext: { version, reactorPath, profiles, settingsPath?, localRepositoryPath?, mavenExecutablePath? } }` for `lsp.startServer.mavenContext` and `lsp.updateMavenConfiguration`; or `{ kind: "gradle", javaGradle: { wrapperPresent, offline, userHome? } }` for `lsp.startServer.javaGradle`, where `wrapperPresent` reports `gradle/wrapper/gradle-wrapper.properties` under `root` |

`executableResolution: 2` adds `{ kind: "toolchain", toolchainID, root }` invocation
candidates. Hosts resolve them through the same canonical project/subproject
selection used by Run, preserving terminal failure and project-code identity.
The optional plan hint `tool.environment` is a bounded string map (64 entries,
valid environment names, 32768 bytes per value, no NUL). It merges into Provider
`environment` before option contributions, for models, dependencies and native
configuration; task/test hosts apply the same selected environment. Only selected
lookup/runtime inputs cross this boundary, never the full process environment.


`outputFile` is an absolute host-allocated path the host creates fresh for
each run and removes afterwards; a command whose declaration writes to a
file refuses a plan without it. Unlike the `plugins.declarative.*` commands,
`build.detect`, `build.decodeModel`, `build.decodeTestResults`,
`build.decodeDependencies`, and `build.syncFingerprint` read bounded files
inside `workspaceRoot` (and the given `outputFile`); none of the commands
writes anything or starts a process. `shared/contracts/plugins/v1/fixtures/build-systems/build-plans.json`
holds the golden plans and decoded outputs.

### VCS providers

The `vcs.*` commands implement API level 3 `vcsProviders` of
[`plugins/v1`](plugins/v1/README.md) and the
[VCS provider contract](vcs-provider-v1.md). Results use the
`plugins.declarative.*` envelope; a malformed payload, a relative
`workspaceRoot`, or an unknown operation is an `invalid_request` failure.

| Command | Request | Result |
| --- | --- | --- |
| `vcs.detectRoots` | `{ workspaceRoot, plugins: [{ manifest }], mappings?: [{ id, vcs }] }` | `detection`: `{ providers, roots: [{ id, vcs, path, mapped }], ambiguous: [{ id, vcs }], unusedMappings, truncated, rejected: [{ index, error }], conflicts: [{ pluginID, vcs, by }] }` |
| `vcs.ownerOf` | `{ roots: [id], ambiguous?: [id], paths: [path] }` | `owners`: `[{ path, root }]` in request order; `root` is `null` outside every root or inside an unmapped ambiguous directory |
| `vcs.decodeReply` | `{ operation, capabilities, request?, reply }` | `result`: the normalized reply, or `plugin.vcs.invalidOutput` |

`vcs.detectRoots` reads directory entries below `workspaceRoot` (at most eight
levels and 20,000 directories) and the marker names in its ancestors; it never
reads file contents, writes anything, or starts a process. The other two
commands touch no file. `shared/fixtures/vcs/model-v1.json` holds the
detection cases, decoded snapshots, and reply validation cases.
### Project generators

The `project.*` commands back the New Project window. Payloads, results, and
problem codes are specified in the plugin contract's
[Project generators](plugins/v1/README.md#project-generators) section, and
`shared/contracts/plugins/v1/fixtures/project-generators/project-plans.json` holds the golden
answers. Results use the `plugins.declarative.*` envelope: `catalog`, `form`,
`plan`, `name`, and `extracted`. Commands that take a manifest revalidate it
and answer `plugin.project.unavailable` for an undeclared generator.

A `projectGenerators` 2 generator picks tool installations with `tool` fields.
The host lists the installations of each field's tool and sends them as the
form's `tools`; Core chooses among them, checks `minimumVersion`, expands
`${field.<id>.executable}`, and returns `toolPins` in the plan. Core lists no
installations itself, so the commands touch neither the file system nor a
process for tools.

`project.generationPlan` reads template files below `packagePath` (bounded,
no symbolic links). `project.extractArchive` is the only command that writes:
it extracts into an existing staging directory the host created and never
replaces a file. Neither starts a process or downloads anything; the host
runs command steps, downloads archives, and moves the finished project into
place.

### Remote connections

`remote.probe` checks a saved SSH connection before a remote workspace is
opened. The request is `{ connection: { host, port?, user?, authentication?,
identityFile?, connectTimeoutSeconds?, keepAliveSeconds? } }`; unknown fields,
including any password, are rejected. `authentication` is `auto` (default),
`agent`, `privateKey` (requires `identityFile`), or `password`. `host` is a
name, address, or SSH configuration alias without a user.

Core runs the system `ssh` with the probe of
[`remote-workspace-protocol-v1`](remote-workspace-protocol-v1.md)'s bootstrap
and relays every OpenSSH question through the same AskPass transport as Git.
Each question is an `authentication` event with `requestId`, `prompt`,
`secret`, and `attempt` on the request's event channel; the host answers it
once with `remote.authRespond` (`{ requestId, answer: string | null }`,
returning `{ accepted }`, with the bounds of `git.authRespond`). Null cancels
the prompt. Core never stores or emits an answer.

The result is `{ status, host, diagnostics }`:

| `status` | Meaning |
| --- | --- |
| `connected` | The shell ran and a server build exists; `host` is set |
| `unsupportedPlatform` | The shell ran, but no server build exists; `host` is set |
| `authenticationFailed` | Every offered credential was rejected |
| `hostKeyRejected` | The host key was declined or has changed |
| `unreachable` | The name did not resolve or the host could not be reached |
| `failed` | Another failure; see `diagnostics` |

`host` is `{ system, machine, homeDirectory, serverTarget }` from `uname -s`,
`uname -m` and `$HOME`; `serverTarget` is the server's Rust target or `null`.
`diagnostics` is the redacted end of OpenSSH's standard error (at most
4 KiB). A malformed connection is `invalid_request`, a missing `ssh` is
`runtime_missing`, and cancellation or the five-minute bound are `cancelled`
and `timed_out`.

`host.details` carries display facts read by the same shell, each nullable:
`hostName`, `operatingSystem`, `kernel`, `cpuCount`, `memoryBytes`,
`diskTotalBytes` and `diskAvailableBytes` (the file system holding `$HOME`),
and `uptimeSeconds`.

#### Remote connections that stay open

`remote.connect` takes `{ connection, servers: [{ target, path }],
serverVersion, installRoot? }`. `servers` are the read-only server builds the
host ships, by Rust target; `installRoot` defaults to `$HOME/.lithe-server`.
One OpenSSH process probes the host, keeps an installed server whose
`--identity` reports the same SHA-256 or uploads the matching build through
the same stream, and starts it, so the user authenticates once. Prompts are
relayed as for `remote.probe`. The result is `{ status, session, host,
diagnostics }`; `session` is `{ id, uploaded, hostName, userName,
homeDirectory }` and is set only for `connected`. A host without a matching
build is `unsupportedPlatform` and nothing is uploaded.

Core keeps an open connection until `remote.disconnect` (`{ sessionId }`,
returning `{ closed }`) or until the host process exits; ending it terminates
the OpenSSH process tree. `remote.closeAll` (no payload, returning
`{ closed }` with the number of connections) ends all of them; the host calls
it while quitting because exiting without it can leave the OpenSSH tree and
the remote server running. Requests over it take `sessionId`:

| Command | Request | Result |
| --- | --- | --- |
| `remote.readDir` | `{ sessionId, path }` | the remote protocol's `fs.readDir` result |
| `remote.readFile` | `{ sessionId, path }` | `{ data (base64), size, modifiedMs }`; files over 16 MiB are `not_supported` |
| `remote.writeFile` | `{ sessionId, path, data, expected? }` | `{ status: "saved", size, modifiedMs }` or `{ status: "conflict" }` |
| `remote.hostRequest` | `{ sessionId, method, params }` | the finite host method's result, including JSON `null` |
| `remote.hostInfo` | `{ sessionId }` | the original connection's handshake `host`, including OS, architecture, home and features |
| `remote.uploadFile` | `{ sessionId, sourcePath, path, sha256, mode }` | verified `{ size, sha256 }` |
| `remote.runWatch` | `{ sessionId, params: { root, excludeNames? } }` | waits until root removal or cancellation; relays `watch.started`, `watch.changed`, `watch.error` |
| `remote.runProcess` | `{ sessionId, params: { argv, cwd?, environment?, env?, pipeStdin? } }` | leader exit; relays `process.started`, `process.output`, `process.exit` |
| `remote.runTerminal` | `{ sessionId, params: { argv?, cwd?, env?, columns, rows } }` | leader exit; relays `terminal.started`, `terminal.output`, `terminal.exit` |
| `remote.captureProcess` | `{ sessionId, params, timeoutMilliseconds, maxOutputBytes }` | base64 `stdout`, `stderr`, nullable `exitCode` and `signal` |

`remote.writeFile` replaces the file atomically on the host. With
`expected` (`{ size, modifiedMs }` from the read) a changed file is a
`conflict`; without it the file must not exist yet. A missing path is
`workspace_not_found`, a denied one `permission_denied`. A broken connection
fails with `connection_closed` and is forgotten, so the host reconnects; an
unknown or closed `sessionId` is also `connection_closed`.

`remote.hostRequest` accepts finite filesystem, environment and port queries,
plus controls of existing processes and terminals. Creating a watch, process,
terminal, walk or tunnel through that command is `invalid_request`; creation
requires an owner that subscribes before sending the start request. Streamed
Core events use `{ type: "remote", event, params }`. Resource IDs are allocated
by Core and replace any caller-supplied ID. Startup output is bounded to 8 MiB.
Cancellation, invalid event data and disconnect release the subscription and
stop the host resource with a two-second cleanup deadline.
That deadline bounds the client's wait, not ownership: when creation has not
published yet, the host records teardown against the pending resource ID and
the creating worker cleans it after publication. A rejected or timed-out close
worker cannot turn an already accepted cancellation into an orphaned resource.

Watch startup emits `watch.started` before buffered changes. The caller rescans
on startup, `overflow`, or watch error; `ROOT_REMOVED` ends the call. Watch paths
remain absolute host paths until the native adapter maps the owning workspace
back to placeholder URLs. A limit error preserves the partially working watch
and requests a rescan. Process capture requires a 1–30,000 ms deadline and
1–8 MiB output budget, rejects open stdin, and owns cleanup on overflow/timeout.

`remote.uploadFile` reads a native absolute regular file and streams it to the
specified host using the optional `upload` feature. It verifies source size,
chunk acknowledgements and the commit receipt; failure attempts an uncancelled
abort with a two-second deadline. Each host call has a 30-second deadline, while
the host imposes the five-minute staging lifetime. This command does not approve
plugin code: the platform package adapter validates trust, version, manifest and
target architecture before invoking it. Target publication never overwrites.
Successful upload ownership transfers to the caller, which removes its run
snapshot after the process has ended. The native source and installation remain
read-only. See the staged upload limits in `remote-workspace-protocol-v1.md`.

Plugin deployment requires both `upload` and `runDirectories` host features.
Through `remote.hostRequest`, `fs.createRunDirectory` accepts a caller-generated
`directoryId` and returns a fresh host `path`; `fs.releaseRunDirectory` accepts
the same identity and is idempotent. Allocation may finish after Core cancellation,
but the host owns it and orders a subsequent release after pending creation.
The platform retains the original connection and the identity before allocation,
releases after process destruction, and never falls back to unchecked `fs.remove`.
Nonpersistent disconnect or session termination also collects full snapshots;
persistent disconnect retains them until explicit release, shutdown or idle expiry.
Forced server termination recovery remains unsupported, rather than risking
deletion of inputs used by surviving processes.

### Git patch discovery and rebase amendment preconditions

`git.patchExport` accepts optional `metadataOnly` (default false). In metadata
mode it returns candidate file counts and rename identities with empty `patch`
and zero `byteLength`, independently of patch text encoding and exchange size.
See [Patch exchange](git-patch-exchange.md) and its metadata fixture.

For Shelf capture, `git.patchExport` also accepts `includeUntracked: true` only
with `source: "unstaged"`. It snapshots the real index and exports the selected
working files, including untracked additions, relative to that index. The real
index remains unchanged. The default false retains tracked-only unstaged export;
`workingTree` remains HEAD-based. See the same contract and its
`unstagedWithUntrackedRequest` fixture.

`git.rebaseControl` requires `expectedHead` when `amendMessage` is present.
Missing or stale HEAD rejects the amendment before writing; plain Continue,
Skip and Abort do not require this field. Both products must send the HEAD
reviewed by the amendment editor. See [Rebase sessions](git-rebase-session.md).

Completion requests accept optional `completionContext` with LSP `triggerKind`
(`1` invoked, `2` trigger character, `3` incomplete-list refresh) and
`triggerCharacter` (required and one character for kind `2`). Missing context
means invoked. Core validates and maps this into LSP `params.context`.
Completion results carry `{ items, isIncomplete }`; array and null server results
are complete. The flag is list-scoped and survives empty lists and host provider
merging. Both Monaco adapters set `CompletionList.incomplete` and forward Monaco's
trigger context, so continued typing can request additional candidates instead of
filtering a partial cache. Existing document-version, cancellation and attachment
checks still reject obsolete results. The fixture is
`shared/fixtures/lsp/completion-refresh-v1.json`.

Completion items returned by the LSP client and runtime preserve `insertTextFormat`
(`1` for plain text, `2` for snippets; absent values default to `1`). Hosts retain
this field through completion resolution. Monaco applies snippet text with its
snippet insertion rule so placeholders participate in selection and undo rather

than being inserted as literal source text. The initialize handshake advertises
`completion.completionItem.labelDetailsSupport` and resolve support for
`labelDetails` so language servers attach typed class/namespace labels on
incomplete items. Core forwards `labelDetails` and omits null `data` so
`completionItem/resolve` can still produce import `use`/`import` edits.

The shared JDT adapter sends `java.completion.guessMethodArguments: "off"`
through initialization, configuration notifications and section queries on both
platforms. JDT LS therefore leaves constructor and method argument lists empty
while preserving the snippet cursor inside the parentheses. Other completion
settings declared in the provider's initialization options are retained for the
session in initialize, didChangeConfiguration, and parent/leaf section pulls
(including favoriteStaticMembers and filteredTypes). This does not disable snippet
support or strip parameter text from arbitrary completion items; the shared
configuration fixture is `shared/fixtures/lsp/java-completion-v1.json`.

### Java preparation snapshot

Java `projectPreparation` runtime events carry a `result` object with `phase`
(`starting`, `importing`, `configuring`, `building`, `ready`, `stopped`), `status`
(`idle`, `loading`, `ready`, `failed`) and boolean `blocksRun`.
`lsp.pollEvents` and `lsp.waitEvents` also return `projectPreparation` (the current
snapshot or null) alongside `events`, so restored consumers need not replay the
queue. Event session identity and sequence retain their existing semantics.

The snapshot reuses the existing service-ready signal, profile-task results and
configuration/build coordinator. Generic indexing never blocks Run. Profile
failure is visible but does not globally block unrelated targets; callers still
build the selected target before launching. A successful preparation does not
promise compilation success. Shared examples live in
`shared/fixtures/lsp/project-preparation-v1.json`.

### Workspace commit preconditions

`git.commitState` accepts `{ root }` and returns `{ head, branch, indexEntries,
gitlinks, stagedPaths, conflictedPaths }`. `head` is null only for an unborn branch; `branch` is
null for detached HEAD. `indexEntries` is Git's opaque NUL-delimited staged index
listing, including blob IDs and conflict stages; clients compare it without
parsing it. `gitlinks` lists stage-0 mode-160000 entries as `{ path, revision }`.
`stagedPaths` disables rename detection so both deleted and added paths are listed;
local selection guards must not miss the old side of a rename.
Read failures are errors, never an empty relationship list.
The requested root must still be Git's exact working-tree root. Removing a
nested repository's metadata must fail instead of falling back to its parent;
gitlink updates also verify the child boundary before reading its HEAD.

`git.write` / `commit` optionally accepts `expectedCommitState` and
`gitlinkUpdates: [{ path, revision }]`. Gitlink updates cannot accompany other
operations or path-selected commits. Push also accepts `expectedCommitState`
to reject a changed repository under its writer lease. Workspace pushes set
`checkSubmodules: true`, invoking Git's `--recurse-submodules=check` so missing child
commits block a parent push even when only the parent pointer was selected. Under the existing repository writer lease,
Core verifies HEAD/index, validates all child HEAD revisions, then updates only
those parent index entries in a single `update-index --index-info` transaction
before the regular commit. Any changed precondition returns `invalid_request`
through the existing operation error envelope. Unrelated unstaged parent files
are not added. A failing hook may leave the pointer staged: clients must retain
partial progress and re-read state before retrying. External Git processes do
not participate in Lithe's lease; cross-repository commits are not atomic.

`git.status.changes[]` additionally carries optional `submodule` with
`commitChanged`, `trackedChanges`, and `untrackedChanges`, normalized from Git
porcelain v2. The existing two-character `status` remains compatible. The optional request flag
`includeIndexOnlyChanges` retains staged additions deleted only from the working
tree (`AD`); both products enable it so every staged file remains visible. Omission
preserves the legacy final-worktree projection. Child dirt
alone is informational in the parent; only a changed commit pointer (or an
already-staged change) is eligible for the parent's staging checkbox.

`git.status` accepts optional `repositoryRoots` (native bindings of discovered
repositories). Untracked paths owned by a nested root are excluded from the
parent list. Each change returns `canToggleStaging`; platforms render that
eligibility instead of reinterpreting submodule dirt.

`git.status` accepts optional `summarizeUntrackedDirectories`. When true, Core
reads Git's collapsed untracked view and reports a wholly untracked directory
holding more than 100 non-ignored files as one change whose `path` ends with `/`
and which carries `untrackedFileCount`. Smaller directories keep one change per
file. A directory containing a nested repository is never summarized; it is
split until each summary is free of nested repositories, so staging (`stage`),
discarding (`discard`/`discardAll`) or diffing (`git.diff` with `untracked`) the
summary path acts on exactly the counted files. Omission preserves the
file-level projection. `git.untrackedDirectory` accepts `{ root, directory,
repositoryRoots? }`, where `directory` is a summary path ending with `/`, and
returns `{ changes }`: the directory's immediate untracked files plus each
subdirectory as a summary, using the same change shape and nested-root
exclusion as `git.status`.

`git.workspaceCommitPrepare` owns the complete multi-repository policy. It accepts
`repositories: [{ id, root }]`, `message`, `amend`, `push`,
`includeParentReferences`, optional `previous` session for retry, and optional
`reviewed` plan for confirmation. `id` is a workspace-relative path with `/`
separators (`..` is allowed for enclosing repositories). Windows manually selected
roots on another volume use a stable `external/<encoded-volume>/<path>` virtual
workspace ID. `root` is the native
execution binding, never a portable identity. The response is
`{ session, reviewChanged, requiresConfirmation }`. Core reads all repositories,
finds real gitlink relationships, includes clean parents when requested, orders
children first, and adds push-only child work where needed. Cycles fail closed.
A changed reviewed plan must be displayed and confirmed again before any step.

When `push` is set, Core also checks whether any repository's branch tracks a
differently named remote branch (a `divergent` push destination, see
`git.pushPreview`). Those repositories are returned as `pushTargetQuestions: [{
repositoryId, localBranch, remote, upstream, upstreamBranch }]` (omitted when
empty) and the session must not be stepped: when a step reaches such a repository,
Core refuses it before writing that repository's commit instead of committing
something it cannot push. Clients answer by preparing again
with `pushTargets: { <repository-id>: { choice, remote, remoteBranch } }`, where
`choice` is `publish` (`remoteBranch` is `localBranch`) or `upstream`
(`remoteBranch` is `upstreamBranch`). The answer names the remote and branch that
were shown; if the tracking configuration moves before the push, the answer no
longer matches and Core asks again. Each repository is answered and checked
separately, answers are stored in `plan.pushTargets`, and a retry restores and
re-validates them from `previous` without the client forwarding them. Routine
pushes (`tracking` or `publish` destinations) never produce a question.

`git.changelists` is a pure reducer: the host owns persistence and supplies
`state` (`lists`, `activeId`, and `assignments` grouped by repository root),
`files` (root, path, optional original path, and `isCopy`), optional repository
bindings, and an optional action (`create`, `rename`, `remove`, `activate`,
`move`, or `rememberRenames`). The response contains the validated state, one
membership per input file in order, and a commit `scope`. Deletion leaves an
explicit Default assignment so a file under an assigned directory returns to
Default. A rename inherits its source's membership, including directory or
implicit Default membership; copies never inherit or modify their source.
Ambiguous overlapping renames with different memberships fail closed. Inputs
and assignment counts are bounded. Hosts must reject stale asynchronous results
and protect persistence against concurrent windows. The shared fixture is
`shared/fixtures/git/changelists-reducer-v1.json`.

An optional `pathScope: { include, paths, membership? }` restricts local
changelist commits. Legacy scopes use literal `paths` grouped by repository ID:
`include: true` allows only listed paths, while `false` excludes listed paths.
Core-generated scopes additionally include `membership: { activeId,
assignments }`, where assignments are grouped by repository ID and may include
explicit file or trailing-slash directory rules. Exact paths override the
nearest assigned directory; missing paths belong to Default. Core uses these
rules against the real staged paths and automatic parent-reference updates,
including paths staged after the UI snapshot. They are literal identities, not
Git pathspecs or a second staging index. Omitted `membership` retains legacy
exact-path behavior. Scope changes invalidate a reviewed plan; retries inherit
the original scope and may not replace it. Continuations retain the entire
scope and validate it before writes, alongside exact HEAD/index checks.
Omitted scopes preserve existing clients' behavior. Legacy examples:
`shared/fixtures/git/local-changelist-scope-v1.json`.

`git.workspaceCommitStep` accepts `{ session }` and returns the next session,
executing at most one commit or push. Session fields are `plan`, last observed
`states`, per-ID `results`, `blocked`, `cursor`, `commandFailed`, `finished`,
`succeeded`, and `canRetry`. They are Core-owned continuations: clients return
them unchanged and must not independently choose roots, reorder work, or infer
completion. `plan` includes bindings, options, `orderedIds`, propagation and
dependency relations, reviewed states, `committedIds`, and `pendingPushIds`.
Each result separates `committed`, `pushed`, stable `status`, and Git `detail`.
Status keys are `pending`, `notIncluded`, `waitingForSubmodule`, `reviewRequired`,
`committed`, `committedPushPending`, `committedAndPushed`, `commitFailed`,
`pushFailed`, `headAdvanced`, and `outcomeUnknown`.

Each step uses a fresh host operation ID and the existing Git writer lease,
process runner, authentication and event stream. Cancellation blocks dependent
parents while independent roots may continue under subsequent operation IDs.
A read-only cleanup deadline of five seconds reconciles a commit whose HEAD may
have advanced before cancellation. This command preserves the reconciled session
instead of replacing it with a generic late-cancellation envelope. Transport
errors before a continuation is returned must never be treated as success.
Retry re-inspects current state, preserves completed commits, and re-pushes
externally advanced completed branches before updating dependent parents.

Sessions own no background resources and are retained only for the current
workspace lifetime. Native clients discard old responses after workspace changes,
show confirmation/progress, and drive steps until `finished`. macOS uses this
shared workflow, as does Windows through its workspace-scoped continuation adapter
and real staging checkboxes. The native products must not duplicate planning or retry policy.
See `shared/fixtures/git/workspace-commit-v1.json` for primitive payloads and
`shared/fixtures/git/workspace-commit-workflow-v1.json` for the complete planning
and continuation fixture consumed by Rust, Swift, TypeScript and Tauri adapter tests.

### Decoded document text classification

`document.classifyText` accepts `{ text }` and returns `{ isPlainText }`.
The input is already decoded Unicode, independent of the filename, language ID,
or tokenizer availability. Core uses the same control-character policy as
`file.read`: reject U+0000–U+0008, U+000E–U+001F, and U+007F; allow other scalars,
including tabs, line breaks, form feed, Chinese, and emoji. The entire decoded
text is inspected, not an arbitrary byte prefix. A missing or non-string `text`
returns `invalid_request`. Hosts retain responsibility for size limits, I/O,
encoding selection, and decode failures; a permission or decode error must not
be relabeled as binary content.

The synchronous C ABI `lithe_core_is_plain_text(const uint8_t *, size_t)` borrows
UTF-8 bytes for the call, including embedded NUL, without allocating a JSON
copy. It returns `1` for plain text, `0` for binary control characters, and `-1`
for invalid UTF-8 or an invalid pointer/length combination. A zero-length input
is plain text and may use a null pointer. Nonzero input must point to at least
`length` readable bytes and `length` must not exceed `isize::MAX`. The Swift
bridge exposes the same lifetime and result contract. Fixtures live in
`shared/fixtures/editor/text-content-v1.json` and exercise both entry points.

### Process lifecycle decisions

`processLifecycle.resolve` accepts `{ context, settings, records }` and returns
`{ gracefulStopMilliseconds, decisions }` with exactly one decision per record,
in request order. `context` is `quit`, `closeTerminalTab`, `agentDisconnect`,
`crashRecovery`, `startupSweep`, `finalSweep`, or `closeWorkspace` (a project or
window closes while Lithe keeps running). Each record carries a host-chosen `id`, a
`kind` (`run`, `terminal`, `agentTask`, `languageServer`, `debugAdapter`,
`pluginTool`, `sidecar`, `daemon`, `container`, `oneShot`), the `ownership` proof
(`launched`, `scopeToken`, `instanceLabel`, `unproven`), and optionally
`declaredPolicy`, `recognizerId`, `recognizedPolicy`, `detached`, `idle`, and
`retained`, and `terminationApproved` (default `false`). Omitted settings take the documented defaults: busy terminals and
Agent tasks are confirmed one by one, closing a busy terminal tab asks,
daemons and containers are asked about, startup leftovers are asked about, Run
sessions are listed before they are stopped (`runServicesOnExit: ask`), and
ordinary processes get five seconds to stop (clamped to 1–60).

A `run` record with `launched` ownership is a Run session the host tracks
itself. During `quit` and `closeWorkspace` its action is `confirmStop` with
`runServicesOnExit: ask` and `terminate` with `runServicesOnExit: terminate`
(reason `runServicesSetting`). Hosts show every `confirmStop` record in one
confirmation whose only choices are stopping all of them or cancelling the
close; a Run session cannot be kept, because its process tree and output pipes
belong to Lithe. Other `run` records, such as inventory items found only by
their scope token, keep the default `terminate`. During `closeWorkspace`,
records that would need any other question (`confirmEach`, `askOnExit`)
`defer` with reason `decidedOnQuit`.

`finalSweep` runs after confirmation and without dialogs. Owned Agent tasks need
`terminationApproved: true` to terminate; otherwise their action is `defer` and
the host must preserve a recoverable record for individual startup confirmation.
Owned records with policy `askOnExit` (daemons, containers, detached processes)
without approval follow a remembered choice or `backgroundResources: keep` /
`terminate`; with the default `ask` they `defer` with reason
`backgroundResourceRequiresStartupConfirmation`, so a successor spawned after the
quit dialog is never ended unseen. Hosts approve the services the user chose to
end once quitting can no longer be cancelled. Other owned records terminate.
Unproven ownership and explicit retention still
win. Approval applies to exact PID/start-time identities; hosts may expand it
only through ancestry proved in the same snapshot.

A decision reports the pre-setting `policy` (`terminate`, `confirmEach`,
`askOnExit`, `external`), the `action` the host performs (`terminate`,
`confirm`, `ask`, `retain`, `defer`, `ignore`, `confirmStop`), and a stable
`reason` for logs.
Unproven ownership is always `ignore`; a record the user kept is `retain`.
Agent tasks are never ended during `crashRecovery` and are always confirmed
during `startupSweep`, whatever the settings say. Hosts own discovery,
signalling, and dialogs. Fixtures live in
`shared/fixtures/process-lifecycle/exit-plan-v1.json`.

`processLifecycle.inventory` accepts `{ scope, mode, applicationSessionId,
excludedProcessIds, retained, agentScopes?, approvedTermination, agentConnections,
processes, context?, settings }`. `agentScopes` restricts rows to named Agent
connections: omitted means unrestricted and an empty list means no rows. Hosts
must specify it when closing one connection. `approvedTermination` defaults to
an empty identity list; an item is approved only when every member matches.
`applicationSessionId` is the original application's session, persisted before
supervisor detachment and reused during recovery. Zero means unknown: Core does
not infer detached background services and asks about ordinary owned leftovers
at startup by default. Hosts must omit an unattended recovery plan for legacy
records with no original session.
`processes` is the host's snapshot of processes that inherited
`LITHE_PROCESS_SCOPE=<scope>`: `processId`, `startTime` (microseconds since the
epoch), `parentProcessId`, `sessionId`, `hasControllingTerminal`, `name`,
`executablePath`, `arguments`, `processScope`, `agentScope` and
`workingDirectory`. Processes of another scope, excluded IDs and retained
identities (`{ processId, startTime }`) are dropped. `mode` is `live` (the
running instance, which reports each Agent connection's `scope`, `agentName`,
`workspace` and `taskBaseline`) or `leftover` (an instance that is gone).

It returns `{ items, plan? }`. Items come in this order: Agent tasks and Agent
infrastructure, background services, terminals, then everything else as
`run:other`. In live mode, an Agent process that started after its
connection's `taskBaseline` is a task. Tasks are grouped into trees by parent
chain (`agentTask:{pid}:{startTime}`). Earlier processes are
`agentInfrastructure:{scope}` (kind `sidecar`). An unknown connection, and every
Agent scope in leftover mode, normally becomes one `agentTask:{agentScope}`
item. During `startupSweep` these scopes instead split into independently
confirmed task trees with `agentTask:{pid}:{startTime}` IDs. During `finalSweep`
they split by exact identity so an unapproved late orphan cannot block approved
siblings. Known live connections keep their infrastructure and task grouping.
A background service is a positive session outside the application's session
whose members have no controlling terminal, even after its session leader exits.
Its representative is the live session leader, or the lowest-PID live root
whose parent is outside the session (falling back to its lowest-PID member).
The representative determines `service:{pid}:{startTime}` (`detached: true`).
Remaining processes are grouped by session as `terminal:{sessionId}`. With a
`context`, `plan` is the `processLifecycle.resolve` result for the items, using
scope-token ownership. Fixtures live in
`shared/fixtures/process-lifecycle/inventory-v1.json`.

`processLifecycle.settle` accepts `{ settings, decisions, answers, remember }`.
`decisions` repeat each plan decision's `id` and `action`, plus an optional
`recognizerId`. `answers` maps IDs to `terminate` or `keep`. It returns
`{ terminate, keep, settings }`:

- `terminate` and `confirmStop` records end and `retain` records are kept.
  Hosts settle a `confirmStop` record only after the user approved stopping.
- `confirm` and `ask` records follow their answer, and an unanswered one is
  kept.
- `defer` and `ignore` appear in neither list.
- With `remember`, answers to `ask` records that have a recognizer are written
  to `settings.rememberedChoices`.

Fixtures live in `shared/fixtures/process-lifecycle/settle-v1.json`.

## Local IDE capability broker

`ideHost.control` accepts `{action, arguments}` and delegates to the native
`lithe-ide-host` adapter. This local host command is not remotely exposed. See
[IDE API v1](ide-api/v1.md) for the allowlisted plugin/MCP capabilities, connection
ownership, authorization, output cursors and shutdown semantics.
Native `open` accepts a `toolExposure` selection of canonical tools and optional
argument names; a host that omits it serves the whole catalog. A selection is stored
with the connection and enforced before requests enter its queue. It can only narrow known schemas; it cannot define tool
types or permissions. Both MCP discovery and native plugin validation use it.
Native Rust hosts can attach an owner-checked, connection-lifetime callback using
`attach_ide_request_dispatcher`; this is separate from the request-scoped Git/Agent
progress callback. It forwards notification IDs only. `ideHost.control` action
`claim` atomically returns an unexpired, unclaimed request or null before any
application action. Closing the connection releases the callback. Windows delivers independent,
window-scoped Tauri events rather than an ordered Channel; a missing notification
must not block subsequent requests.

### Java service hot replacement

`debug.inspect` accepts the Java-provider extension `kind: "redefineClasses"`
with a caller-owned `operationId`. Unlike the inspection kinds, this operation
**mutates the running debuggee**; it requires a running or paused Java session,
but no selected thread. Platforms save documents and complete a successful JDT
`vscode.java.buildWorkspace` before submitting it. They must retain the original
launch target and compare its runtime paths with JDT before compiling; changed
paths require a restart instead of applying to a different output directory.

The terminal result is `{ kind: "redefineClasses", changedClasses: [...] }`,
sorted and deduplicated. Empty means no classes were replaced. Java Debug Server's
`errorMessage` inside a successful DAP response becomes `operationFailed` with
`adapterRejected`; the debug session remains usable. Malformed replacement
results also fail only the operation. Replacement does not imply continue.
The fixture is `shared/fixtures/debug/hot-code-replace-v1.json`.

Java debug launches append `-Dspring.devtools.restart.enabled=false` (also for
Core-planned direct JDT JDWP launches) so DevTools cannot restart the classloader during
HotSwap. Attach to independently launched JVMs does not change their options.
The Windows host maps `redefineClasses` to this operation and `cancelOperation`
to `debug.cancelOperation` with a `timedOut` reason for its bounded result wait.

### Commit dates and history date queries

`git.history`, `git.historyPage`, and `git.commit` return author `date` in Git's
wall-clock form and `dateUtcOffsetMinutes` (east positive). When both describe a
valid instant, `dateUnixSeconds` supplies the absolute Unix time. An unknown or
invalid offset omits the timestamp; older clients can still display the original
date. Hosts should use the timestamp for presentation and cache identity.

`git.historyQuery` accepts up to 4,096 `entries` with unique, nonempty `id`
(up to 256 UTF-8 bytes), `date` (up to 128 bytes), optional `utcOffsetMinutes`,
and optional `fallbackUnixSeconds` for legacy dates without an offset. `afterUnixSeconds` is inclusive and `beforeUnixSeconds` is exclusive; an
unresolvable date is excluded. The result's `matchingIds` preserves input order.
Clients handling larger histories must batch requests and abandon stale results.
Local calendar boundaries (including daylight-saving transitions) come from the
host's system calendar, are converted to absolute seconds, and are passed to Core;
Core does not infer an OS timezone or assume every calendar day is 24 hours. See
`shared/fixtures/git/history-date-query-v1.json`.

### Saved changes: directional patches and immutable stashes

`git.patchPreview` and `git.patchApply` accept optional `reverse` (default `false`).
The preview token binds direction, patch bytes, target, index, HEAD and working files;
changing direction requires a new preview. Preview checks use disposable index copies
and preserve the real index bytes. Applying to `indexAndWorktree` may refresh its
stat cache after reviewed-state validation. Git remains responsible for applicability;
there is no partial-reject or automatic whitespace repair mode.
See `shared/fixtures/git/patch-exchange-v1.json`.

`git.stashes` adds `oid`, the full immutable object identity, alongside the positional
`reference`. `git.diff` accepts `stashReference` to read a stash including its untracked
files. Stash write operations also accept the full object identity in `reference`;
Core resolves its current stash position under the existing writer lease and rejects
an identity that is no longer present. Legacy positional references remain accepted.
With `includeFileSections: true`, `git.diff` returns `files` in Git order for
working-tree, index, reference, commit, snapshot and stash reads. Stash reads
still require the whole-repository pathspec `["."]`. Each file provides a
validated `path`, optional `originalPath`, `status`, `isBinary`, additions and
deletions, UTF-8 `patch`, unified `lines`, aligned `rows`, and complete per-hunk
`hunks`. The flat `patch`, `rows`, and `hunks` are empty in this mode to avoid
a second full-document transfer. `omitFilePatch: true` additionally omits each
whole-file patch after validation while retaining exact per-hunk patches; hosts
that need a complete saved patch must leave it false. The `hasLossyLineEndings` flag records whether
display normalization omits CR or a missing-final-newline marker. Git's NUL
statistics and patch are captured by the same invocation; standard prefixes,
no color, and no text conversion are forced. Unsupported paths, mismatched
sections and patches exceeding 32 MiB are rejected. Regular diff reads replace
invalid UTF-8 for display and set `hasDecodingLoss`; their patches and hunks
must never be used as write material. Rename hunks additionally provide a
`contentPatch` against the destination path, so a partial stage or unstage does
not itself apply or reverse the rename. If absent, such a hunk is not writable.
Stash reads reject invalid UTF-8.
Without the flag, `git.diff` retains its flat response shape.

`git.parsePatch` accepts `{root, patch}` and returns the same per-file shape
for a complete saved UTF-8 patch. Git validates file identity in one batch,
with a reverse inspection when rename/copy identities require it. Empty patches
return no files; invalid, unsafe or oversized inputs are rejected. Shelf retains
separate staged and working-tree patches and parses each layer once. Hosts may
render the unified and split rows, but must use only byte-faithful hunks for
writes and honor the decoding-loss flag. See
`shared/fixtures/git/saved-stash-v1.json` and
`shared/fixtures/git/parsed-diff-v1.json`.

### Native plugin UI data

`plugins.nativeUI.validateData` accepts `{ ui, data }`, where `ui` is the
validated native schema-1 declaration and `data` is a provider's `{ nodes }`
reply. It returns `{ status: "ok", nodes }` or
`{ status: "rejected", error: { code: "plugin.ui.invalidData", message } }`.
Malformed envelopes remain Core `invalid_request` failures. The operation uses
the same identity, literal label, nesting and node budgets as manifest validation
and rejects data above 1 MiB. Form declarations validate bounded input/select/checkbox
controls (including search/editor/segmented/stepper), typed scalar defaults, choices,
info, button action references/width policies and onCommit references; form source replies
require empty nodes. Hosts inject this typed operation into their
presentation feature; views never call the C ABI. Windows can reuse validation
when it later adds a native renderer; Core support does not advertise ui 3 on
that platform.

### Agent skill management

`agent.skills` accepts explicit `action` values `list`, `directories`, `read`,
`create`, `import`, and `setEnabled`, with `agentId` (`codex-acp` or `claude-acp`) and optional
absolute `workspace`. These management operations never create an Agent session,
send a prompt or stop a running conversation. Only an explicit `setEnabled` action changes native visibility settings.
The shared fixture is `shared/fixtures/agent/skills-management-v1.json`.

`list` returns `skills`, `source`, `issues`, and native `directories` (`user`,
plus `repo` when a workspace is present). Each row has `name`, `description`,
absolute `path`, native `scope` (`user`, `repo`, `system`, `admin`), optional
`enabled` and optional `pluginId`. Paths are transient platform file-operation
metadata, not portable persisted identifiers. Rows are sorted by lowercased name
and path. Native Codex discovery uses the installed CLI's official `skills/list`
with the selected cwd and `forceReload: true`, reusing the bounded App Server
probe and process-tree cleanup. Unknown enablement remains null. Missing or
malformed native results fail explicitly; refresh failure retains previous rows
only within the same workspace and Agent.

Claude `source: directory` is an explicitly partial inventory of
`CLAUDE_CONFIG_DIR/skills` (default `~/.claude/skills`) and the selected workspace's
`.claude/skills`. It does not emulate inherited-directory, plugin, policy or
session discovery. Its `enabled` reports configured visibility: user rows read user settings; repo rows merge user, project shared and project-local settings. Absent overrides mean on, off means false, name-only/user-invocable-only mean true. Invalid or unreadable configuration leaves the affected state null. This is not effective managed policy or evidence of session availability. Codex `source: agent` is native discovery. Platform UI
uses Global/Project as the main categories and Agent provenance as a filter.

`setEnabled` requires an absolute discovered `source` path and boolean `enabled`; Claude also requires matching `scope`. It returns a fresh listing using the same shape as `list`. Codex validates the path with `skills/list`, calls official `skills/config/write`, then forces native readback and verifies the desired state. Its setting is global by path even for a project skill. Claude merges only the named `skillOverrides` on/off value into user `settings.json` for global skills, or project `.claude/settings.local.json` for project skills; it preserves unrelated JSON values and permissions, refuses malformed, linked or over-1-MiB files, uses a nonblocking cross-process lock and same-directory atomic replacement with a pre-publish snapshot check. Claude settings are by name, so same-named skills share a setting; project/managed settings can override user settings. Plugin skills are not managed through this operation. Existing session contents cannot be withdrawn: clients advise reconnecting, and never automatically interrupt a running conversation. No skill file is renamed or edited by toggling.

`directories` returns only the native destination map and needs no installed
CLI. `read` takes the selected absolute `source` path to a `SKILL.md`, reads at
most 128 KiB of regular UTF-8 text and returns `content`. It never interprets or
executes instructions, scripts or dynamic content in the document.

`create` requires `scope` (`user` or `repo`), portable `name` (1–64 lowercase
letters/digits separated by single hyphens), `description`, and `instructions`.
`import` requires `scope` and an absolute, user-selected `source` (`SKILL.md` or
its package directory). Writes return the resulting `path`. Codex targets
`~/.agents/skills` or `<workspace>/.agents/skills`; Claude targets its native
configuration directory or `<workspace>/.claude/skills`. Project writes require
an opened workspace. Imports preserve package contents and file permissions,
reject special files and symbolic links, and enforce 2,000 entries, 20 nested
levels, 128 KiB per SKILL.md, 8 MiB per resource file and 32 MiB total. Hidden staging is removed on failure or
cancellation; publication atomically refuses an existing target, including an
empty directory. Existing skills and import sources are never overwritten.
These are explicit user-owned documents, not downloaded/build/cache resources;
no app bundle, installation resource or shared worktree cache is writable.

The macOS settings surface offers search, refresh, file details, native open and
reveal, creation and import. It keeps native loading separate from management
and rejects stale results after project changes. Windows can use the same Core
operations; the settings UI and Windows runtime validation remain pending.


Team Build options use `shared/contracts/build-project-options-v1.schema.json`
at `.lithe/build/options.json`. `options` holds workspace-scoped values;
`instanceDefaults` applies to every detected root's instance-scoped options;
`instances` overrides those defaults by normalized root. Platform-local values
then override that root. Storage writes local differences only; passive detection
never rewrites the shared document. Explicit local reset reveals the shared value.
Malformed, unsupported, or inaccessible documents fail instead of becoming empty
options. Source documents stay read-only during resolution; the host only writes
one through guarded publication for an explicit edit or activation migration.
`build.detect.instanceDefaults` receives this same team default snapshot before
static model/run generation; hosts use the same merge in every subsequent plan.

`savedChoices` preserves unselected custom choices. Hosts display them only when
the resolved option permits custom values; they never change selection or upstream
model facts. Storage validates bounded documents and preserves invalid originals.

`build.decodeTestResults.request.result` accepts a canonical inline report only
for `test.results.decoder=provider` (buildProviders 8). Provider replies carry
`testResults` with the same execution. Core validates bounded case fields and
workspace-relative paths and aggregates by optional project/suite/case identity;
the host does not read tool-specific report directories for this decoder.

### Project JDK supplied to JDT LS

`lsp.startServer.javaRuntimes` entries contain `homePath`, `version`, and optional
`isDefault` (default `false`). Platforms use their existing project toolchain selection,
including explicit JDK homes outside discovery roots. The server process JVM remains
independent. Core registers one JDK per Java major; the first valid selected candidate
wins its major and alone receives `default: true` in `java.configuration.runtimes`,
both at initialization and in configuration responses. Empty homes and unparseable versions
are ignored during projection; platform adapters validate explicit choices before launch.
Legacy callers that omit `isDefault` retain their previous behavior.
Fixture: `shared/fixtures/lsp/java-project-runtimes-v1.json`.


### Workspace indexing policy

`workspace.configureIndexing` accepts `root`, `manualExcludedDirectories`,
`includedDirectories`, `gitIgnoreEnabled`, optional `refresh` and `paths`.
Directory identifiers are workspace-relative `/` paths; `.` names the root.
Manual ancestor exclusions take precedence over every include exception. An include
exception disables automatic Git exclusion for its subtree, while allowing a
more-specific manual exclusion. Ancestors needed to reach an exception remain
traversable. Standalone ignored files are not converted to directory exclusions.
Git checks use native `check-ignore` and protect tracked descendants with `ls-files`.
No `.gitignore`, index, or project configuration files are written by this command.

`ownerId` optionally identifies one workspace runtime lifetime. Independent runtimes
using the same canonical root hold independent leases. Hosts acquire/release leases
with workspace membership, never with tool-window or tree mounting. Omitting
`ownerId` retains the legacy revision-guarded lease. A native window host must reclaim
its leases on destruction, including installations that finish after destruction.

`workspace.refreshIndexing` requires `root`, `ownerId` and its published `revision`.
It validates the live lease, retires the scan generation and clears Git decisions and
search caches without installing settings, acquiring a lease or replacing any owner's
release token. Closed or superseded leases return `cancelled`. Its `IndexingStatus`
retains the supplied release token; directory reasons remain lazy, just as for configure.
Without a running language service it does not scan directories or prewarm content.
Live providers reuse the existing directory-only preparation and withdraw excluded
working copies and diagnostics. Hosts resynchronize still-open buffers after success.

Windows maintains one invalidation queue per native canonical root. Events advance an
epoch before fan-out to WebViews; waiting queries consume the same queue and reject
results if its epoch changes. Concurrent refresh requests share the completed root status
but retain their own envelope and lease token. Lock waits have a 30-second deadline;
refreshes consume at most three epochs, leaving newer events dirty on failure. Root
membership and watcher registrations belong to runtime lifetimes, including background
workspaces. Preferences and refresh completion use distinct events to avoid write loops.
The native host injects the window identity for Git/file watcher ownership, shares paths
and releases only the last holder; window destruction also revokes late registrations.

### Directory rules, copy names and history events

`workspace.reduceDirectoryAction` takes `{ path, action, caseInsensitive?, rules }`, where
`path` is workspace-relative (`.` is the root), `action` is `{ kind: "setRole", role }`,
`{ kind: "exclude" }` or `{ kind: "cancelExclusion" }`, and `rules` is the root's persisted
`{ marks, includedDirectories, previousRoles }`. It returns `{ changed, rules }`; hosts persist
`rules` verbatim and skip the write when `changed` is false. Excluding remembers the replaced role in
`previousRoles` and canceling a manual exclusion restores it. `workspace.relocateDirectoryRules`
takes `{ source, destination?, caseInsensitive?, rules, target? }` and returns `{ rules, target }`:
keys at or below `source` leave `rules`, reappear under `destination` (in `target` for a move across
workspace roots) and are dropped when there is no destination. Request and response pairs are pinned
by `shared/fixtures/workspace/directory-rules-v1.json`.

`workspace.planDuplicate` takes `{ name, isDirectory, existing?, caseInsensitive? }` and returns
`{ name }`; `workspace.planPaste` takes `{ items: [{ name, isDirectory }], existing?, caseInsensitive? }`
and returns `{ names }`. A file name is split at its last dot, a directory name and a leading-dot name
are not. Core never touches the file system: the host passes the names it has seen to exist, creates the
copy without replacing anything (`FileManager.copyItem`, which refuses an existing destination, on macOS;
`create_new` and `MoveFileEx` without replacement on Windows) and, when that fails because the name
appeared meanwhile, adds the name to `existing` and plans again. After 512 rounds the host reports
the stable `destination_exists` error. Cases are in `shared/fixtures/workspace/file-copy-names-v1.json`.

`history.planEvent` takes `{ event }` and returns `{ snapshots: [{ source, reason }] }`. `source` says
whose text the host records: `beforeChange` (the text an event replaces), `afterChange` (the text it
produced) or `editorBuffer` (unsaved editor text that is discarded). A save or auto-save records
`beforeChange` and `afterChange`, so a snapshot of the saved state exists immediately.
Cases are in `shared/fixtures/history/event-plan-v1.json`.

The directory-action sequence contract is `shared/fixtures/workspace/directory-actions-v1.json`.
Role changes retain include exceptions, explicit exclusion deletes only its own exception,
and canceling Git exclusion preserves the current role. Only canceling a manual exclusion
restores the remembered role. Manual ancestor exclusion cannot be overridden.

`revision` is the requesting owner's release token. Explicit policy replacement or legacy `configureIndexing` refresh
replaces only that owner's token; other owners retain their valid release tokens; internal Git watcher refreshes retain it while advancing a
separate Core-only scan generation used by index and language-service caches.
Changing settings or `refresh: true` retires the old generation and discards its
cache. Hosts persist settings in application storage and reinstall them on project
open. Consumers must not create a new policy root for a scoped search; search scopes
are subsets of the registered project root. `paths` asks for additional effective
directory reasons without changing the generation. `excludedDirectories` is a
resolved, lazily populated set, not a complete enumeration of the filesystem.
`gitIgnoreFailed` means automatic decisions are incomplete; manual exclusions remain
in force. Hosts must display this state instead of treating it as empty rules.

Tree listings deliberately remain available. Snapshot inventories, filename and
content indexes, symbols and replacement preview candidates obey the policy.
Generated filename search cannot bypass it. Language-server working-copy sync is
blocked for excluded paths. Java additionally receives import exclusions; this does
not promise resource-scan exclusion for imported or build-declared modules. Rust and Go receive native configuration overlays that preserve user settings;
other providers may continue background scanning and hosts must display that limitation.

`workspace.snapshot.incompleteDirectories` is present when optional child directories
could not be scanned. Hosts retain browsing but must not treat that inventory as an
authoritative deletion list or refresh automatic analysis from it. Root failures and
cancellation remain errors. `workspace.releaseIndexing` removes only the matching owner/token lease. The last
release retires the policy and clears cached Git decisions and indexes; a small retired policy record rejects late work
until the next explicit configuration for that root.

`workspace.search.scopePaths` optionally limits candidates to workspace-relative
files or directory subtrees before applying result caps. It never establishes a new
policy root. Empty scopes search the full registered project.

Inventory snapshots, search (including Search Everywhere and its pages), index
warm/update requests and replacement previews accept optional `workspaceRoots`:
the absolute native roots explicitly opened in the calling workspace. Omission or
an empty array preserves single-root behavior. Core canonicalizes the roots and
prunes strict descendant roots from the current root's inventory and indexes;
the host queries each descendant using its own policy. Directory listing remains
available. Explicit replacement paths and text overrides cannot bypass ownership.
The effective descendant set is part of each index cache key and is retained for
save/watcher updates. It is request-local, never inferred from process-global
indexing policies or retired roots. Hosts discard in-flight results when their
workspace root set changes. Removing a nested root restores parent scanning.
An unavailable non-current root does not fail a scoped request for an accessible
root; a missing descendant retains its ownership boundary until removed by the host.

### Consumer tool preferences (development)

`toolchains.resolveConsumerPreferences` accepts `{document, directory, consumer?, tool, fixed?}`.
The document follows `toolchain-consumer-preferences-v1.schema.json`; `directory` is workspace-relative
and `consumer` is an inert `pluginID/contributionID` identity. A non-null explicit Run `fixed` value
wins. Otherwise the nearest consumer choice precedes general directory/workspace choices.
`inherit: workspace` reads the workspace tool afresh; `inherit: consumer` in a directory reads that
consumer's workspace preference and then the workspace tool. A consumer's `inherit: tool` reads
the general tool at the original requested directory, including its nearest general override;
following a workspace consumer reference preserves that original directory. General tool entries
cannot refer back to consumers or to themselves, so the reference graph cannot form cycles.
An absent general choice returns `fixed: null`,
which means the normal toolchain resolver still owns automatic/project/global selection.

The response is `{status: ok, preferences: {fixed, source, inheritance, stored}}`, or the standard rejected
`plugin.toolchain.invalidParams` / `plugin.toolchain.limitExceeded` envelope. Fixed values remain
inert inputs to the existing resolver; this command cannot register a tool, prove package trust,
resolve a version, write preferences or grant permission to run a program. Native consumers must
recheck their source bytes and active definitions after discovery. The shared fixture is
`shared/fixtures/toolchains/consumer-preferences.json`. The machine-local Run document stores it at `toolchain.preferences`. Run editor updates omit to
preserve, or pass an empty v1 document to reset. `runConfig.projectToolchain` returns the inert
`toolPreferences` alongside existing fields. The native host supplies the current
installed plugin/build-system contribution identity; both native Build consumers read these preferences
before the existing proof pipeline and recheck their bytes afterwards. `stored` is the value at exactly
the requested scope, or null when that scope inherits. It is separate from the resolved `fixed` input.

`toolchains.editConsumerPreferences` accepts `{document, directory, consumer?, tool, value}`.
`value` is required: null removes only that scope's override; otherwise it is a fixed selection or
an allowed symbolic inheritance reference. The command validates both the original and edited
documents, preserves siblings, prunes empty containers along the edited path, and returns
`{status: ok, edit: {document, preferences}}`. Resetting an absent value is a no-op.

`runConfig.updateToolPreferences` accepts `{localDocument, preferences}` and returns
`{document}` containing the replacement local Run JSON. It replaces only `toolchain.preferences`;
it does not materialize legacy language/build defaults, migrate v1 Run entries or modify other fields.
The captured `localDocument` is required; this command performs no native I/O. Unknown document
versions are rejected without numeric narrowing. The native adapter owns bounded reads, cancellation,
read-only package boundaries, optimistic comparison, metadata-preserving atomic replacement and
read-back. No editor command discovers or executes tools. Global defaults and complete one-time
legacy migration remain incomplete; these APIs alone do not complete Stage D.

### Test run verdict

`build.resolveTestRunOutcome` takes `{ termination, scope, summary? }`, where
`termination` is `{ kind: "exited", exitCode }`, `{ kind: "timedOut" }` or
`{ kind: "cancelled" }`, `scope` is `workspace`, `project`, `suite` or `case`,
and `summary` is the `{ total, passed?, failed?, errors?, skipped? }` the
provider's decoded results reported, or `null` when the run has no structured
results. It returns `{ outcome, success, exitCode }` with `outcome` one of
`passed`, `testsFailed`, `exitedWithError`, `noTestsMatched` (an explicit suite
or case ran nothing), `noTestsFound` (a project or workspace scope ran nothing),
`timedOut` or `cancelled`. Interruptions never claim a test outcome, reported
failures outrank the exit code, a non-zero exit outranks an empty result, and a
zero exit with decoded results but no executed test is not a pass. Counts that
exceed `total` are `InvalidRequest`. No tool or selector syntax is interpreted.
Hosts localize the outcome. Cases: `shared/fixtures/build/test-run-outcome-v1.json`.

### Test history merge

`build.mergeTestOutcomes` takes `{ previous, incoming, scope }`: `previous` and
`incoming` are lists of result identifiers (strings) in display and report order,
and `scope` is `{ ids?, prefixes? }`, the identifiers the run replaces. A result is
covered when its id equals one of `ids` or starts with one of `prefixes`; an empty
scope covers nothing and an empty prefix is `InvalidRequest`. It returns
`{ entries: [{ source, index }] }` with `source` `previous` or `incoming` and
`index` the position in that input: covered history entries are dropped, the
others stay in place, then the run's covered results follow. Incoming results
outside the scope are discarded, and for a repeated id the later entry wins.
Core compares strings only: hosts keep the result payloads, and the provider
adapter builds the scope (for example turning Java nested classes `Outer$Inner`
into the prefix `Outer$`). Cases: `shared/fixtures/build/test-outcome-merge-v1.json`.

### Variable and disassembly paging

`debug.planVariablePage { variablesReference, namedVariables?, indexedVariables?, pageSize }`
returns a cursor `{ variablesReference, pageSize, segments, loadedPages, next? }`.
Named children page before indexed ones; without counts the container pages
unfiltered until a short page. `next` is the `{ filter?, start, count, remainingCount? }`
to send as `debug.inspect` `variableFilter`/`start`/`count`; it is absent once the
container is exhausted. `debug.reduceVariablePage { state, requested, page, newItemCount }`
takes the page's `{ name, value, type?, evaluateName?, variablesReference }`
identities and how many of them the host did not already show, and returns
`{ accept, state }`. `accept: false` means the host drops the page: it answers an
older cursor or repeats a page (an adapter that ignores `start`). Paging stops on
an oversized page, a page of only known children, the reported count, or a short
page without a count. Hosts keep the page size, expansion and child identity.
Cases: `shared/fixtures/debug/variable-page-plan-v1.json`.

`debug.planDisassemblyWindow { direction, reference, count, instructionsBefore? }`
returns a fetch whose `request` is the exact DAP `disassemble` arguments;
`direction` is `around` (the first window, `instructionsBefore` of `count` above
the instruction pointer), `before` or `after` (one listed edge).
`debug.reduceDisassemblyPage { fetch, reply, knownAddresses? }` takes the reply as
`{ kind: "instructions", instructions: [{ address, instruction, instructionBytes? }] }`,
`{ kind: "rejected", message }` (the adapter answered `success: false`) or
`{ kind: "failed", message }` (transport, timeout, cancellation) and returns
`{ kind: "request", fetch }`, `{ kind: "page", keep, exhausted }` or
`{ kind: "failed", message }`. `keep` indexes the reply's addressable
instructions (empty padding removed) not already in `knownAddresses`, compared
as canonical address text. A refused first window with a negative offset is
retried from the instruction pointer; a refused edge page is halved down to one
instruction, then the known edge is probed: only an edge that still
disassembles ends the direction (`exhausted`), otherwise the refused window's
message is returned. Transport failures are never treated as a boundary.
Addresses are never parsed or offset by Core or hosts. Hosts keep the viewport,
scroll anchor and rendering. Cases: `shared/fixtures/debug/disassembly-paging-v1.json`.

### Windows source-breakpoint relocation

Windows forwards the editor's exact source-preserving edits to
`debug.relocateBreakpoints` and converts its zero-based store lines to/from Core's
one-based lines. The context-expanded patches used to synchronize the editor's
source mirror must not be used as anchor edits: unchanged neighboring code must
not be treated as deleted. The existing cases in
`shared/fixtures/debug/breakpoint-relocation-v1.json` cover both platforms.

Each native multi-cursor event is sent as one batch of original-source edits;
Core applies the edits before projecting anchors. Rapid events serialize or share
one ordered request, split views share a mutation identity, and launch reads the
current owner after all pending relocations complete.

## Markdown rendering

`markdown.render` accepts `{ "source": "<Markdown text>" }` and returns
`{ "html": "<sanitized HTML fragment>" }`. The existing Comrak dialect and
Ammonia sanitizer are shared by macOS and Windows; platforms must not parse
Markdown again or fall back to another dialect. Closed leading `---` front
matter is omitted, not rendered as a platform-specific property card.
Code fences preserve whitespace and language classes, and rendered elements
can contain `data-sourcepos` attributes. Platform syntax coloring must preserve
these attributes and the original decoded code text.

Raw formatting HTML can survive, but scripts, executable attributes, embeds,
arbitrary inline styles and unsafe URL schemes are removed in Core before
embedding. Windows asynchronously requests this existing command via its
central dispatcher, discards obsolete responses and falls back to the sanitized
fragment if syntax coloring fails. Render failures are shown as localized text;
there is no frontend Markdown parser fallback. This does not promise Windows
math or diagram rendering parity.

Shared examples: `shared/fixtures/editor/markdown-render-v1.json`,
`markdown-html-v1.json` and `markdown-rich-content-v1.json`.

### Structured logging of recoverable LSP maintenance warnings

`lsp.pollEvents` log observations may carry the existing `error` object even at
WARN severity. Its code and stage describe a recoverable diagnostic; `type:log`
does not transition session state. Codes have one meaning:

| code | stage | meaning |
| --- | --- | --- |
| `mavenSettingsUnchanged` | `mavenSettings` | Maven settings could not be normalized and were forwarded unchanged |
| `configurationCleanupFailed` | `configurationCleanup` | Unused language-server configuration areas could not be removed |
| `mavenProfileStartFailed` | `mavenProfileStart` | The pending Maven profile update could not start |

The existing Core log sources additionally classify `upstreamStderr` (stderr
observation), `stderrReadFailed` (stderr I/O), `navigationLimited` (batch cap),
`navigationMarkerFailed` (marker verification), `workspaceImportStalled`
(no import progress), `mavenProfileUpdateFailed` (project update failure),
`shutdownTimeout` (forced termination after shutdown deadline), and
`mavenProfileTimeout` (profile application deadline). Each code names exactly
that observation; arbitrary upstream messages retain `upstreamDiagnostic`.

Hosts persist these controlled identities, never the raw detail, URL, output or argv.

### Batched breakpoint relocation snapshots

`debug.relocateBreakpoints` retains the single `edit` input and also accepts `edits`, an array of non-overlapping original-source UTF-16 replacements. Character anchors are retained until the complete batch finishes; only then are positions projected and duplicates merged. LF, CRLF and lone CR are line boundaries.

Optional `editBatches` contains up to 127 additional editor mutations in order,
with up to 4096 edits and 64 MiB of replacement text across those additional
batches. Each batch uses UTF-16
offsets in the text produced by the preceding mutation. Core projects and
deduplicates breakpoints after each mutation, exactly as for separate calls, and
keeps `originalIndices` relative to the request's original breakpoint list.

The response's `originalIndices` array identifies the zero-based input breakpoint
that survived for each entry in `breakpoints`, in the same order. It allows a host
to preserve breakpoint identity after relocation and collision resolution.

Optional `document: {id, version}` enables bounded process-local source reuse. Version 1 supplies `source`; each subsequent version increments by one and omits source. Missing or stale snapshots fail closed. The cache holds four sources of at most 16 MiB each, evicts least-recently-used entries, and never writes runtime resources. Hosts reset with a new identity when the exact source chain changes.

### Engine logging v2 handoff (PR3)

`lsp.startServer` adds optional `role` (`language_server`, `vcs`, `build`,
`toolchain`, `backend`; default `language_server`) and optional `logSubject`.
The host supplies the registered VCS ID as `logSubject` for `role:vcs`.
The start response additionally returns `channel`, derived by Core from these
identities, so hosts can register trace I/O without rebuilding routing rules.
Core does not parse prefixes or colons in `providerId`. Routing is:

| Role | Catalog channel | Identity field |
| --- | --- | --- |
| `language_server` | `lsp/{server}` | `providerId` |
| `vcs` | `vcs/{provider}` | `logSubject` |
| `build`, `toolchain`, `backend` | `plugins/{plugin}/host` | `pluginId` |

Every dynamic segment passes `validate_segment`. Invalid or missing identities
use `invalid-` followed by the first 32 lowercase SHA-256 hexadecimal digits of
that identity (the opaque provider ID when the selected identity is absent).
This deterministic fallback preserves evidence and startup compatibility for
language IDs such as `c++`; it never exposes the original invalid text as a path.
`pluginId` in the event remains the original ownership identity, independently
of the validated catalog routing field. Hosts must use `fields` and `channel`
from Core, never rebuild the route from `providerId` or `pluginId`.

Log runtime events retain `type:"log"`, sequence, providerId, sessionId,
level, message, detail, error, and Maven state fields. They add `channel`,
`pluginId?`, `role`, `event` (catalog ID), `catalogLevel` (canonical uppercase v2 level), and `fields` (normalized scalar disk
fields). `type` is the actual JSON discriminator; there is no `kind` wire key.
Catalog metadata determines canonical v2 severity; the old `level` remains a v1
compatibility value, including its historical `warning` spelling. To pass one
fact to `diagnostics.encodeLogBatch`, the host supplies a timestamp and its own
session sequence and uses `catalogLevel`, the catalog's uppercase severity. It sets
`validateCatalog:true`; catalog-derived channel and message are authoritative.
The special system event `log.dropped` uses the validated session channel.

```json
{"type":"log","sequence":17,"providerId":"opaque:git:provider","sessionId":"lsp-1","level":"info","message":"window/logMessage","detail":"{\"type\":2,\"message\":\"upstream warning\"}","channel":"vcs/git","pluginId":"io.example.git","role":"vcs","event":"vcs.message.logged","catalogLevel":"INFO","fields":{"provider":"git","diagnostic":"upstream warning","severity":"warning"}}
```

`window/logMessage` and `window/showMessage` produce `*.message.logged` and
`*.message.shown`. The `severity` token is `error|warning|info|log|debug`.
Upstream diagnostics pass through the shared text normalization/redaction
boundary. Other notifications record only their method, never the payload.
Existing v1 `detail`, `message`, and `level` remain byte-for-byte compatible,
including `projectCount=N`, navigation format strings, and original notification
JSON. V2 source inputs travel independently of detail; Core never parses v1
detail to construct catalog fields. The one stderr framing change is explicit:
v1 detail is now each complete line (without LF/trailing CR), including its
spaces, rather than a trimmed arbitrary read chunk. The existing reader bounds
and overflow rules below apply. New dropped facts use `count=N`, not JSON detail.
Legacy detail is not a v2 persistence input. Trace catalog level is DEBUG while
its historical v1 level remains info.
Core lifecycle transitions attach `*.session.updated`, `channel`, `pluginId`,
`role`, `fields:{server|provider|plugin,state}`, and `catalogLevel:DEBUG` to the
existing `type:"stateChanged"` event. They pass through the same
`prepare_catalog_event` boundary as log facts. They never add a v1 `type:"log"`
row, and existing type/state/sequence/message/error fields remain unchanged.
Hosts decode and forward optional structured identity independently of the event
kind, once before event-specific handling; this also covers VCS, build, toolchain
and backend sessions. Core owns these session lifecycle states and protocol
initialization. macOS owns only `lsp.session.stage_changed` (DEBUG; closed
requested|resolving|registered|stopping|cancelled) and `lsp.cache.cleaned` (DEBUG;
removed entry count), emitted at the source rather than inferred from v1 text.
Host ready/terminated callbacks retain v1 buffer lines without duplicate v2 facts.
Stderr is framed by LF, removes a trailing CR, ignores empty lines, flushes the
last partial line at EOF, and keeps at most 4096 bytes per line while discarding
the remainder through LF. `truncated:true` marks the reader limit. Catalog text
normalization then redacts and caps the diagnostic at 1024 UTF-8 bytes.
The reader accepts at most 200 nonempty lines in each monotonic elapsed-second
window. Suppressed counts produce `log.dropped` on the next reader observation
in a later window or on reader completion, including read failure. No idle
background timer is installed.

`lsp.setDetailedDiagnostics` accepts `{sessionId,enabled}` and returns `{}`.
It sends `$/setTrace` with `{"value":"verbose"}` when enabled and
`{"value":"off"}` when disabled. Sessions start disabled; only enabled
sessions emit `*.trace.received` (DEBUG). Only the summary `message` enters v2,
limited to 1024 UTF-8 bytes before shared text redaction and control removal.
The `verbose` field is excluded because it can contain raw RPC bodies and source
text; the legacy in-memory detail remains compatible. The gate changes only
after a successful ordered write. Before the initialize handshake completes, the command
only stores the latest desired value; an enabled value is sent after `initialized`
in the ordered handshake batch. Disabling it before that batch cancels the pending
enable without sending any trace notification. Invalid payloads or terminal
sessions fail through the existing Core error envelope; transport errors keep the existing session
failure/cleanup behavior. This does not change showMessage handling.

```json
{"version":1,"command":"lsp.setDetailedDiagnostics","payload":{"sessionId":"lsp-1","enabled":true}}
```

```json
{"id":null,"ok":true,"data":{}}
```

`diagnostics.drainCoreEvents` accepts `{}` and atomically returns
`{events:[{ts,level,event,channel,op?,fields}],dropped}` in the ordinary Core
success envelope. It drains a process-owned queue shared across workspaces,
with at most 256 normalized entries. Overflow and exact duplicate pending
facts increment a saturating `dropped` counter; draining resets the counter.
The host converts `dropped` to `log.dropped` on its application channel.
`record` accepts only catalog events whose owner is `lithe-core`: logging error
`-32059` means Core event owner mismatch, exclusively; existing `-32053` through
`-32058` retain their catalog and collection meanings.

`lithe_core_install_log_waker(callback, context)` registers the host's single
log writer for a pending-fact signal; a later install replaces the earlier one
and a null callback is ignored. Core invokes the callback at most once per drain
cycle: when the first fact or drop is queued after a drain, and immediately at
install when facts are already pending. It runs synchronously on the recording
or installing thread, must not unwind or call back into Core, and only schedules
the writer's existing drain. `lithe_core_remove_log_waker(context)` returns 1 when
`context` owned the registration and 0 otherwise; after it returns, Core never
invokes the callback with `context`. The waker belongs to the existing queue:
there is no second writer, file handle, background task, or poller. The queue
observes UTC at the Core event boundary; host
session sequences are assigned at drain ingestion. Project skips retain only
workspace-relative paths and stable error categories; cleanup facts retain
only categories, excluding remote addresses, output, and scratch names.

```json
{"version":1,"command":"diagnostics.drainCoreEvents","payload":{}}
```

```json
{"id":null,"ok":true,"data":{"events":[{"ts":"2026-11-03T08:00:00.000Z","level":"WARN","event":"app.workspace.directory_skipped","channel":"app","fields":{"path":"src/inaccessible","error":"Directory traversal failed","error_code":"permission_denied","error_domain":"core"}}],"dropped":0}}
```

`diagnostics.configureCoreEvents` accepts `{debug:bool,roots?:[string]}` and
returns `{}`. Unknown fields fail with `invalid_request`. It sets the process-wide
admission gate for DEBUG Core facts: `debug:false` rejects every DEBUG fact,
`debug:true` without `roots` admits DEBUG on every channel root, and
`debug:true` with `roots` admits DEBUG only on the listed roots. The default is
disabled. Rejected DEBUG facts return success to their producer, are never
queued and never count as dropped, so background traces cannot fill the
256-entry queue and displace later WARN or ERROR facts. INFO, WARN and ERROR
are always admitted. Producers that build expensive fields check the gate first.

```json
{"version":1,"command":"diagnostics.configureCoreEvents","payload":{"debug":true,"roots":["app","vcs"]}}
```

```json
{"id":null,"ok":true,"data":{}}
```

`diagnostics.recordPluginOperation` records one terminal result of a declarative
plugin contribution: work a plugin declares in its manifest that the host or a
Core engine executes, so no plugin process can report it through `lithe/log`. It
accepts `{pluginId,operation,outcome,stage?,durationMs,operationId?}` with no other
keys and returns `data:{result:{}}` once the fact is queued, or
`data:{error:{code:-32064,reason}}`. `outcome` is `finished|failed`; `stage` is
required for `failed` and forbidden for `finished`. `durationMs` is monotonic
milliseconds up to 2^53-1. `operationId` follows the SDK `operationId` grammar
(1-128 bytes of ASCII letters, digits and `._:/-$`). The fact becomes
`plugins.operation.finished` or `plugins.operation.failed` on
`plugins/{plugin}/host`, the same events and channel an SDK-backed plugin writes,
with fields `plugin`, `operation`, `duration_ms` and, for failures, `code`.
Cancellation is never recorded. No plugin output, path or error text is accepted.

Each accepted `operation` is one row of Core's contribution table. The row's
lifecycle decides which stages exist and which `host.*` code each stage means, so
a code has one meaning across every contribution with that lifecycle:

| `operation` | Contribution | Lifecycle |
| --- | --- | --- |
| `languageServer/start` | `languageServers[]` | process start |
| `debugAdapter/start` | `debugAdapters[]` | process start |
| `lithe/build/model` | `buildSystems[].model` command source | command run |
| `lithe/build/dependencies` | `buildSystems[].dependencies` command source | command run |

| `stage` | Process start | Command run |
| --- | --- | --- |
| `plan` | rejected | `host.planFailed` |
| `resolve` | `host.executableUnavailable` | `host.executableUnavailable` |
| `launch` | `host.launchFailed` | `host.launchFailed` |
| `initialize` | `host.initializeFailed` | rejected |
| `timeout` | `host.timedOut` | `host.timedOut` |
| `exit` | `host.exitedEarly` | `host.commandFailed` |
| `decode` | rejected | `host.outputInvalid` |

An unknown operation, a stage the lifecycle cannot reach, an unknown key, an
explicit `null` for an optional key, an invalid operation ID or an out-of-range
duration all return -32064. Whoever executes the attempt records it. The host
records debug adapter starts and build commands itself. A debug adapter start
uses the debug session ID as `operationId`, so it correlates with that session's
own debug records. It stays at `launch` until the adapter is reachable: a stdio
process once it runs, a language server hosted adapter once its socket connects.
A failure before then is `launch`, or `timeout` when the hosted adapter's
discovery deadline fires. `exit` applies only to an adapter that was reached.
Core refusing the debug session is a host outcome and is not recorded.

A declarative language server is resolved by the host and supervised by Core.
The host records failures before launch, including plugin API 1 servers that
launch as host-owned processes. Otherwise it passes
`startupOperation:{pluginId,operationId,elapsedMs}` on `lsp.startServer`. Core
accepts the handoff only for the language server role, and only when the
request's `pluginId` is absent or equals the handoff's `pluginId`; it ignores the
handoff otherwise. Core then records exactly one result:

- `launch` when `lsp.startServer` fails for any reason other than cancellation,
  including a failure to write the `initialize` request to the started process;
- `exit` when the process exits before `initialize` succeeds;
- `initialize` for any other terminal failure before then;
- `timeout` at the initialize deadline;
- `finished` when the `initialize` result succeeds.

A start that a newer indexing policy retires is cancelled and records nothing,
even after its process started. `durationMs` adds the host's `elapsedMs` to Core's own monotonic
time. Stopping before a result records nothing. A fact the engine cannot queue
increments the `dropped` counter.

```json
{"version":1,"command":"diagnostics.recordPluginOperation","payload":{"pluginId":"io.example.go","operation":"debugAdapter/start","outcome":"failed","stage":"resolve","durationMs":12,"operationId":"7c0d1f0e-3f6b-4a52-9d5e-0b7c2b0b9a11"}}
```

```json
{"id":null,"ok":true,"data":{"result":{}}}
```

`plugins.declarative.languageServerLaunchPlan.request.logDirectory` is an
optional absolute host-owned current-session plugin files directory for
`${logDir}`. Language servers and plugin backends use the same expansion.
Missing, unusable, or relative values fail with `plugin.launch.invalidRequest`
when needed; `requiredDirectories` adds `log` when used. The host creates the
provided writable directory before launch, outside all bundles and installation
resources. Validation probes cannot reference `${logDir}`. See the synchronized
[plugin contract](plugins/v1/README.md). Existing API 1 literal arguments remain
literal. Wire examples are exercised by
`shared/fixtures/diagnostics/engine-logging-v2.json` and Core tests.

Plugin-owned sessions offer `litheLogging` 1 independently of other protocols.
The negotiated `lithe/log` notification is validated in Core and enters the
same bounded `diagnostics.drainCoreEvents` queue, with the installed plugin
identity selecting `plugins/<id>/host`. It never copies notification JSON into
legacy runtime detail. The four facts map to catalog INFO/ERROR/WARN/WARN,
and a live wire request ID resolves to its original host `op`; no user content
or backend-selected channel/level/message is accepted. See the
[plugin logging contract](plugins/v1/README.md#structured-plugin-diagnostics-logging-protocol-1)
and `plugins/v1/fixtures/backend/plugin-logging.json`. Explicit upstream LSP message
types retain their severity through separate catalog events; unclassified
stderr is DEBUG and actual lifecycle failure is ERROR.

macOS PR3 passes `CoreLogRecord` directly to the injected `LogSink`. Every
MacLogStore drain, flush and finish calls `diagnostics.drainCoreEvents` once,
retaining source `ts`/`op` and allocating session `seq`. Only the application
writer installs the Core log waker; its callback schedules the same 100 ms
one-shot drain that host events use, so Core and plugin facts recorded without
host activity reach disk and live subscribers without an idle poller or second
writer. Finishing the session removes the waker before the final drain.
MacLogStore sends `diagnostics.configureCoreEvents` only when the
detailed-diagnostics state or its channel roots change. `channelCategory` maps
lsp to language, vcs to git and plugin-host processes to plugins. The selected diagnostic category drives
`lsp.setDetailedDiagnostics` for active sessions, newly registered sessions and
a one-shot 15-minute expiry. A failed desired state, including a failed
`configureCoreEvents`, is reported once with
`app.logging.diagnostics_failed`; changing desired state permits another attempt.
Language-server evidence has no in-memory v1 buffer on macOS; the log window reads
only v2 session files.

`diagnostics.resolveLogChannel` additionally returns optional `pluginFilesPath`
for a `plugins/<id>/host` channel using Core's `plugin_files_path` rule. macOS
creates that directory under its current session with mode 0700 and descriptor
relative no-follow traversal, and supplies `request.logDirectory` before local
language/provider/backend launch. Missing log storage omits it; Core rejects a
launch that actually uses `${logDir}`. Remote processes cannot write the macOS
log directory, so remote requests omit it and reject `${logDir}` rather than
writing into remote package/state directories. Package installation validation
uses an uncreated placeholder only to validate expansion, never to launch.

Core directory traversal and scratch cleanup reuse PR1's
`app.search.directory_skipped`, `app.workspace.directory_skipped` and
`app.workspace.scratch_cleanup_failed`. Error message/domain are fixed; code is a
stable category without absolute paths, scratch names or remote addresses.
Remote process/upload cleanup uses ClientError categories timeout, closed,
transport, spawn, protocol, or remote_<protocol_code>; peer prose is excluded.

### Execution traces

Core records one terminal fact for each dispatched request and one for each Git
process, and hands both to the host through `diagnostics.drainCoreEvents`. Event
identities and field shapes are declared in `shared/logging/events/app.json` and
`shared/logging/events/vcs.json`; this section defines when each is emitted.

Request traces use channel `app/core`: `app.core.request.finished` (INFO),
`app.core.request.traced` (DEBUG) and `app.core.request.failed` (WARN). The
dispatcher resolves the trace `op` from the first of `origin.operation`,
`operationId` and `id` that has the `operation` shape, and the source from `origin.source` unless it is absent or `unknown`, then
`gitExecution.source`, then `unknown`. It installs `{op, source}` as thread-local context for the request's
duration, so every Git process the request starts inherits both. An error
response other than `cancelled` is `failed` and carries `error` with domain
`core`. Any other response is `finished` when the source is `user` and `traced`
otherwise; a cancelled response adds `cancelled:true`. Fields are `method`,
`source`, `duration_ms`, the optional payload `operation` selector, `trigger`,
the first absolute path among `root`, `workspaceRoot`, `repositoryRoot`, `projectRoot`,
`rootPath`, `directory` and `path` in the payload, recorded as `path`, and `remote` for
remote workspaces. No other payload content is recorded. `core.ping`, every
`diagnostics.*` command and the per-keystroke, per-frame, polling and watcher
methods listed in `request_trace::is_hot` record nothing.

Git process traces use channel `vcs/git`: `vcs.git.command.finished` (INFO),
`vcs.git.command.traced` (DEBUG) and `vcs.git.command.failed` (WARN). They are
emitted at the single execution point shared by local and remote workspaces.
A visible command runs through `execute_git` and is returned to the host as an
invocation; an internal read runs through `capture_git` and Core parses its
output. Outcomes are classified in this order:

1. A `cancelled` runner error is a cancellation; any other runner error is a failure.
2. Exit status 0 is a success.
3. An exit status that the command documents as an answer (for example 1 from
   `git diff --quiet` or `git config --get`) is a success.
4. A nonzero exit of an internal read whose source is not `user` is a success at
   this layer; the caller decides its meaning, and an error response it returns
   is recorded by the request trace.
5. Every other exit is a failure.

A failure is `failed`. A success or cancellation is `finished` for a visible
command whose source is `user` and `traced` otherwise. Fields are `command`,
`arguments`, `source`, `duration_ms`, and optionally `repository`, `remote`,
`exit_code` and `cancelled`. `arguments` is produced only by `format_arguments`:
commit message values become `<message>`, values of `-c` keys that name
credentials or personal identity become `<redacted>`, URL user information and
the shared redaction patterns are rewritten, arguments are quoted where needed,
and text beyond 1024 bytes is cut with a trailing `…`. A failure, a cancellation
or a nonzero exit adds `stderr`: the last 8 nonempty lines of the final 16 KiB of standard
error, each redacted and joined with ` | `, keeping the newest 1024 bytes with a
leading `…`. A failure caused by a runner error adds `error`, `error_code` and
`error_domain:"core"`;
the process `exit_code` is never merged into `error_code`. Standard output,
standard input and environment values are never recorded.

Trace failures are always WARN because Core cannot know whether the host will
retry, degrade or give up. A host that notifies the user about a failure whose
facts are all in a same-`op` trace references that record instead of logging
the failure again.

```json
{"ts":"2026-11-03T08:00:01.123Z","level":"WARN","event":"vcs.git.command.failed","channel":"vcs/git","op":"op-7f3a","fields":{"command":"fetch","arguments":"fetch --prune origin","repository":"<HOME>/src/app","source":"user","duration_ms":311,"exit_code":128,"stderr":"fatal: could not read from remote repository."}}
```

`agent.attachments.retentionPlan` decides which pasted Agent images the platform may
delete; it reads and writes no files. The payload is `{nowMs, entries, acceptedReferences,
ledgerPresent, caseInsensitive}`: `entries` lists the platform's pasted-image cache as `{path, modifiedMs,
abandoned}` (`modifiedMs` is Unix milliseconds and may be omitted; `abandoned` marks a
paste that failed or was discarded before any conversation accepted it),
`acceptedReferences` is the platform ledger of paths a conversation accepted, and
`caseInsensitive` (Windows) compares paths without case; separators are always normalized.
`ledgerPresent` reports only whether the ledger file exists, never whether it is empty: when it
is missing, every non-abandoned cached image counts as accepted (the cache predates the
ledger) and is returned in `seed`, which the platform writes atomically (temporary file, then
rename) before deleting anything. The result is `{delete, keep, seed}`, the first two lists of `{path, reason}` in entry order. Reasons:
`referenced` (kept, even when flagged abandoned), `recent` (kept, unreferenced and at most
seven days old or of unknown age), `abandoned` and `expired` (deleted). The cache and the
ledger live in the platform cache directory, never in the app bundle or install directory.
The fixture is `shared/fixtures/agent/attachment-retention-v1.json`.
