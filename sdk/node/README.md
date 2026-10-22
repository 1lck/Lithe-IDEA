# Lithe plugin backend SDK for Node.js

`@lithe/plugin-sdk` is the official way to write a plugin backend in
JavaScript: the process a plugin starts through a `runtime` launch
(`{ "kind": "runtime", "tool": "node", … }`). It speaks the LSP base protocol
on stdio and implements Lithe's backend protocols from
[plugin contract v1](../../shared/contracts/plugins/v1/README.md):

- **`litheBuild` 1**: typed `lithe/build/model` and `lithe/build/dependencies`
  requests, for a build system whose `model` or `dependencies` source is
  `provider`.
- **`litheFunctions` 1**: plugin functions, which are plugin-private actions
  that Lithe invokes for the same plugin, with progress, cancellation, and
  registration at runtime.
- **`litheVcs` 1**: typed `lithe/vcs/*` requests, for a plugin's
  `vcsProviders` entry, from the
  [VCS provider contract](../../shared/contracts/vcs-provider-v1.md).

The SDK owns the wire format, negotiation, cancellation, process cleanup, and
error mapping. Your code supplies only handlers. Node 20.3 or newer is
required; declare it as the runtime's `minimumVersion`.

## A minimal backend

```js
import { createBackend, PluginError } from './vendor/lithe-plugin-sdk/src/index.mjs';

const backend = createBackend({ name: 'example-backend', version: '1.0.0' });

backend.build.model(async ({ root }) => ({
  buildSystemID: 'example',
  root,
  projects: [{ name: 'app', path: root }],
}));

backend.function('snapshot.refresh', async (params, context) => {
  context.progress({ message: 'Refreshing', percentage: 10 });
  const result = await context.run('example-tool', ['refresh'], { cwd: params.root });
  if (result.exitCode !== 0) throw new PluginError('example.refreshFailed', 'The refresh failed.');
  return { refreshedAt: Date.now() };
});

backend.listen();
```

[`examples/sample-build`](examples/sample-build) is a complete plugin with a
build provider, functions, persistent state, a function registered at runtime,
and cancellation. Rust Core's
`rust/lithe-core/tests/plugin_sdk_node.rs` drives it through a real Core
session.

## A VCS provider

```js
import { createBackend, PluginError, VCS_ERRORS } from './vendor/lithe-plugin-sdk/src/index.mjs';

createBackend({ name: 'example-vcs', version: '1.0.0' })
  .vcs('example', {
    status: async ({ root, tool }, context) => {
      if (!tool) throw new PluginError(VCS_ERRORS.toolUnavailable, 'The example client was not found.');
      const result = await context.run(tool.executable, ['status', '--json'], { cwd: root.path });
      return { changes: JSON.parse(result.stdout).changes };
    },
    baseContent: ({ path }) => ({ content: readBase(path), binary: false }),
    checkin: ({ paths, message }) => ({ revision: commit(paths, message) }),
    rollback: ({ paths }) => revert(paths),
  })
  .listen();
```

`backend.vcs(id, handlers, traits?)` names the VCS of the manifest's
`vcsProviders` entry and its handlers, keyed by operation: `status`,
`baseContent`, `checkin`, and `rollback` are required; `history`,
`fileHistory`, `annotate`, `update`, `fileOperation`, `resolve`, and
`cleanup` are optional. Each handler you declare negotiates its capability,
so the host offers only what you implement. `traits` describes the VCS
itself: `{ push: true }` when a check-in is local and publishing is a
separate step, `{ staging: true }` when changes have a staged dimension.
`git` is reserved for Lithe.

A handler receives the operation's arguments plus `root: { path }` and
`tool: { executable } | null` (the client the host resolved), and returns the
reply of the contract; returning nothing answers `{}`. Core validates every
reply, sorts paths, and refuses one that leaves the root. Throw
`PluginError` with a `VCS_ERRORS` code (`conflict`, `outOfDate`,
`authenticationFailed`, `workingCopyLocked`, `workingCopyUnsupported`,
`toolUnavailable`) so the host can explain the failure; other codes reach it
as `vcs.provider.failed`. A VCS handler's `context.run` also reports each
finished command (command line, exit code, duration, and at most 16 KiB of
stderr) as `lithe/vcs/execution` for the project console; pass
`{ report: false }` to skip one. Arguments are reported as given, so never
put a credential in them.

[`examples/sample-vcs`](examples/sample-vcs) is a complete provider for a
toy VCS that keeps revisions in a JSON file. Rust Core's
`rust/lithe-core/tests/plugin_sdk_node.rs` drives every operation through a
real Core session.

## Packaging

The SDK is not published to a registry yet. Copy `src/` into your plugin
package (for example as `backend/vendor/lithe-plugin-sdk/src/`) and import it
by relative path. A plugin package is installed read-only, has no
`node_modules` install step, and must run offline, so everything the backend
imports has to be inside the package. The SDK has no dependencies.

## API

