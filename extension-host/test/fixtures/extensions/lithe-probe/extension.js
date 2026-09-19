// Test-only VS Code extension. It uses nothing but the public `vscode` API so the
// host is exercised exactly like an unmodified third-party extension would.
const vscode = require('vscode');
const childProcess = require('child_process');

exports.activate = context => {
    const events = [];
    context.subscriptions.push(
        vscode.workspace.onDidOpenTextDocument(document => events.push({ kind: 'open', uri: document.uri.toString(), version: document.version, text: document.getText() })),
        vscode.workspace.onDidChangeTextDocument(event => events.push({ kind: 'change', uri: event.document.uri.toString(), version: event.document.version, text: event.document.getText(), isDirty: event.document.isDirty })),
        vscode.workspace.onDidSaveTextDocument(document => events.push({ kind: 'save', uri: document.uri.toString(), version: document.version, isDirty: document.isDirty })),
        vscode.workspace.onDidCloseTextDocument(document => events.push({ kind: 'close', uri: document.uri.toString() })),

        vscode.commands.registerCommand('litheProbe.editAndSave', async uri => {
            const echoed = await vscode.commands.executeCommand('lithe.echo', uri);
            const document = await vscode.workspace.openTextDocument(uri);
            const before = { text: document.getText(), version: document.version };
            const edit = new vscode.WorkspaceEdit();
            edit.insert(document.uri, new vscode.Position(0, 0), '// edited by extension\n');
            const applied = await vscode.workspace.applyEdit(edit);
            const afterEdit = { text: document.getText(), version: document.version, isDirty: document.isDirty };
            const saved = await document.save();
            return { argumentIsUri: uri instanceof vscode.Uri, echoed, before, applied, afterEdit, saved, isDirtyAfterSave: document.isDirty };
        }),
        vscode.commands.registerCommand('litheProbe.events', () => events.splice(0)),
        vscode.commands.registerCommand('litheProbe.workspaceFolders', () =>
            (vscode.workspace.workspaceFolders ?? []).map(folder => ({ uri: folder.uri.toString(), name: folder.name }))),
        vscode.commands.registerCommand('litheProbe.configuration', section => vscode.workspace.getConfiguration().get(section)),
        vscode.commands.registerCommand('litheProbe.isTrusted', () => vscode.workspace.isTrusted),
        vscode.commands.registerCommand('litheProbe.availableCommands', async () =>
            (await vscode.commands.getCommands()).filter(id => id.startsWith('lithe.') || id === 'litheProbe.events')),
        vscode.commands.registerCommand('litheProbe.showMessage', () => vscode.window.showWarningMessage('Continue?', 'Yes', 'No')),
        vscode.commands.registerCommand('litheProbe.progress', () => vscode.window.withProgress(
            { location: vscode.ProgressLocation.Notification, title: 'Indexing' },
            async progress => { progress.report({ message: 'half', increment: 50 }); return 'done'; })),
        vscode.commands.registerCommand('litheProbe.useUnsupportedApi', async () => {
            try {
                await vscode.window.showQuickPick(['a', 'b']);
                return { failed: false };
            } catch (error) {
                return { failed: true, message: String(error && error.message) };
            }
        }),
        vscode.commands.registerCommand('litheProbe.bumpCounter', async () => {
            const next = (context.globalState.get('counter') ?? 0) + 1;
            await context.globalState.update('counter', next);
            return next;
        }),
        vscode.commands.registerCommand('litheProbe.fileSystem', async folder => {
            const file = vscode.Uri.joinPath(folder, 'notes', 'a.txt');
            await vscode.workspace.fs.createDirectory(vscode.Uri.joinPath(folder, 'notes'));
            await vscode.workspace.fs.writeFile(file, Buffer.from('héllo'));
            const text = Buffer.from(await vscode.workspace.fs.readFile(file)).toString('utf8');
            const stat = await vscode.workspace.fs.stat(file);
            const entries = await vscode.workspace.fs.readDirectory(vscode.Uri.joinPath(folder, 'notes'));
            const missing = await vscode.workspace.fs.readFile(vscode.Uri.joinPath(folder, 'missing.txt')).then(
                () => 'unexpected', error => ({ isFileSystemError: error instanceof vscode.FileSystemError, code: error.code }));
            const overwrite = await vscode.workspace.fs.copy(file, file, { overwrite: false }).then(
                () => 'unexpected', error => error.code);
            return { text, type: stat.type, size: stat.size, entries, missing, overwrite };
        }),
        vscode.commands.registerCommand('litheProbe.findFiles', async (pattern, maxResults) =>
            (await vscode.workspace.findFiles(pattern, undefined, maxResults)).map(uri => uri.toString())),
        // Starts a child that only exits when killed, like a language server that ignores its client.
        // Resolves only after the child ignores SIGTERM, so shutdown must escalate to SIGKILL.
        vscode.commands.registerCommand('litheProbe.startStubbornChild', () => new Promise((resolve, reject) => {
            const child = childProcess.spawn(process.execPath,
                ['-e', 'process.on("SIGTERM", () => {}); process.stdout.write("ready\\n"); process.stdin.resume()'],
                { stdio: ['pipe', 'pipe', 'ignore'] });
            child.once('error', reject);
            child.stdout.once('data', () => resolve(child.pid));
        })),
        vscode.commands.registerCommand('litheProbe.tryToExit', () => {
            process.exit(3);
            return 'still running';
        }),
        vscode.commands.registerCommand('litheProbe.fail', () => {
            throw new Error('probe failure');
        }),
        vscode.commands.registerCommand('litheProbe.callLithe', (command, ...args) => vscode.commands.executeCommand(command, ...args)),
        vscode.commands.registerCommand('litheProbe.callLitheThenReport', async command => {
            const result = await vscode.commands.executeCommand(command);
            await vscode.commands.executeCommand('lithe.report', result);
            return result;
        })
    );
};

exports.deactivate = () => undefined;
