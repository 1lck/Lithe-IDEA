import { CommandRegistryMain } from '@theia/plugin-ext/lib/common/plugin-api-rpc';
import { Methods } from '../protocol';
import { MainContext } from './main-context';
import { fromProtocolValue, toProtocolValue } from './uri';

interface CommandDescription {
    id: string;
    label?: string;
}

/**
 * Main side of `vscode.commands`.
 *
 * Commands with an extension handler run inside the plugin side and never reach
 * this class. Everything else an extension executes is a Lithe command and is
 * forwarded to Lithe, which answers `commandNotFound` for ids it does not own.
 */
export class LitheCommandRegistryMain implements Partial<CommandRegistryMain> {
    private readonly extensionHandlers = new Set<string>();
    private litheCommands: string[] = [];

    constructor(private readonly context: MainContext) { }

    /** Commands Lithe declared it can execute; reported through `commands.getCommands()`. */
    setLitheCommands(commands: string[]): void {
        this.litheCommands = [...new Set(commands)].sort();
    }

    hasExtensionHandler(id: string): boolean {
        return this.extensionHandlers.has(id);
    }

    $registerCommand(command: CommandDescription): void {
        this.context.connection.notify(Methods.commandRegistered, { command: command.id, title: command.label ?? null });
    }

    $unregisterCommand(id: string): void {
        this.context.connection.notify(Methods.commandUnregistered, { command: id });
    }

    $registerHandler(id: string): void {
        this.extensionHandlers.add(id);
    }

    $unregisterHandler(id: string): void {
        this.extensionHandlers.delete(id);
    }

    async $executeCommand<T>(id: string, ...args: unknown[]): Promise<T | undefined> {
        const result = await this.context.connection.request<unknown>(Methods.executeLitheCommand, {
            command: id,
            arguments: args.map(argument => toProtocolValue(argument)),
        });
        return (fromProtocolValue(result) ?? undefined) as T | undefined;
    }

    async $getCommands(): Promise<string[]> {
        return [...new Set([...this.litheCommands, ...this.extensionHandlers])].sort();
    }

    async $getKeyBinding(): Promise<undefined> {
        // Lithe keybindings are not exposed to extensions; VS Code also answers
        // `undefined` for commands without a binding.
        return undefined;
    }
}