| API | Purpose |
| --- | --- |
| `createBackend({ name?, version?, capabilities? })` | Creates the backend. `capabilities` are standard LSP server capabilities; `experimental.litheBuild`, `experimental.litheFunctions`, and `experimental.litheVcs` are reserved for the SDK. |
| `backend.build.model(handler)`, `backend.build.dependencies(handler)` | Implements the typed build requests. The SDK stamps `format` and `version`; a handler returning another format or a version other than 1 fails. Core validates the document. `litheBuild` is answered only when a handler exists. |
| `backend.vcs(id, handlers, traits?)` | Implements the typed VCS requests; see [A VCS provider](#a-vcs-provider). `litheVcs` is answered only when the host offers it. |
| `backend.function(id, handler)` | Declares a function offered in `initialize`. |
| `backend.registerFunction(id, handler)`, `backend.unregisterFunction(id)` | Adds or withdraws a function. Called before the `initialize` answer (for example from `onInitialize`), they change the initial list; later they send `lithe/function/register` / `unregister`. Withdrawing revokes running calls. |
| `backend.onInitialize(hook)`, `backend.onShutdown(hook)` | Lifecycle hooks. `onInitialize` receives the `initialize` params and what was negotiated. |
| `backend.onRequest(method, handler)`, `backend.onNotification(method, handler)` | Ordinary LSP methods, such as `textDocument/hover` for a language server. Lifecycle and `lithe/*` methods are reserved. |
| `backend.sendRequest`, `backend.sendNotification` | Ordinary LSP messages to the host; `lithe/*` methods are reserved. |
| `backend.log(...)` | Writes a line to stderr, which the host keeps in its log. |
| `backend.listen()` | Serves stdio until `exit` or the end of input. |
| `PluginError(code, message)` | A failure meant for your own UI, or with a `VCS_ERRORS` code, for the host's. |
| `runProcess(command, args, options)` | Runs a process without a shell, as one cancellable process tree. |
| `openStateStore(directory)` | A small atomic JSON store in a host-provided directory. |

Every handler receives a context:

| Member | Meaning |
| --- | --- |
| `signal` | Aborted when Lithe cancels the call, its deadline passes, the function is withdrawn, or the session ends; also once the handler has settled, so work it left running stops. |
| `throwIfCancelled()` | Throws the cancellation if `signal` is aborted. |
| `run(command, args, options)` | `runProcess` bound to the call: cancelling or ending the call ends the whole process tree. In VCS handlers it also reports the finished command unless `options.report` is `false`. |
| `log(...)` | Same as `backend.log`. |
| `functionID`, `operationID` | Functions only. `operationID` is opaque; never derive anything from it. |
| `progress({ message?, percentage? })` | Functions only. The message is cut to 1024 bytes and the percentage clamped to 0–100; reports after the call ends are dropped. |

## Results and errors

| Handler outcome | What Lithe sees |
| --- | --- |
| Returns a value (including `null`) | `result.value` |
| Throws `PluginError(code, message)` | `plugin.function.failed` with your `message` and `pluginErrorCode`. The code is for your plugin's own UI; Lithe never branches on it. |
| Throws anything else | `plugin.function.failed` with a generic message, so paths and stack traces never reach the UI. The real error goes to stderr. |
| Ends because of `signal` | `requestCancelled` (or Lithe's timeout/revocation outcome) |

A result must serialize to at most 1 MiB of JSON. A value JSON cannot encode
(a `BigInt`, a cycle) or a larger one fails like any other unexpected error and
is logged to stderr; the session keeps running. A function ID is dot-separated
lowerCamelCase segments (`snapshot.refresh`), at most 128 bytes, and a session
holds at most 256 functions. A `PluginError` code matches
`[A-Za-z][A-Za-z0-9._-]*`, at most 64 bytes.

## Rules that keep Lithe in charge

The SDK leaves your plugin free to define its own functions, params, results,
UI, and state, but these rules keep Lithe's workflows, permissions, and
lifecycle unified. The SDK enforces the ones it can.

1. **Domain capabilities stay typed.** Build models and dependency trees go
   through `backend.build.*`, and version control through `backend.vcs`,
   never through a function, so every host and IDE workflow reads one
   contract. Functions are for actions only your plugin understands.
2. **No calls back into Lithe's dispatch.** A backend never sends
   `lithe/function/invoke` or `lithe/build/*`; Lithe would route it back to the
   same process, which would then wait for itself. Lithe refuses these with
   `plugin.function.recursiveCall`, and the SDK refuses to send any `lithe/*`
   method. The only `lithe/vcs/*` message a provider sends is the execution
   report, which `context.run` writes for you.
3. **stdout belongs to the protocol.** When serving stdio, the SDK moves
   `console.log`, `console.info`, and `console.debug` to stderr. Never write to
   `process.stdout` yourself.
4. **The package is read-only.** Keep caches, snapshots, and logs under the
   directories Lithe passes through launch templates (`${stateDir}`,
   `${workspaceStateDir}`). `openStateStore` refuses any directory inside the
   plugin package. Writing to the package breaks code signing and update
   deltas.
5. **Work ends with its call.** Start processes with `context.run`, and check
   `signal` in long loops. On cancellation the SDK stops the process tree
   politely, then forcibly. When the handler returns or throws, tools of that
   call still running (an unawaited `context.run`, the siblings of a failed
   `Promise.all`) are stopped the same way. A tool that exits on its own takes
   the workers it left in its process group with it. On `shutdown`, `exit`, or
   the end of input the SDK ends every process it started. If the backend
   itself is killed, no JavaScript runs; ending what it left is the host's
   job, not the SDK's. Lithe finds those processes by the markers it puts in
   the backend's environment, so `runProcess` carries them over even when
   `env` replaces the environment.
6. **Errors stay presentable.** Throw `PluginError` for failures the user
   should see; every other exception is reported generically.

## Testing

```bash
npm test --prefix sdk/node
```

The tests use a bounded in-memory host (`test/harness.mjs`), which plugin
authors can copy to test their own backends without starting Lithe.
