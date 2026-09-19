// End-to-end tests of the extension host process against a fake Lithe peer.
//
// Each test launches the built host under Node, loads the unmodified-API probe
// extension and drives it only through the Lithe protocol. The fake Lithe owns
// document content, as the real product does.
import { afterEach, describe, expect, test } from 'bun:test';
import * as fs from 'fs';
import { FakeLithe, HostRequestError } from './support/fake-lithe';

const TEST_TIMEOUT_MILLISECONDS = 30_000;
const launched: FakeLithe[] = [];

function launch(directory?: string): FakeLithe {
    const lithe = FakeLithe.launch(directory);
    launched.push(lithe);
    return lithe;
}

async function launchInitialized(directory?: string): Promise<FakeLithe> {
    const lithe = launch(directory);
    await lithe.request('host/initialize', lithe.initializeParams());
    return lithe;
}

function isProcessRunning(pid: number): boolean {
    try {
        process.kill(pid, 0);
        return true;
    } catch {
        return false;
    }
}

async function expectHostError(promise: Promise<unknown>, code: string): Promise<HostRequestError> {
    const error = await promise.then(() => undefined, failure => failure);
    expect(error).toBeInstanceOf(HostRequestError);
    expect((error as HostRequestError).code).toBe(code);
    return error as HostRequestError;
}

afterEach(async () => {
    await Promise.all(launched.splice(0).map(lithe => lithe.dispose()));
});

describe('initialize', () => {
    test('reports the scanned extension with inferred activation events', async () => {
        const lithe = launch();
        const result = await lithe.request('host/initialize', lithe.initializeParams({
            extensionPaths: [lithe.workspaceDirectory, ...(lithe.initializeParams().extensionPaths as string[])],
        }));

        expect(result.protocolVersion).toBe(1);
        expect(result.apiVersion).toMatch(/^\d+\.\d+\.\d+$/);
        expect(result.extensions).toEqual([{
            id: 'lithe-test.lithe-probe',
            version: '0.0.1',
            displayName: 'Lithe Probe',
            activationEvents: ['onCommand:litheProbe.editAndSave'],
            commands: [{ command: 'litheProbe.editAndSave', title: 'Edit and save through Lithe' }],
        }]);
        // The workspace directory has no package.json: it is reported, not fatal.
        expect(result.failedExtensions).toHaveLength(1);
        expect(result.failedExtensions[0].path).toBe(lithe.workspaceDirectory);
    }, TEST_TIMEOUT_MILLISECONDS);

    test('rejects work before initialize and a second initialize', async () => {
        const lithe = launch();
        await expectHostError(lithe.request('host/activateByEvent', { event: '*' }), 'notInitialized');
        await expectHostError(lithe.request('host/initialize', { protocolVersion: 99 }), 'invalidParams');
        await lithe.request('host/initialize', lithe.initializeParams());
        await expectHostError(lithe.request('host/initialize', lithe.initializeParams()), 'alreadyInitialized');
    }, TEST_TIMEOUT_MILLISECONDS);

    test('exposes workspace folders and configuration from initialize', async () => {
        const lithe = launch();
        await lithe.request('host/initialize', lithe.initializeParams({
            configuration: { defaults: { 'java.home': null }, user: { 'java.home': '/jdk/user' }, workspace: { 'probe.flag': true } },
        }));
        await lithe.request('host/activateByEvent', { event: 'onCommand:litheProbe.editAndSave' });

        const folders = await lithe.request('host/executeCommand', { command: 'litheProbe.workspaceFolders', arguments: [] });
        expect(folders).toEqual([{ uri: lithe.uriOf('').replace(/\/$/, ''), name: 'workspace' }]);
        expect(await lithe.request('host/executeCommand', { command: 'litheProbe.configuration', arguments: ['java.home'] })).toBe('/jdk/user');
        expect(await lithe.request('host/executeCommand', { command: 'litheProbe.configuration', arguments: ['probe.flag'] })).toBe(true);
    }, TEST_TIMEOUT_MILLISECONDS);

    test('extension-contributed defaults sit below Lithe defaults and user settings', async () => {
        const lithe = launch();
        await lithe.request('host/initialize', lithe.initializeParams({
            configuration: { defaults: { 'litheProbe.nested.limit': 5 }, user: { 'litheProbe.greeting': 'hi from user' } },
        }));
        await lithe.request('host/activateByEvent', { event: 'onCommand:litheProbe.editAndSave' });

        expect(await lithe.request('host/executeCommand', { command: 'litheProbe.configuration', arguments: ['litheProbe'] }))
            .toEqual({ greeting: 'hi from user', nested: { limit: 5 } });
    }, TEST_TIMEOUT_MILLISECONDS);

    test('workspace trust is decided by Lithe and defaults to untrusted', async () => {
        const untrusted = await launchInitialized();
        const trusted = launch();
        await trusted.request('host/initialize', trusted.initializeParams({ workspaceTrusted: true }));
        for (const lithe of [untrusted, trusted]) {
            await lithe.request('host/activateByEvent', { event: 'onCommand:litheProbe.editAndSave' });
        }

        expect(await untrusted.request('host/executeCommand', { command: 'litheProbe.isTrusted', arguments: [] })).toBe(false);
        expect(await trusted.request('host/executeCommand', { command: 'litheProbe.isTrusted', arguments: [] })).toBe(true);
    }, TEST_TIMEOUT_MILLISECONDS);
});

