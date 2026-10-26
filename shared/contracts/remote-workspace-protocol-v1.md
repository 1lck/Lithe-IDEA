# Remote workspace protocol v1

The protocol between a Lithe client and `lithe-remote-server`, which runs at
the end of a transport chain (SSH host, container, or a chain of both). The
Rust types in `rust/lithe-remote-protocol/` are the reference
implementation; this document is the compatibility surface for other
clients. Design rationale lives in
`.agents/notes/proposed/architecture/2026-10-24-remote-development-workspace-host.md`.

## Starting the server

| Command | Session |
| --- | --- |
| `lithe-remote-server --stdio` | Ends with the connection, terminating everything it started. |
| `lithe-remote-server --connect <key> [--state-dir <dir>]` | Persistent: relays to the daemon of session `<key>`, starting it if needed. |

`<key>` is 1–64 characters from `[A-Za-z0-9._-]`. The daemon keeps its
socket, lock and log under `<dir>` (default `$HOME/.lithe-server`) in
directories only the user can access, and rejects peers with another user
id. A session has one client at a time: a new connection replaces the
current one. A session without a client ends after its idle timeout.

## Stream

1. The server writes the preamble `\nLITHE-REMOTE-PROTOCOL/1\n` once per
   connection. Clients discard up to 64 KiB of bytes before it (shell
   banners) and report them as diagnostics when the preamble never arrives.
2. Every following unit is a frame: a 4-byte big-endian length and that many
   bytes of UTF-8 JSON. Frames larger than 16 MiB are rejected.
3. Closing the client-to-server stream is a disconnect.

The server never listens on a network port; all traffic, including tunnels,
uses this stream.

## Messages

```json
{"type": "request", "id": 1, "method": "fs.stat", "params": {"path": "/srv"}}
{"type": "response", "id": 1, "result": {"kind": "directory", "size": 4096, "modifiedMs": 1761300000000, "readonly": false, "mode": 493}}
{"type": "response", "id": 2, "error": {"code": "NOT_FOUND", "message": "…", "details": {"path": "/x", "osError": 2}}}
{"type": "event", "event": "process.exit", "params": {"processId": 1, "exitCode": 0, "signal": null}, "seq": 42}
```

- Request `id`s are chosen by the client and unique per connection.
  Responses may arrive in any order. A client that stops waiting discards a
  late response.
- The first request must be `server.hello`; anything earlier fails with
  `INVALID_REQUEST`. Events reach a connection only after it calls
  `server.resume`, once.
- Every event carries `seq`, increasing by one per event in the session.
- Field names are camelCase. Byte payloads (`data`) are standard Base64.
- Paths are absolute paths on the remote host. Relative paths fail with
  `INVALID_PATH`.
- Requests that change a running resource in order — `process.writeStdin`,
  `process.closeStdin`, `process.kill`, `terminal.write`, `terminal.resize`,
  `terminal.close`, `tunnel.write`, `tunnel.close`, `watch.stop`,
  `walk.cancel` — are applied in the order sent. Other requests may complete
  in any order.

## Resources and events

Processes, terminals, watches, tunnels and walks are identified by ids the
**client** chooses, unique within the session across reconnections (start
from `session.nextResourceId` in the hello result). Reusing the id of a live
resource fails with `RESOURCE_ID_IN_USE`; an unknown id fails with
`UNKNOWN_RESOURCE`.

Every event is named `<family>.<name>` and carries `<family>Id`, so a client
can route `terminal.output` with `terminalId: 7` to terminal 7, and can
subscribe before creating the resource.

## Methods

