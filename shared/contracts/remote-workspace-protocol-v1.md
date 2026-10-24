# Remote workspace protocol v1

The protocol between a Lithe client and `lithe-remote-server`, which runs at
the end of a transport chain (SSH host, container, or a chain of both). The
Rust types in `rust/lithe-remote-protocol/` are the reference
implementation; this document is the compatibility surface for other
clients. Design rationale lives in
`.agents/notes/proposed/architecture/2026-10-24-remote-development-workspace-host.md`.

## Stream

1. The server writes the preamble `\nLITHE-REMOTE-PROTOCOL/1\n` once.
   Clients discard up to 64 KiB of bytes before it (shell banners) and report
   them as diagnostics when the preamble never arrives.
2. Every following unit is a frame: a 4-byte big-endian length and that many
   bytes of UTF-8 JSON. Frames larger than 16 MiB are rejected.
3. Closing the client-to-server stream is a disconnect. The server then
   terminates every process group it started (`SIGTERM`, then `SIGKILL`
   after 2 seconds) and exits.

The server never listens on a network port; all traffic, including future
port forwarding, uses this stream.

## Messages

```json
{"type": "request", "id": 1, "method": "fs.stat", "params": {"path": "/srv"}}
{"type": "response", "id": 1, "result": {"kind": "directory", "size": 4096, "modifiedMs": 1761300000000, "readonly": false}}
{"type": "response", "id": 2, "error": {"code": "NOT_FOUND", "message": "…", "details": {"path": "/x", "osError": 2}}}
{"type": "event", "event": "process.exit", "params": {"processId": 1, "exitCode": 0, "signal": null}}
```

- `id` is chosen by the client and unique per connection. Responses may
  arrive in any order. A client that stops waiting discards a late response.
- The first request must be `server.hello`; anything earlier fails with
  `INVALID_REQUEST`.
- Field names are camelCase. Byte payloads (`data`) are standard Base64.
- Paths are absolute paths on the remote host. Relative paths fail with
  `INVALID_PATH`.

## Methods

| Method | Params | Result |
| --- | --- | --- |
| `server.hello` | `protocolVersion`, `clientName` | `protocolVersion`, `serverVersion`, `host` capabilities |
| `server.shutdown` | — | `null`; the server then exits |
| `fs.stat` | `path` | file metadata of the path itself (links not followed) |
| `fs.readDir` | `path` | `entries` sorted by name byte order, `skippedNonUtf8` |
| `fs.readFile` | `path`, `offset`, `length` (≤ 8 MiB) | `data`, `eof`, `metadata` |
| `fs.writeFile` | `path`, `data` (≤ 8 MiB), `expected`, `overwrite`, `createParents` | metadata after the write |
| `fs.createDir` | `path`, `recursive` | `null` |
| `fs.remove` | `path`, `recursive` | `null`; links are removed, never followed |
| `fs.rename` | `from`, `to`, `overwrite` | `null` |
| `fs.volumeInfo` | `path` | `caseSensitive` (`null` when unknown) |
| `process.spawn` | `argv`, `cwd`, `env`, `pipeStdin` | `processId`, `pid` |
| `process.writeStdin` | `processId`, `data` | `null`; `BUSY` when the process stops reading |
| `process.closeStdin` | `processId` | `null` |
| `process.kill` | `processId`, `force` | `null`; signals the whole process group |

`fs.writeFile` replaces the file atomically through a temporary sibling and
writes through symbolic links. With `expected` (`size`, `modifiedMs`) it fails
with `CONFLICT` unless the file still matches; without it, an existing file is
only replaced when `overwrite` is set.

## Events

| Event | Params |
| --- | --- |
| `process.output` | `processId`, `stream` (`stdout` / `stderr`), `data` |
| `process.exit` | `processId`, `exitCode`, `signal` — always after that process's output |

## Host capabilities

`server.hello` returns `host` with `os` (`linux` / `macos`), `arch`
(`x86_64` / `aarch64`), `hostName`, `userName`, `homeDirectory`,
`defaultShell`, `pathSeparator`, `process.orphanProtection`
(`parentDeathSignal` / `serverShutdown`) and the sorted `features` list
(`filesystem`, `process`). Clients branch on these facts, never on `os`
alone, and check `features` before calling optional methods.

## Error codes

`PROTOCOL_MISMATCH`, `INVALID_REQUEST`, `UNKNOWN_METHOD`, `INVALID_PATH`,
`NOT_FOUND`, `PERMISSION_DENIED`, `ALREADY_EXISTS`, `NOT_A_DIRECTORY`,
`IS_A_DIRECTORY`, `DIRECTORY_NOT_EMPTY`, `CONFLICT`, `TOO_LARGE`,
`PROCESS_NOT_FOUND`, `SPAWN_FAILED`, `BUSY`, `UNSUPPORTED`, `IO`.
Clients additionally produce `TIMEOUT` and `DISCONNECTED` locally. Messages
are for people; OS error numbers stay in `details`.

## Compatibility

Incompatible changes increment the protocol version, which `server.hello`
rejects with `PROTOCOL_MISMATCH`. Additive fields and new methods keep the
version and are announced through `features`.

## Server identity

`lithe-remote-server --identity` prints one JSON line with `serverVersion`,
`protocolVersion` and `sha256` of the executable itself. Bootstrappers reuse an
installed server only when the hash matches the artifact they ship.
