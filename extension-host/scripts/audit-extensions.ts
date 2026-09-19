// Development tool: loads real, unmodified extensions into the host and records
// which VS Code APIs they reach that Lithe does not implement yet.
//
//   bun run build
//   bun scripts/audit-extensions.ts --workspace <dir> --open <relative file> \
//       --event workspaceContains:pom.xml --event onLanguage:java \
//       --config 'java.configuration.runtimes=[{"name":"JavaSE-21","path":"/jdk","default":true}]' \
//       --observe-seconds 60 <extension dir>...
//
// The report goes to stdout as JSON; the host's stderr goes to --host-log.
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { pathToFileURL } from 'url';
import { FakeLithe } from '../test/support/fake-lithe';

interface Options {
    workspace: string;
    open: string[];
    events: string[];
    commands: string[];
    observeSeconds: number;
    hostLog: string | null;
    configuration: Record<string, unknown>;
    extensions: string[];
}

function parseArguments(argv: string[]): Options {
    const options: Options = { workspace: '', open: [], events: [], commands: [], observeSeconds: 30, hostLog: null, configuration: {}, extensions: [] };
    for (let index = 0; index < argv.length; index++) {
        const argument = argv[index];
        const value = () => argv[++index] ?? '';
        switch (argument) {
            case '--workspace': options.workspace = path.resolve(value()); break;
            case '--open': options.open.push(value()); break;
            case '--event': options.events.push(value()); break;
            case '--command': options.commands.push(value()); break;
            case '--observe-seconds': options.observeSeconds = Number(value()); break;
            case '--host-log': options.hostLog = path.resolve(value()); break;
            case '--config': {
                // --config key=<JSON value>, delivered as user configuration like Lithe settings would be.
                const [key, ...rest] = value().split('=');
                options.configuration[key] = JSON.parse(rest.join('='));
                break;
            }
            default: options.extensions.push(path.resolve(argument));
        }
    }
    if (!options.workspace || options.extensions.length === 0) {
        throw new Error('Usage: audit-extensions.ts --workspace <dir> [--open file] [--event e] [--command c] <extension dir>...');
    }
    return options;
}

async function main(): Promise<void> {
    const options = parseArguments(process.argv.slice(2));
    const lithe = FakeLithe.launch(fs.mkdtempSync(path.join(os.tmpdir(), 'lithe-extension-audit-')));
    const outcomes: { step: string; outcome: string }[] = [];
    const record = async (step: string, action: () => Promise<unknown>) => {
        try {
            const result = await action();
            outcomes.push({ step, outcome: `ok ${JSON.stringify(result)?.slice(0, 200) ?? ''}` });
        } catch (error) {
            outcomes.push({ step, outcome: `failed ${error instanceof Error ? error.message.split('\n')[0] : String(error)}` });
        }
    };
    try {
        const initialize = await lithe.request('host/initialize', {
            ...lithe.initializeParams(),
            workspaceFolders: [{ uri: pathToFileURL(options.workspace).toString(), name: path.basename(options.workspace) }],
            extensionPaths: options.extensions,
            configuration: { user: options.configuration },
            workspaceTrusted: true,
            commands: [],
        }, 60_000);
        for (const event of ['*', ...options.events, 'onStartupFinished']) {
            await record(`activate ${event}`, () => lithe.request('host/activateByEvent', { event }, 120_000));
        }
        for (const relative of options.open) {
            const file = path.join(options.workspace, relative);
            lithe.openDocument(pathToFileURL(file).toString(), fs.readFileSync(file, 'utf8'));
            await record(`activate onLanguage:java for ${relative}`, () => lithe.request('host/activateByEvent', { event: 'onLanguage:java' }, 120_000));
        }
        for (const command of options.commands) {
            await record(`execute ${command}`, () => lithe.request('host/executeCommand', { command, arguments: [] }, 120_000));
        }
        // Language servers keep calling the host after activation; watch for a bounded window.
        await lithe.waitForNotification(() => false, 'the observation window', options.observeSeconds * 1000).catch(() => undefined);
        await record('shutdown', () => lithe.request('host/shutdown', { timeoutMilliseconds: 10_000 }, 20_000));
        await lithe.waitForExit(20_000).catch(() => undefined);

        const unsupported = new Map<string, number>();
        for (const entry of lithe.notifications.filter(entry => entry.method === 'lithe/unsupportedApi')) {
            unsupported.set(entry.params.api, (unsupported.get(entry.params.api) ?? 0) + 1);
        }
        const report = {
            apiVersion: initialize.apiVersion,
            extensions: initialize.extensions.map((extension: { id: string; version: string }) => `${extension.id}@${extension.version}`),
            failedExtensions: initialize.failedExtensions,
            steps: outcomes,
            unsupportedApis: [...unsupported.keys()].sort(),
            litheRequests: [...new Set(lithe.receivedRequests.map(entry => entry.method === 'lithe/executeCommand'
                ? `lithe/executeCommand ${entry.params.command}` : entry.method))].sort(),
            messages: lithe.receivedRequests.filter(entry => entry.method === 'lithe/showMessage')
                .map(entry => `${entry.params.severity}: ${String(entry.params.message).slice(0, 400)}`),
            registeredCommands: lithe.notifications.filter(entry => entry.method === 'lithe/commandRegistered').length,
            progressTitles: [...new Set(lithe.notifications.filter(entry => entry.method === 'lithe/progress' && entry.params.title)
                .map(entry => entry.params.title as string))].sort(),
            errorLogs: lithe.notifications.filter(entry => entry.method === 'lithe/log' && entry.params.level === 'error')
                .map(entry => String(entry.params.message).split('\n')[0].slice(0, 240)),
        };
        process.stdout.write(JSON.stringify(report, undefined, 2) + '\n');
    } finally {
        if (options.hostLog) {
            fs.writeFileSync(options.hostLog, lithe.stderr + '\n--- lithe/log ---\n' + lithe.notifications
                .filter(entry => entry.method === 'lithe/log').map(entry => `[${entry.params.level}] ${entry.params.message}`).join('\n'));
        }
        await lithe.dispose();
    }
}

main().catch(error => {
    process.stderr.write(`${error instanceof Error ? error.stack : String(error)}\n`);
    process.exitCode = 1;
});
