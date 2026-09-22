# AI commit generation contract

Version: 1. Behavioral fixture: `shared/fixtures/ai/commit-generation-v1.json`.

Windows consumes the typed Rust API in `lithe_core::ai`. macOS remains the reference
for settings and generation behavior and currently retains its Swift implementation;
this change does not claim that macOS calls the new Rust API. The API has no filesystem,
HTTP, operating-system credential, or UI dependencies.

## Portable inputs

`Provider`: `id`, `name`, `endpoint`, `model`, `apiProtocol`, `authentication`,
`source`, `requiresApiKey`, `allowsInsecureHttp`. Sources are `local`, `codex`,
`claude`; authentication is `bearer` or `apiKey`.

`CommitOptions`: `language` (`english`, `simplifiedChinese`), `format`
(`conventional`, `concise`, `imperative`, `descriptive`, `releaseNote`, `custom`),
`customInstructions`, `includeBody`, `subjectMaximumLength` (20–200),
`maximumDiffCharacters` (8,000–120,000 Unicode characters), `reasoningEffort`
(`none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`).

`CommitFile`: repository-relative `path`, `changeKind`, and `diff`.
The caller must provide evidence matching its actual commit operation:
macOS uses staged diffs, Windows uses the full working-tree snapshot of selected paths.
Generation never stages, commits, or pushes.

## Typed operations

- `parse_codex(config, auth, environment)` parses TOML using the existing TOML dependency.
  It supports the selected profile, provider `base_url`, `wire_api`, `env_key`, and
  API-key auth JSON. OAuth token bundles are not API keys.
- `parse_claude(settings, credentials, root, environment)` parses supported JSON and
  environment settings, resolves common model aliases and selects bearer/API-key auth.
- Both return `DetectedConfiguration`; its `credential` is host-only and skipped by
  Serde serialization. Only metadata and `hasCredential` cross the UI boundary.
- `plan_commit(provider, options, files)` returns a credential-free URL and JSON body.
  It validates protocol, URL and limits; distributes diff space across file boundaries;
  and includes language, format, custom and subject/body instructions.
- `decode_message(protocol, response, include_body)` extracts text from the three
  supported response envelopes, strips Markdown fences and rejects empty responses.

## Windows adapter surface

All commands route through existing `platform_invoke`:

| Command | Arguments | Result |
| --- | --- | --- |
| `ai_commit_detect` | `{}` | `{ configurations: [{provider,hasCredential}], warnings: [{source,code}] }` |
| `ai_commit_key` | `{id,action:"status"|"save"|"remove",value?}` | Boolean credential presence; never the credential |
| `ai_commit_generate` | `{operationId,provider,options,files}` | `{message}` |
| `ai_commit_cancel` | `{operationId}` | `null` |

The adapter reloads imported profiles immediately before each request and ignores
caller-supplied imported endpoints/models. Credentials are read from the same snapshot.
Manual credentials use the application-scoped Windows Credential Manager namespace.
Imports never write back to Codex/Claude files. Cancellation drops the pending HTTP
future. Requests have a 45-second deadline; no redirects; a 2 MiB response cap.
Configuration reads have a 1 MiB per-file cap. At most four requests may be registered.

Errors are stable strings prefixed `AI_COMMIT_`, including `INVALID_PROVIDER`,
`INVALID_OPTIONS`, `INSECURE_ENDPOINT`, `MISSING_KEY`, `EMPTY_DIFF`, `SENSITIVE_FILE`,
`EMPTY_RESPONSE`, `INVALID_RESPONSE`, `TIMEOUT`, `NETWORK_ERROR`, `CONFIG_MISSING`,
`INVALID_CONFIG`, `CONFIG_READ_FAILED`, `CONFIG_TOO_LARGE`, `KEY_FAILED`,
`RESPONSE_TOO_LARGE`, `BUSY`, `CANCELLED`, `INTERNAL_ERROR`, and `HTTP_<status>`.
The frontend maps them to actionable localized messages and discards stale results.

## Draft lifecycle

Only one generation per commit panel is active. Changing repository/branch/selection
or unmounting cancels it. A successful response is a draft, never a Git mutation.
Existing text requires replacement confirmation. Selection and patch fingerprints
are rechecked before applying; edits made while confirming are preserved.

Subject length is an instruction to the model, not a hard truncation guarantee.
Anthropic Messages does not receive reasoning-effort fields. Filesystem location,
credential management and actual HTTP cancellation remain host-owned behavior.