describe('commands', () => {
    test('executing a contributed command activates its extension first', async () => {
        const lithe = await launchInitialized();
        const uri = lithe.uriOf('A.java');
        lithe.documents.set(uri, { languageId: 'java', version: 1, text: 'class A {}\n', isDirty: false });
        lithe.litheCommands.set('lithe.echo', args => ({ echoed: args }));

        const result = await lithe.request('host/executeCommand', { command: 'litheProbe.editAndSave', arguments: [{ $uri: uri }] });

        expect(result.argumentIsUri).toBe(true);
        expect(result.echoed).toEqual({ echoed: [{ $uri: uri }] });
        // Commands declared in package.json are already in the initialize summary; only
        // commands an extension registers without declaring them are announced at runtime.
        const registered = lithe.notifications.filter(entry => entry.method === 'lithe/commandRegistered').map(entry => entry.params.command);
        expect(registered).toContain('litheProbe.events');
        expect(registered).not.toContain('litheProbe.editAndSave');
    }, TEST_TIMEOUT_MILLISECONDS);

    test('unknown, failing and Lithe-owned commands produce distinct outcomes', async () => {
        const lithe = await launchInitialized();
        await lithe.request('host/activateByEvent', { event: 'onCommand:litheProbe.editAndSave' });

        await expectHostError(lithe.request('host/executeCommand', { command: 'missing.command', arguments: [] }), 'commandNotFound');
        const failure = await expectHostError(lithe.request('host/executeCommand', { command: 'litheProbe.fail', arguments: [] }), 'commandFailed');
        expect(failure.message).toContain('probe failure');

        // Extension -> Lithe: a command Lithe does not own is an error inside the extension.
        const callMissing = lithe.request('host/executeCommand', { command: 'litheProbe.callLithe', arguments: ['lithe.missing'] });
        const nested = await expectHostError(callMissing, 'commandFailed');
        expect(nested.message).toContain('lithe.missing');

        // getCommands() lists Lithe's declared commands and every extension handler.
        expect(await lithe.request('host/executeCommand', { command: 'litheProbe.availableCommands', arguments: [] }))
            .toEqual(['lithe.echo', 'litheProbe.events']);
    }, TEST_TIMEOUT_MILLISECONDS);

    test('a cancelled request is answered with cancelled and its late result is dropped', async () => {
        const lithe = await launchInitialized();
        await lithe.request('host/activateByEvent', { event: 'onCommand:litheProbe.editAndSave' });
        let release: ((value: string) => void) | undefined;
        lithe.litheCommands.set('lithe.block', () => new Promise<string>(resolve => { release = resolve; }));
        lithe.litheCommands.set('lithe.report', () => null);

        const cancelled = lithe.requestAndCancel('host/executeCommand', { command: 'litheProbe.callLitheThenReport', arguments: ['lithe.block'] });
        await expectHostError(cancelled, 'cancelled');
        await lithe.waitForRequest(entry => entry.params?.command === 'lithe.block', 'the extension to call the blocking Lithe command');
        release?.('late');
        await lithe.waitForRequest(entry => entry.params?.command === 'lithe.report', 'the extension to finish after cancellation');

        // A later round trip through the plugin side is queued behind the late result.
        expect(await lithe.request('host/executeCommand', { command: 'litheProbe.availableCommands', arguments: [] }))
            .toEqual(['lithe.echo', 'litheProbe.events']);
        expect(lithe.unexpectedResponses).toEqual([]);
    }, TEST_TIMEOUT_MILLISECONDS);
});

