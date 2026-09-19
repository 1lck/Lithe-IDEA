import { URI } from '@theia/core/shared/vscode-uri';
import { UriComponents } from '@theia/plugin-ext/lib/common/uri-components';
import { isRecord } from '../protocol';

export function uriToString(components: UriComponents): string {
    return URI.from(components).toString();
}

export function parseUri(value: string): URI {
    return URI.parse(value);
}

/** VS Code marshals `Uri` instances with `$mid: 1`; Lithe sees them as `{ "$uri": "<string>" }`. */
function isMarshalledUri(value: Record<string, unknown>): boolean {
    return value.$mid === 1 && typeof value.scheme === 'string' && typeof value.path === 'string';
}

/** Converts extension values into protocol JSON. Unrepresentable values become `null`. */
export function toProtocolValue(value: unknown, depth = 0): unknown {
    if (depth > 64) {
        return null;
    }
    if (value === undefined || typeof value === 'function' || typeof value === 'symbol' || typeof value === 'bigint') {
        return null;
    }
    if (value instanceof URI || (isRecord(value) && isMarshalledUri(value))) {
        return { $uri: uriToString(value as UriComponents) };
    }
    if (Array.isArray(value)) {
        return value.map(item => toProtocolValue(item, depth + 1));
    }
    if (isRecord(value)) {
        const result: Record<string, unknown> = {};
        for (const key of Object.keys(value)) {
            result[key] = toProtocolValue(value[key], depth + 1);
        }
        return result;
    }
    return value;
}

/** Inverse of {@link toProtocolValue}: `{ "$uri": ... }` becomes a real `Uri` for the extension. */
export function fromProtocolValue(value: unknown): unknown {
    if (Array.isArray(value)) {
        return value.map(fromProtocolValue);
    }
    if (isRecord(value)) {
        const keys = Object.keys(value);
        if (keys.length === 1 && typeof value.$uri === 'string') {
            return parseUri(value.$uri);
        }
        const result: Record<string, unknown> = {};
        for (const key of keys) {
            result[key] = fromProtocolValue(value[key]);
        }
        return result;
    }
    return value;
}
