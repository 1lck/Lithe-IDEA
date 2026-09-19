// Entry point of the Lithe VS Code extension host process.
//
// stdout carries the Lithe protocol and nothing else. It is captured before any
// Theia or extension code loads; afterwards every other stdout write, including
// Theia's `console` routing and extensions writing to `process.stdout`, is
// redirected to stderr, which Lithe records as the host log.
const writeProtocolLine = process.stdout.write.bind(process.stdout);
const writeDiagnostics = process.stderr.write.bind(process.stderr);
process.stdout.write = ((chunk: string | Uint8Array, ...rest: unknown[]) =>
    (writeDiagnostics as (chunk: string | Uint8Array, ...args: unknown[]) => boolean)(chunk, ...rest)) as typeof process.stdout.write;

const diagnostics = (message: string): void => {
    writeDiagnostics(`[lithe-extension-host] ${message}\n`);
};

// Extensions share this process; they must not be able to end it. Theia's own
// plugin host applies the same guard.
const exitProcess = process.exit.bind(process);
process.exit = ((code?: number) => {
    diagnostics(`Ignored process.exit(${code ?? ''}) called by extension code.`);
}) as typeof process.exit;
// Installed before any extension code can start a child process.
const { ChildProcessTracker } = require('./child-process-tracker') as typeof import('./child-process-tracker');
const childProcesses = new ChildProcessTracker();
childProcesses.install();

process.on('uncaughtException', error => diagnostics(`Uncaught exception in extension code: ${error.stack ?? error.message}`));
process.on('unhandledRejection', reason => diagnostics(`Unhandled rejection in extension code: ${reason instanceof Error ? reason.stack : String(reason)}`));

/* eslint-disable @typescript-eslint/no-require-imports */
// Loaded after the guards above so no Theia module observes the original stdout.
require('@theia/core/shared/reflect-metadata');
const { suppressNodeNavigator } = require('@theia/plugin-ext/lib/hosted/node/plugin-host-navigator-override') as
    typeof import('@theia/plugin-ext/lib/hosted/node/plugin-host-navigator-override');
const { MsgPackExtensionManager } = require('@theia/core/lib/common/message-rpc/msg-pack-extension-manager') as
    typeof import('@theia/core/lib/common/message-rpc/msg-pack-extension-manager');
// The package entry registers Theia's MsgPack extensions (Uri, Range, ...) exactly once.
require('@theia/plugin-ext');
const { URI: PluginUri } = require('@theia/plugin-ext/lib/plugin/types-impl') as typeof import('@theia/plugin-ext/lib/plugin/types-impl');
const { URI: VSCodeURI } = require('@theia/core/shared/vscode-uri') as typeof import('@theia/core/shared/vscode-uri');
const { LitheConnection } = require('./lithe-connection') as typeof import('./lithe-connection');
const { ExtensionHost } = require('./extension-host') as typeof import('./extension-host');
/* eslint-enable @typescript-eslint/no-require-imports */

suppressNodeNavigator();

// Same as Theia's plugin host: URIs crossing the RPC must deserialize into the
// extension API's `Uri` class so `instanceof vscode.Uri` holds inside extensions.
// `MsgPackExtensionTag` is a const enum with no runtime value; 4 is `VsCodeUri` in Theia 1.75.0.
const VS_CODE_URI_MSGPACK_TAG = 4;
const uriExtension = MsgPackExtensionManager.getInstance().getExtension(VS_CODE_URI_MSGPACK_TAG);
if (uriExtension?.class === VSCodeURI) {
    uriExtension.deserialize = (data: string) => PluginUri.parse(data);
}

const connection = new LitheConnection(line => writeProtocolLine(line), diagnostics);
new ExtensionHost(connection, diagnostics, childProcesses, code => exitProcess(code));

process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk: string) => connection.receive(chunk));
process.stdin.on('end', () => connection.close());