describe('documents owned by Lithe', () => {
    test('an extension edit round-trips through Lithe before applyEdit resolves', async () => {
        const lithe = await launchInitialized();
        const uri = lithe.uriOf('A.java');
        lithe.documents.set(uri, { languageId: 'java', version: 1, text: 'class A {}\n', isDirty: false });
        lithe.litheCommands.set('lithe.echo', () => 'ok');

        const result = await lithe.request('host/executeCommand', { command: 'litheProbe.editAndSave', arguments: [{ $uri: uri }] });

        expect(result.before).toEqual({ text: 'class A {}\n', version: 1 });
        expect(result.applied).toBe(true);
        expect(result.afterEdit).toEqual({ text: '// edited by extension\nclass A {}\n', version: 2, isDirty: true });
        expect(result.saved).toBe(true);
        expect(result.isDirtyAfterSave).toBe(false);
        expect(lithe.documents.get(uri)).toEqual({ languageId: 'java', version: 2, text: '// edited by extension\nclass A {}\n', isDirty: false });
        const edit = lithe.receivedRequests.find(entry => entry.method === 'lithe/applyWorkspaceEdit');
        expect(edit?.params.edits).toEqual([{
            uri,
            range: { startLine: 1, startColumn: 1, endLine: 1, endColumn: 1 },
            text: '// edited by extension\n',
            expectedVersion: null,
        }]);
    }, TEST_TIMEOUT_MILLISECONDS);

    test('Lithe edits reach extension events in version order', async () => {
        const lithe = await launchInitialized();
        await lithe.request('host/activateByEvent', { event: 'onCommand:litheProbe.editAndSave' });
        const uri = lithe.uriOf('B.java');

        lithe.openDocument(uri, 'class B {}\n');
        lithe.editDocument(uri, { startLine: 1, startColumn: 7, endLine: 1, endColumn: 8 }, 'Renamed');
        lithe.notify('host/documentSaved', { uri });
        lithe.notify('host/documentClosed', { uri });
        const events = await lithe.request('host/executeCommand', { command: 'litheProbe.events', arguments: [] });

        expect(events).toEqual([
            { kind: 'open', uri, version: 1, text: 'class B {}\n' },
            { kind: 'change', uri, version: 2, text: 'class Renamed {}\n', isDirty: true },
            // VS Code also fires onDidChangeTextDocument when only the dirty state changes.
            { kind: 'change', uri, version: 2, text: 'class Renamed {}\n', isDirty: false },
            { kind: 'save', uri, version: 2, isDirty: false },
            { kind: 'close', uri },
        ]);
    }, TEST_TIMEOUT_MILLISECONDS);

    test('a change that does not advance the version is rejected and reported', async () => {
        const lithe = await launchInitialized();
        const uri = lithe.uriOf('C.java');
        lithe.openDocument(uri, 'class C {}\n');

        lithe.notify('host/documentChanged', { uri, version: 1, changes: [], isDirty: true });

        const log = await lithe.waitForNotification(entry => entry.method === 'lithe/log' && entry.params.message.includes('staleDocumentVersion'),
            'the stale change to be reported');
        expect(log.params.level).toBe('error');
    }, TEST_TIMEOUT_MILLISECONDS);
});