| Method | Params | Result |
| --- | --- | --- |
| `server.hello` | `protocolVersion`, `clientName`, `idleTimeoutSeconds?` | `protocolVersion`, `serverVersion`, `host`, `session` |
| `server.resume` | `afterSeq?` | `truncated`; then every kept event after `afterSeq`, followed by live events |
| `server.ack` | `seq` | `null`; events up to `seq` may be forgotten |
| `server.shutdown` | — | `null`; the session ends |
| `server.ping` | — | `{}` |
| `server.state` | — | running `processes`, `terminals`, `watches` |
| `fs.stat` | `path` | metadata of the path itself (links not followed) |
| `fs.readDir` | `path` | `entries` sorted by name byte order, `skippedNonUtf8` |
| `fs.readFile` | `path`, `offset`, `length` (≤ 8 MiB) | `data`, `eof`, `metadata` |
| `fs.writeFile` | `path`, `data` (≤ 8 MiB), `expected?`, `overwrite`, `createParents` | metadata after the write |
| `fs.createDir` | `path`, `recursive`, `mode?` (at most `0o7777`) | `null` |
| `fs.remove` | `path`, `recursive` | `null`; links are removed, never followed |
| `fs.rename` | `from`, `to`, `overwrite` | `null` |
| `fs.copy` | `from`, `to`, `recursive`, `overwrite` | `skippedSpecialFiles`; links are copied as links |
| `fs.trash` | `path` | `null`; moves the entry to the host account's recoverable system trash |
| `fs.realPath` | `path` | `path` with links resolved |
| `fs.setPermissions` | `path`, `mode` (≤ `0o7777`) | `null` |
| `fs.volumeInfo` | `path` | `caseSensitive` (`null` when unknown) |
| `fs.uploadStart` | `path`, `size`, `sha256`, `mode` | `uploadId` |
| `fs.uploadChunk` | `uploadId`, `offset`, `data` | next `offset` |
| `fs.uploadCommit` | `uploadId` | verified `size`, `sha256` |
| `fs.uploadAbort` | `uploadId` | `null` |
| `walk.start` | `walkId`, `root`, `excludeNames`, `maxEntries?` | `null`; entries follow as events |
| `walk.cancel` | `walkId` | `null` |
| `watch.start` | `watchId`, `root`, `excludeNames` | `watchedDirectories` (per-directory backends) |
| `watch.stop` | `watchId` | `null` |
| `process.spawn` | `processId`, `argv`, `cwd?`, `environment` (`server` / `login`), `env`, `pipeStdin` | `pid` |
| `process.writeStdin` | `processId`, `data` | `null`; `BUSY` when the process stops reading |
| `process.closeStdin` | `processId` | `null` |
| `process.kill` | `processId`, `force` | `null`; signals every process of its session, also after `process.exit` while members run; `UNKNOWN_RESOURCE` once the session is empty |
| `terminal.open` | `terminalId`, `argv?`, `cwd?`, `env`, `columns`, `rows` | `pid`; default program is the login shell |
| `terminal.write` | `terminalId`, `data` | `null`; `BUSY` when not read |
| `terminal.resize` | `terminalId`, `columns`, `rows` | `null` |
| `terminal.close` | `terminalId` | `null`; `SIGHUP` to its session, `SIGKILL` after 2 s |
| `environment.resolve` | `refresh` | `environment`, `source`, `diagnostics?` |
| `tunnel.open` | `tunnelId`, `target` (`{kind: tcp, host, port}` / `{kind: unix, path}`) | `null`; `CONNECT_FAILED` on failure |
| `tunnel.write` | `tunnelId`, `data` | `null`; `BUSY` when the peer stops reading |
| `tunnel.shutdownWrite` | `tunnelId` | `null`; queued data is sent, then the write side is shut down; replies keep arriving |
| `tunnel.close` | `tunnelId` | `null`; aborts both directions, queued data is discarded |
| `ports.listening` | — | sorted `ports` (`address`, `port`) |

`fs.copy` refuses, with `INVALID_REQUEST`, to copy a file onto itself —
directly, through a symbolic link in either direction or onto a hard link —
and to copy a directory into itself after resolving links. Sockets, FIFOs and
devices are never copied: at the top level the request fails with
`UNSUPPORTED`, inside a tree they are skipped and counted.
With `overwrite: false`, a private sibling staging directory holds the copy
until an atomic no-replace rename publishes it. A concurrent destination
creation fails with `ALREADY_EXISTS` and leaves that destination unchanged.

`fs.trash` uses the host's native trash implementation (Freedesktop Trash on
Linux and the system Trash on macOS). Recovery content and metadata belong to
the remote account, never to the client placeholder or installation. A host
without usable trash storage returns an error and retains the original entry;
it does not fall back to permanent deletion.

`fs.writeFile` replaces the file atomically through a temporary sibling and
writes through symbolic links. With `expected` (`size`, `modifiedMs`) it fails
with `CONFLICT` unless the file still matches; without it, an existing file is
only replaced when `overwrite` is set. A write with neither `expected` nor
`overwrite` only creates: when two such writes race, exactly one succeeds and
the other fails with `ALREADY_EXISTS`. When a file is replaced, the temporary
file never has broader permissions than the original.

Hosts advertising `features: ["upload", ...]` accept staged uploads without
increasing the frame limit. Upload IDs are server-assigned and owned by the
connection that created them, including in a persistent session. At most four
uploads are staged per server; each file is at most 2 GiB. Chunks contain
1–256 KiB of decoded bytes and must name the exact acknowledged offset.
`sha256` is a 64-character hexadecimal digest; `mode` permits only `0o000`–`0o777`.
Staging uses a private `0600` sibling file. Commit verifies size and digest,
syncs the file and atomically publishes without replacing an existing target.
Failed commits, aborts, disconnects, session shutdown and an absolute five-minute
expiry remove staging files. Clients serialize chunks and commit only after
the last acknowledgement. Interrupted clients may not know whether a completed
commit published; owners must remove their allocated run directory separately.

