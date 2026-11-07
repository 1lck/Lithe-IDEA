# AI pull request descriptions and inline edits

Version: 1. Behavioral fixtures: `shared/fixtures/ai/pull-request-description-v1.json`
and `shared/fixtures/ai/inline-edit-v1.json`.

Both features reuse the credential-free provider request model of
[AI commit generation](ai-commit.md): Core validates the endpoint, appends the
protocol path exactly once, encodes a non-streaming body, and extracts text from
the complete response. Hosts resolve credentials, attach authentication headers,
perform HTTP with a bounded response, and present the result. Credentials are never
command inputs or outputs, and failures never echo patches, edit text or responses.

## Pull request descriptions

`ai.pullRequest.plan` accepts `{provider, options, comparison}` and returns
`{url, body}`. The typed Rust API is `plan_pull_request` / `decode_pull_request`.

- `provider` is the AI commit `Provider` (`responses`, `chatCompletions`,
  `anthropicMessages`).
- `options`: `language` (`english`, `simplifiedChinese`), `format` (`standard`,
  `concise`, `detailed`, `custom`), `customTemplate` (up to 16,000 characters; a
  blank template selects `standard`), `maximumDiffCharacters` (8,000–120,000
  Unicode scalars), `reasoningEffort` (commit values; `default` omits the field).
- `comparison`: `repository`, `base`, `head`, `commitMessages` (context only) and
  `files: [{path, changeKind, diff}]`. Hosts report every changed file, including
  ones without a textual patch (`diff: ""`); Core drops them from the prompt but
  applies the commit sensitive-path policy to every listed path.

Core shares the commit diff budget across files with an explicit truncation marker,
keeps at most 250 commit messages within 16,000 characters, JSON-quotes metadata,
and allows 4,096 output tokens because providers count reasoning against the same
limit. More than 1,000 files is `AI_COMMIT_TOO_MANY_FILES`; no file with a textual
patch is `AI_PULL_REQUEST_EMPTY_COMPARISON`; provider and option failures use the
`AI_COMMIT_*` codes of the commit contract.

`ai.pullRequest.decode` accepts `{protocol, response}` and returns
`{title, description}`. The model output must be one JSON object, optionally inside
a single Markdown fence, with nonblank `title` and `description` strings. Partial
drafts and prose around the JSON are `AI_PULL_REQUEST_INVALID_RESPONSE`; no text is
`AI_PULL_REQUEST_EMPTY_RESPONSE`; output-limit termination is `AI_COMMIT_OUTPUT_LIMIT`.

macOS sends the GitHub branch comparison through the JSON commands. Windows sends
its local `base...head` ref diff to the native `ai_commit_pull_request` command
(`{operationId, provider, options, comparison}` → `{title, description}`), which
shares the AI commit adapter's credential resolution, cancellation, 45-second
deadline, redirect policy and 2 MiB response cap. Windows does not yet collect the
branch's commit messages and sends an empty list.

## Inline edits

`ai.inlineEdit.plan` accepts:

```json
{
  "provider": {
    "wireProtocol": "chatCompletions | anthropicMessages | geminiGenerateContent | responses",
    "endpoint": "base URL or complete endpoint",
    "requiresApiKey": true,
    "allowsInsecureHttp": false,
    "acceptsUnlistedModels": false,
    "chatTokenLimitField": "max_tokens | max_completion_tokens",
    "supportsTemperature": true
  },
  "model": { "id": "model", "listing": "catalog | discovered | unlisted", "maxTokens": 4096 },
  "edit": {
    "beforeSelection": "", "selectedText": "", "afterSelection": "",
    "instruction": "", "filePath": "", "languageId": ""
  }
}
```

The platform resolves its provider catalog into these facts; provider-specific
knowledge such as which models need `max_completion_tokens` stays with the
provider adapter. Core owns the rest:

- A blank model is `AI_INLINE_EDIT_MODEL_MISSING`. An `unlisted` model is rejected
  with `AI_INLINE_EDIT_MODEL_NOT_FOUND` unless the provider accepts unlisted ids.
- Output tokens are `min(maxTokens, 4096)`, using 4,096 when the listing has no
  positive limit.
- At most 12,000 Unicode scalars of context are kept on each side of the
  selection. Platforms read a window of at least that size without splitting
  surrogate pairs; all edit text together is limited to 2 MiB
  (`AI_INLINE_EDIT_INVALID_REQUEST`).
- A blank instruction becomes `Improve this code while preserving behavior.`; the
  system prompt, file and language context and temperature 0.2 (when supported)
  are fixed by Core. Requests are not streamed.
- Endpoint failures are `AI_INLINE_EDIT_ENDPOINT_MISSING`,
  `AI_INLINE_EDIT_INVALID_ENDPOINT` (no host, user info, query or fragment) and
  `AI_INLINE_EDIT_INSECURE_ENDPOINT`; an unknown protocol is
  `AI_INLINE_EDIT_UNSUPPORTED_PROVIDER`.

The result is `{url, body, headers, credential: {required, header, scheme}}`.
`headers` are non-secret; the host attaches its credential under
`credential.header`, as `Bearer <key>` when `scheme` is `bearer` and verbatim when
it is `raw`, and fails with `AI_INLINE_EDIT_MISSING_KEY` when `required` is true
and no credential exists.

`ai.inlineEdit.decode` accepts `{wireProtocol, response}` and returns
`{editedText}`: the trimmed text with one wrapping Markdown fence removed. An empty
replacement is a valid result that the caller reports; an output-limit
termination is `AI_INLINE_EDIT_OUTPUT_LIMIT`, so partial code is never applied; a
non-object response is `AI_INLINE_EDIT_INVALID_RESPONSE`.

Inline edit is only offered by the Windows product. Platform-owned failures are
`AI_INLINE_EDIT_PROVIDER_NOT_FOUND`, `AI_INLINE_EDIT_MISSING_KEY`,
`AI_INLINE_EDIT_NETWORK_ERROR`, `AI_INLINE_EDIT_HTTP` (with the status only; error
bodies are not shown because they may echo request content) and
`AI_INLINE_EDIT_FAILED`.
