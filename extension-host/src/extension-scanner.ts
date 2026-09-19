import * as path from 'path';
import { pathToFileURL } from 'url';
import { loadManifest } from '@theia/plugin-utils/lib/node/plugin-manifest';
import { buildLifecycle, buildModelForVsCode } from '@theia/plugin-utils/lib/common/plugin-model';
import { PluginManifest, PluginMetadata } from '@theia/plugin-utils/lib/common/manifest-types';
import { ExtensionSummary } from './protocol';

/** Theia routes plugin metadata by host id; this process is the only host. */
export const LITHE_PLUGIN_HOST_ID = 'main';

export interface ScannedExtension {
    metadata: PluginMetadata;
    summary: ExtensionSummary;
    /** `default` of every contributed setting plus `configurationDefaults`, as flat dotted keys. */
    configurationDefaults: Record<string, unknown>;
}

/**
 * Reads one unpacked VS Code extension directory.
 *
 * Manifest parsing, NLS substitution and implicit activation events (for example
 * `onCommand` for contributed commands) come from Theia's own loader so that the
 * host and the plugin manager agree on the same model.
 */
export async function scanExtension(extensionPath: string): Promise<ScannedExtension> {
    const manifest = await loadManifest<PluginManifest>(extensionPath);
    if (!manifest.main) {
        throw new Error('Only extensions with a Node `main` entry point are supported.');
    }
    const model = buildModelForVsCode({
        ...manifest,
        publisher: manifest.publisher ?? 'unpublished',
        packagePath: extensionPath,
        packageUri: pathToFileURL(extensionPath).toString(),
    }, { uiKind: 'desktop' });
    model.entryPoint.backend = path.resolve(extensionPath, model.entryPoint.backend ?? manifest.main);
    const lifecycle = {
        ...buildLifecycle(manifest, 'vscode'),
        backendInitPath: require.resolve('@theia/plugin-ext-vscode/lib/node/plugin-vscode-init'),
    };
    const commands = (manifest.contributes?.commands as { command: string; title?: unknown }[] | undefined) ?? [];
    return {
        metadata: { host: LITHE_PLUGIN_HOST_ID, model, lifecycle, outOfSync: false },
        configurationDefaults: contributedConfigurationDefaults(manifest.contributes),
        summary: {
            id: model.id,
            version: model.version,
            displayName: model.displayName || null,
            activationEvents: [...(manifest.activationEvents ?? [])].sort(),
            commands: commands
                .map(entry => ({ command: entry.command, title: typeof entry.title === 'string' ? entry.title : null }))
                .sort((left, right) => left.command.localeCompare(right.command)),
        },
    };
}

/**
 * VS Code builds its default configuration layer from what extensions contribute.
 * Without it, `getConfiguration('java').get('project')` is `undefined` and
 * extensions that rely on declared defaults fail during activation.
 */
function contributedConfigurationDefaults(contributes: unknown): Record<string, unknown> {
    const defaults: Record<string, unknown> = {};
    if (typeof contributes !== 'object' || contributes === null) {
        return defaults;
    }
    const { configuration, configurationDefaults } = contributes as { configuration?: unknown; configurationDefaults?: unknown };
    const sections = Array.isArray(configuration) ? configuration : configuration ? [configuration] : [];
    for (const section of sections) {
        const properties = (section as { properties?: Record<string, { default?: unknown }> }).properties ?? {};
        for (const key of Object.keys(properties).sort()) {
            if ('default' in properties[key]) {
                defaults[key] = properties[key].default;
            }
        }
    }
    if (typeof configurationDefaults === 'object' && configurationDefaults !== null) {
        Object.assign(defaults, configurationDefaults);
    }
    return defaults;
}
