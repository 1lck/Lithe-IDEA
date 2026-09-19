// Assembles Theia's unmodified plugin-side API implementation inside this process.
//
// The bindings mirror `@theia/plugin-ext/lib/hosted/node/plugin-host-module` in
// Theia 1.75.0. That module constructs a process IPC channel at load time, so it
// cannot be reused directly; this copy differs only in the channel it receives.
// Re-check the list whenever the pinned Theia version changes.
import '@theia/core/shared/reflect-metadata';
import { Container, ContainerModule, interfaces } from '@theia/core/shared/inversify';
import { Channel } from '@theia/core/lib/common/message-rpc/channel';
import { EncodingService } from '@theia/core/lib/common/encoding-service';
import { RPCProtocol, RPCProtocolImpl } from '@theia/plugin-ext/lib/common/rpc-protocol';
import { LocalizationExt } from '@theia/plugin-ext/lib/common/plugin-api-rpc';
import { AbstractPluginHostRPC, PluginContainerModuleLoader, PluginHostRPC } from '@theia/plugin-ext/lib/hosted/node/plugin-host-rpc';
import { setupPluginHostLogger } from '@theia/plugin-ext/lib/hosted/node/plugin-host-logger';
import { InternalPluginContainerModule } from '@theia/plugin-ext/lib/plugin/node/plugin-container-module';
import { AbstractPluginManagerExtImpl, MinimalTerminalServiceExt, PluginManagerExtImpl } from '@theia/plugin-ext/lib/plugin/plugin-manager';
import { EnvExtImpl } from '@theia/plugin-ext/lib/plugin/env';
import { EnvNodeExtImpl } from '@theia/plugin-ext/lib/plugin/node/env-node-ext';
import { LocalizationExtImpl } from '@theia/plugin-ext/lib/plugin/localization-ext';
import { InternalStorageExt, KeyValueStorageProxy } from '@theia/plugin-ext/lib/plugin/plugin-storage';
import { InternalSecretsExt, SecretsExtImpl } from '@theia/plugin-ext/lib/plugin/secrets-ext';
import { PreferenceRegistryExtImpl } from '@theia/plugin-ext/lib/plugin/preference-registry';
import { DebugExtImpl } from '@theia/plugin-ext/lib/plugin/debug/debug-ext';
import { LmExtImpl } from '@theia/plugin-ext/lib/plugin/lm-ext';
import { LanguageModelToolsExtImpl } from '@theia/plugin-ext/lib/plugin/lm-tool-ext';
import { EditorsAndDocumentsExtImpl } from '@theia/plugin-ext/lib/plugin/editors-and-documents';
import { WorkspaceExtImpl } from '@theia/plugin-ext/lib/plugin/workspace';
import { MessageRegistryExt } from '@theia/plugin-ext/lib/plugin/message-registry';
import { ClipboardExt } from '@theia/plugin-ext/lib/plugin/clipboard-ext';
import { WebviewsExtImpl } from '@theia/plugin-ext/lib/plugin/webviews';
import { TerminalServiceExtImpl } from '@theia/plugin-ext/lib/plugin/terminal-ext';

export interface PluginSide {
    rpc: RPCProtocol;
    pluginHost: PluginHostRPC;
}

/**
 * Creates the plugin-side container. Theia's logger setup replaces the global
 * `console`, so from this point on host diagnostics must not use `console`.
 */
export function createPluginSide(channel: Channel): PluginSide {
    const module = new ContainerModule(bind => {
        const rpc = new RPCProtocolImpl(channel);
        setupPluginHostLogger(rpc);
        bind(RPCProtocol).toConstantValue(rpc);

        bind(PluginContainerModuleLoader).toDynamicValue(({ container }: interfaces.Context) =>
            (pluginModule: ContainerModule) => {
                container.load(pluginModule);
                return (pluginModule as InternalPluginContainerModule).initializeApi?.(container);
            }).inSingletonScope();

        bind(AbstractPluginHostRPC).toService(PluginHostRPC);
        bind(AbstractPluginManagerExtImpl).toService(PluginManagerExtImpl);
        bind(PluginManagerExtImpl).toSelf().inSingletonScope();
        bind(PluginHostRPC).toSelf().inSingletonScope();
        bind(EnvExtImpl).to(EnvNodeExtImpl).inSingletonScope();
        bind(LocalizationExt).to(LocalizationExtImpl).inSingletonScope();
        bind(InternalStorageExt).toService(KeyValueStorageProxy);
        bind(KeyValueStorageProxy).toSelf().inSingletonScope();
        bind(InternalSecretsExt).toService(SecretsExtImpl);
        bind(SecretsExtImpl).toSelf().inSingletonScope();
        bind(PreferenceRegistryExtImpl).toSelf().inSingletonScope();
        bind(DebugExtImpl).toSelf().inSingletonScope();
        bind(LmExtImpl).toSelf().inSingletonScope();
        bind(LanguageModelToolsExtImpl).toSelf().inSingletonScope();
        bind(EncodingService).toSelf().inSingletonScope();
        bind(EditorsAndDocumentsExtImpl).toSelf().inSingletonScope();
        bind(WorkspaceExtImpl).toSelf().inSingletonScope();
        bind(MessageRegistryExt).toSelf().inSingletonScope();
        bind(ClipboardExt).toSelf().inSingletonScope();
        bind(WebviewsExtImpl).toSelf().inSingletonScope();
        bind(MinimalTerminalServiceExt).toService(TerminalServiceExtImpl);
        bind(TerminalServiceExtImpl).toSelf().inSingletonScope();
    });
    const container = new Container();
    container.load(module);
    return { rpc: container.get<RPCProtocol>(RPCProtocol), pluginHost: container.get(PluginHostRPC) };
}
