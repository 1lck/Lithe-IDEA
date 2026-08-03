# Rust Core API

The Rust core is the shared application runtime for macOS SwiftUI and Windows
Qt/C++. Both bindings call the same C ABI:

```c
const char *lithe_core_version(void);
char *lithe_core_execute_json(const char *request);
void lithe_core_free_string(char *value);
```

The macOS package uses the small C bridge in `Sources/LitheRustCore/`. The
canonical C declarations are in `rust/lithe-core/include/lithe_core.h`.
Windows can link the same `staticlib` or `cdylib` and call these functions from
C++.
Strings returned by the core are UTF-8 JSON allocated by Rust. The caller must
release response strings with `lithe_core_free_string`.

## Envelope

Every request has this shape:

```json
{
  "id": "request-id",
  "command": "workspace.search",
  "payload": {}
}
```

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

| Command | Purpose |
| --- | --- |
| `core.ping` | Verify the ABI and protocol version |
| `workspace.snapshot` | Enumerate visible workspace nodes and relative file paths |
| `workspace.search` | Search visible file names and UTF-8 text files |
| `file.read` | Read a UTF-8 file using a workspace-relative path |
| `file.write` | Write a UTF-8 file using a workspace-relative path |
| `git.status` | Resolve the repository, current branch, and working-tree changes |

Workspace paths in responses are relative and use `/` separators. Line numbers
are one-based. `git.status.repositoryRoot` may be an absolute path when the
opened workspace is a subdirectory of the repository; all Git change paths are
relative to that repository root. The core rejects absolute paths and `..`
traversal for file commands. Native file dialogs, file watching, PTY/ConPTY,
Java processes, and runtime discovery remain platform adapters.

The protocol version is currently `1`. Add a fixture under `shared/fixtures/`
before changing a response shape or search rule.

`workspace.search` accepts `maxResults` for a total result cap. Callers that
need separate buckets may also provide `maxFileResults` and
`maxContentResults`; each category is capped independently and the total cap
still applies.