`process.exit` and `terminal.exit` report the leader. The server keeps owning
its session until no member is left, so members that outlive the leader can
still be killed and are cleaned up when the session ends; `server.state`
marks such processes with `leaderExited`.

When a session ends, the server terminates everything it still owns
(`SIGTERM` or `SIGHUP`, then `SIGKILL` after 2 seconds to sessions that still
have members), lets running requests finish for up to 5 seconds, and exits.

`environment.resolve` asks the user's login shell, interactive first, for its
environment and caches it for the session. `process.spawn` with
`environment: login` uses that environment as the base.

## Events

| Event | Params |
| --- | --- |
| `process.output` | `processId`, `stream` (`stdout` / `stderr`), `data` |
| `process.exit` | `processId`, `exitCode`, `signal` — always after that process's output |
| `terminal.output` | `terminalId`, `data` |
| `terminal.exit` | `terminalId`, `exitCode`, `signal` — always after that terminal's output |
| `watch.changed` | `watchId`, `changes` (`path`, `kind`: `created` / `modified` / `deleted`), `overflow` |
| `watch.error` | `watchId`, `code` (`LIMIT_REACHED` / `ROOT_REMOVED`), `message` |
| `walk.entries` | `walkId`, `entries` (`path` relative with `/`, `kind`) |
| `walk.done` | `walkId`, `total`, `truncated`, `cancelled`, `skippedNonUtf8`, `unreadableDirectories` |
| `tunnel.data` | `tunnelId`, `data` |
| `tunnel.closed` | `tunnelId`, `error?` — the last event of the tunnel |

`watch.changed` batches are coalesced and sorted by path. With `overflow`
changes were lost and the client must rescan the watched tree.

## Event delivery and persistent sessions

`server.hello` returns `session` with `persistent`, `resumed`,
`nextResourceId` and `lastEventSeq`. The session keeps every event until the
client acknowledges it with `server.ack` (clients acknowledge periodically,
for example every 256 events), up to 8 MiB; beyond that the oldest kept
events are dropped. Written to a socket is not received: when a connection
dies, events may still sit in its outbox or in kernel buffers, so they stay
kept until acknowledged.

`server.resume` with `afterSeq` — the last `seq` the client received on an
earlier connection — sends every kept event after it, then live events, so
each event arrives exactly once. A reconnecting client first calls
`server.state` and subscribes to the resources it reattaches to, then
resumes, so their missed events reach those subscriptions. `truncated` means
events after `afterSeq` were dropped; the client re-reads state and rescans
watches.

While no client is attached, a persistent session keeps processes, terminals
and watches running. Tunnels and walks belong to the connection that opened
them and end with it. After `server.shutdown` a persistent session is no
longer reachable, even while it is still terminating its processes; the next
connection with the same key starts a fresh session.

## Host capabilities

`server.hello` returns `host` with `os` (`linux` / `macos`), `arch`
(`x86_64` / `aarch64`), `hostName`, `userName`, `homeDirectory`,
`defaultShell`, `pathSeparator`, `process.orphanProtection`
(`parentDeathSignal` / `serverShutdown`), `watch.backend`
(`inotify` / `fsevents`), `watch.directoryLimit` and the sorted `features`
list. Clients branch on these facts, never on `os` alone, and check
`features` before calling optional methods.

## Error codes

`PROTOCOL_MISMATCH`, `INVALID_REQUEST`, `UNKNOWN_METHOD`, `INVALID_PATH`,
`NOT_FOUND`, `PERMISSION_DENIED`, `ALREADY_EXISTS`, `NOT_A_DIRECTORY`,
`IS_A_DIRECTORY`, `DIRECTORY_NOT_EMPTY`, `CONFLICT`, `TOO_LARGE`,
`UNKNOWN_RESOURCE`, `RESOURCE_ID_IN_USE`, `SPAWN_FAILED`, `CONNECT_FAILED`,
`BUSY`, `UNSUPPORTED`, `IO`. Clients additionally produce `TIMEOUT` and
`DISCONNECTED` locally. Messages are for people; OS error numbers stay in
`details`.

## Compatibility

Incompatible changes increment the protocol version, which `server.hello`
rejects with `PROTOCOL_MISMATCH`. Additive fields and new methods keep the
version and are announced through `features`. The daemon's socket name
includes the server version, so a client upgrade starts a new daemon rather
than reaching an older one.

## Server identity

`lithe-remote-server --identity` prints one JSON line with `serverVersion`,
`protocolVersion` and `sha256` of the executable itself. Bootstrappers reuse an
installed server only when the hash matches the artifact they ship.