describe('window and API coverage', () => {
    test('messages and progress are forwarded to Lithe', async () => {
        const lithe = await launchInitialized();
        await lithe.request('host/activateByEvent', { event: 'onCommand:litheProbe.editAndSave' });
        lithe.showMessageAnswer = 1;

        expect(await lithe.request('host/executeCommand', { command: 'litheProbe.showMessage', arguments: [] })).toBe('No');
        expect(await lithe.request('host/executeCommand', { command: 'litheProbe.progress', arguments: [] })).toBe('done');

        const message = lithe.receivedRequests.find(entry => entry.method === 'lithe/showMessage');
        expect(message?.params).toEqual({ severity: 'warning', message: 'Continue?', detail: null, modal: false, actions: ['Yes', 'No'] });
        const start = lithe.notifications.find(entry => entry.method === 'lithe/progress' && entry.params.title === 'Indexing');
        const isIndexing = (entry: { method: string; params: any }) => entry.method === 'lithe/progress' && entry.params.id === start?.params.id;
        // The end of a progress may arrive after the command result; both are sent by the plugin side.
        await lithe.waitForNotification(entry => isIndexing(entry) && entry.params.phase === 'end', 'the progress to end');
        const indexing = lithe.notifications.filter(isIndexing);
        expect(indexing.map(entry => entry.params.phase)).toEqual(['start', 'report', 'end']);
        expect(indexing[1].params).toMatchObject({ message: 'half', increment: 50 });
    }, TEST_TIMEOUT_MILLISECONDS);

    test('an unimplemented API fails explicitly and is reported once', async () => {
        const lithe = await launchInitialized();
        await lithe.request('host/activateByEvent', { event: 'onCommand:litheProbe.editAndSave' });

        const first = await lithe.request('host/executeCommand', { command: 'litheProbe.useUnsupportedApi', arguments: [] });
        await lithe.request('host/executeCommand', { command: 'litheProbe.useUnsupportedApi', arguments: [] });

        expect(first.failed).toBe(true);
        expect(first.message).toContain('QuickOpenMain.$show');
        const reported = lithe.notifications.filter(entry => entry.method === 'lithe/unsupportedApi').map(entry => entry.params.api as string);
        expect(reported).toContain('QuickOpenMain.$show');
        expect(new Set(reported).size).toBe(reported.length);
    }, TEST_TIMEOUT_MILLISECONDS);

    test('workspace.fs reads and writes file URIs and maps errors to FileSystemError', async () => {
        const lithe = await launchInitialized();
        await lithe.request('host/activateByEvent', { event: 'onCommand:litheProbe.editAndSave' });

        const result = await lithe.request('host/executeCommand', { command: 'litheProbe.fileSystem', arguments: [{ $uri: lithe.uriOf('') }] });

        expect(result).toEqual({
            text: 'héllo',
            type: 1,
            size: 6,
            entries: [['a.txt', 1]],
            missing: { isFileSystemError: true, code: 'FileNotFound' },
            overwrite: 'FileExists',
        });
    }, TEST_TIMEOUT_MILLISECONDS);

    test('findFiles is answered by Lithe with its own search rules', async () => {
        const lithe = await launchInitialized();
        await lithe.request('host/activateByEvent', { event: 'onCommand:litheProbe.editAndSave' });
        fs.mkdirSync(`${lithe.workspaceDirectory}/module`, { recursive: true });
        fs.writeFileSync(`${lithe.workspaceDirectory}/pom.xml`, '<project/>');
        fs.writeFileSync(`${lithe.workspaceDirectory}/module/pom.xml`, '<project/>');

        const all = await lithe.request('host/executeCommand', { command: 'litheProbe.findFiles', arguments: ['**/pom.xml'] });
        const first = await lithe.request('host/executeCommand', { command: 'litheProbe.findFiles', arguments: ['**/pom.xml', 1] });

        expect(all).toEqual([lithe.uriOf('module/pom.xml'), lithe.uriOf('pom.xml')]);
        expect(first).toHaveLength(1);
        const search = lithe.receivedRequests.find(entry => entry.method === 'lithe/findFiles');
        expect(search?.params).toEqual({ include: '**/pom.xml', baseUri: null, exclude: null, useDefaultExcludes: true, useIgnoreFiles: false, maxResults: null });
    }, TEST_TIMEOUT_MILLISECONDS);

    test('extension output never corrupts the protocol stream and process.exit is ignored', async () => {
        const lithe = await launchInitialized();
        await lithe.request('host/activateByEvent', { event: 'onCommand:litheProbe.editAndSave' });

        expect(await lithe.request('host/executeCommand', { command: 'litheProbe.tryToExit', arguments: [] })).toBe('still running');

        expect(lithe.stderr).toContain('Ignored process.exit(3)');
        expect(lithe.notifications.filter(entry => entry.method === 'test/corruptStdout')).toEqual([]);
    }, TEST_TIMEOUT_MILLISECONDS);
});

describe('lifecycle', () => {
    test('shutdown deactivates, persists extension state and exits; state survives a restart', async () => {
        const first = await launchInitialized();
        await first.request('host/activateByEvent', { event: 'onCommand:litheProbe.editAndSave' });
        expect(await first.request('host/executeCommand', { command: 'litheProbe.bumpCounter', arguments: [] })).toBe(1);

        await first.request('host/shutdown', { timeoutMilliseconds: 5_000 });
        expect(await first.waitForExit()).toBe(0);

        const second = await launchInitialized(first.directory);
        await second.request('host/activateByEvent', { event: 'onCommand:litheProbe.editAndSave' });
        expect(await second.request('host/executeCommand', { command: 'litheProbe.bumpCounter', arguments: [] })).toBe(2);
        expect(fs.existsSync(first.directory)).toBe(true);
    }, TEST_TIMEOUT_MILLISECONDS);

    test('shutdown ends child processes that extensions left running', async () => {
        const lithe = await launchInitialized();
        await lithe.request('host/activateByEvent', { event: 'onCommand:litheProbe.editAndSave' });
        const pid = await lithe.request('host/executeCommand', { command: 'litheProbe.startStubbornChild', arguments: [] });
        expect(isProcessRunning(pid)).toBe(true);

        // The child ignores SIGTERM, so this also covers the SIGKILL escalation.
        await lithe.request('host/shutdown', { timeoutMilliseconds: 2_000 }, 20_000);

        expect(isProcessRunning(pid)).toBe(false);
        const warning = await lithe.waitForNotification(entry => entry.method === 'lithe/log' && entry.params.source === 'host',
            'the leftover child report');
        expect(warning.params.message).toBe('Terminated 1 child process(es) extensions left running at shutdown.');
        expect(await lithe.waitForExit()).toBe(0);
    }, TEST_TIMEOUT_MILLISECONDS);

    test('closing stdin stops the host without a shutdown request', async () => {
        const lithe = await launchInitialized();

        lithe.closeInput();

        expect(await lithe.waitForExit()).toBe(0);
    }, TEST_TIMEOUT_MILLISECONDS);
});
