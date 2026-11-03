#!/usr/bin/env node
// Build-time catalog compiler. Complete validation precedes every output write.
import { readFile, readdir, mkdir, writeFile } from 'node:fs/promises';
import { realpathSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const ROOTS = 'app editor perf lsp vcs run debug terminal remote agent update plugins'.split(' ');
export const TYPES = 'int bool duration bytes id token version path error text'.split(' ');
export const DEFAULT_RATE = 60;
export const GENERIC_DESCRIPTIONS = Object.freeze([
  'Validated internal identifier',
  'Controlled machine vocabulary',
  'Structured failure',
  'Path redacted before persistence',
  'Monotonic elapsed time',
  'Count or numeric result',
  'Outcome flag',
  'Byte count',
  'Component version',
  'Upstream diagnostic',
]);
const LEVELS = ['debug', 'info', 'warn', 'error'];
const RESERVED = ['seq', 'event', 'op', 'msg', 'ts', 'level'];
const segment = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const fieldName = /^[a-z][a-z0-9_]{0,63}$/;
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const fail = message => { throw new Error(message); };
const nonempty = (value, where) => { if (typeof value !== 'string' || !value.trim()) fail(`${where}: expected nonempty string`); };
const keys = (value, allowed, where) => {
  if (!object(value)) fail(`${where}: expected object`);
  for (const key of Object.keys(value)) if (!allowed.includes(key)) fail(`${where}: unknown property ${key}`);
};
const sorted = entries => entries.sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
const pascal = id => id.split(/[._]/).map(word => word[0].toUpperCase() + word.slice(1)).join('');
const camel = name => name.replace(/_([a-z])/g, (_, letter) => letter.toUpperCase());
const wireNames = (name, field) => field.type === 'duration' ? [`${name}_ms`] : field.type === 'error' ? [name, `${name}_code`, `${name}_domain`] : [name];

export function validateCatalog(catalogs) {
  const ids = new Set();
  const names = new Set();
  const events = [];
  const declarations = [];
  for (const catalog of catalogs) {
    keys(catalog, ['version', 'root', 'events'], 'catalog');
    if (catalog.version !== 1 || !ROOTS.includes(catalog.root) || !Array.isArray(catalog.events)) fail('invalid catalog version/root/events');
    for (const event of catalog.events) {
      keys(event, ['id', 'channel', 'level', 'message', 'fields', 'span', 'rate', 'owner'], catalog.root);
      if (typeof event.id !== 'string' || !/^[a-z][a-z0-9]*(?:\.[a-z][a-z0-9_]*){2,}$/.test(event.id) || event.id.split('.')[0] !== catalog.root) fail(`invalid event id: ${event.id}`);
      if (!LEVELS.includes(event.level)) fail(`${event.id}: invalid level`);
      nonempty(event.owner, `${event.id} owner`);
      nonempty(event.message, `${event.id} message`);
      if (!/^[\x20-\x7e]+$/.test(event.message)) fail(`${event.id}: message must be an English single-line template`);
      const rate = event.rate ?? DEFAULT_RATE;
      if (!Number.isSafeInteger(rate) || rate < 1 || rate > 60000) fail(`${event.id}: invalid rate`);
      if (!object(event.fields)) fail(`${event.id}: expected fields`);
      const encoded = new Set(RESERVED);
      const swiftParameters = new Set(['operationID', ...(event.span ? ['clock', 'emit', 'state'] : [])]);
      for (const [name, field] of Object.entries(event.fields)) {
        if (!fieldName.test(name) || RESERVED.includes(name)) fail(`${event.id}: reserved or invalid field ${name}`);
        if (swiftParameters.has(camel(name))) fail(`${event.id}: generated parameter collision ${name}`);
        swiftParameters.add(camel(name));
        keys(field, ['type', 'required', 'description', 'reason'], `${event.id}/${name}`);
        if (!TYPES.includes(field.type)) fail(`${event.id}/${name}: unknown type ${field.type}`);
        if (typeof field.required !== 'boolean') fail(`${event.id}/${name}: required must be boolean`);
        nonempty(field.description, `${event.id}/${name} description`);
        if (GENERIC_DESCRIPTIONS.includes(field.description.trim())) fail(`${event.id}/${name}: generic description must explain this event's field`);
        if ([...field.description.trim()].length < 16) fail(`${event.id}/${name}: description must contain at least 16 characters`);
        if (field.type === 'text') nonempty(field.reason, `${event.id}/${name}: text requires reason`);
        else if (field.reason !== undefined) fail(`${event.id}/${name}: reason is only for text`);
        if (field.type === 'duration' && name.endsWith('_ms')) fail(`${event.id}/${name}: duration name must not end in _ms`);
        for (const wire of wireNames(name, field)) {
          if (!fieldName.test(wire) || encoded.has(wire)) fail(`${event.id}: encoded field collision or invalid name ${wire}`);
          encoded.add(wire);
        }
      }
      if (typeof event.channel !== 'string') fail(`${event.id}: missing channel`);
      const parts = event.channel.split('/');
      if (!ROOTS.includes(parts[0]) || parts[0] !== catalog.root) fail(`${event.id}: invalid channel root`);
      for (const part of parts.slice(1)) {
        const placeholder = /^\{([a-z][a-z0-9_]*)\}$/.exec(part);
        if (placeholder) {
          const field = event.fields[placeholder[1]];
          if (field?.type !== 'id' || !field.required) fail(`${event.id}: channel placeholder must be a required id field`);
        } else if (!segment.test(part)) fail(`${event.id}: invalid channel segment`);
      }
      if (parts[0] === 'plugins' && parts.length > 1 && event.channel !== 'plugins/{plugin}/host') fail(`${event.id}: plugin host channel must be plugins/{plugin}/host`);
      for (const match of event.message.matchAll(/\{([^{}]+)\}/g)) {
        if (!Object.hasOwn(event.fields, match[1])) fail(`${event.id}: message references undeclared field ${match[1]}`);
        if (!event.fields[match[1]].required) fail(`${event.id}: message references optional field ${match[1]}`);
      }
      if (/[{}]/.test(event.message.replace(/\{[^{}]+\}/g, ''))) fail(`${event.id}: malformed message template`);
      if (event.span !== undefined) {
        keys(event.span, ['failureLevel'], `${event.id} span`);
        if (!LEVELS.includes(event.span.failureLevel)) fail(`${event.id}: invalid span failureLevel`);
        if (['duration', 'error'].some(name => Object.hasOwn(event.fields, name)) || ['duration_ms', 'error', 'error_code', 'error_domain'].some(name => encoded.has(name))) fail(`${event.id}: span automatic fields collide`);
      } else if (!/(?:started|finished|failed|skipped|missing|received|selected|superseded|hit|inspected|sampled|measured|rejected|updated|forwarded|removed|cleaned|cancelled|initialized|limited|applied|waiting|stalled|timed_out|resolved|logged|shown|interrupted)$/.test(event.id.split('.').at(-1))) fail(`${event.id}: expected outcome name in past tense`);
      declarations.push({ ...event, rate });
      const variants = event.span ? ['started', 'finished', 'failed'] : [null];
      for (const phase of variants) {
        const fields = { ...event.fields };
        if (phase && phase !== 'started') fields.duration = { type: 'duration', required: true, description: `Monotonic time from ${event.id}.started to ${event.id}.${phase}, encoded in milliseconds` };
        if (phase === 'failed') fields.error = { type: 'error', required: true, description: `Failure that ended the ${event.id} operation, retaining its error code and domain without unredacted private details` };
        const expanded = { ...event, id: phase ? `${event.id}.${phase}` : event.id,
          fields: Object.fromEntries(sorted(Object.entries(fields))), rate, span: phase,
          message: phase ? `${event.message} ${phase}` : event.message,
          level: phase === 'started' ? 'debug' : phase === 'failed' ? event.span.failureLevel : event.level };
        const name = pascal(expanded.id);
        if (ids.has(expanded.id)) fail(`duplicate id: ${expanded.id}`);
        if (names.has(name)) fail(`generated name collision: ${name}`);
        ids.add(expanded.id); names.add(name); events.push(expanded);
      }
      if (event.span) {
        const name = `${pascal(event.id)}Span`;
        if (names.has(name)) fail(`generated name collision: ${name}`);
        names.add(name);
      }
    }
  }
  return { events: events.sort((a, b) => a.id < b.id ? -1 : 1), declarations: declarations.sort((a, b) => a.id < b.id ? -1 : 1) };
}

export async function loadCatalog(root = ROOT) {
  const directory = path.join(root, 'shared/logging/events');
  const files = (await readdir(directory)).sort();
  if (JSON.stringify(files) !== JSON.stringify(ROOTS.map(root => `${root}.json`).sort())) fail('expected exactly one catalog file per fixed channel root');
  const catalogs = await Promise.all(files.map(async file => {
    const catalog = JSON.parse(await readFile(path.join(directory, file), 'utf8'));
    if (catalog.root !== file.slice(0, -5)) fail(`${file}: root differs from filename`);
    return catalog;
  }));
  return validateCatalog(catalogs);
}

const swiftType = type => ({ int: 'Int64', bool: 'Bool', duration: 'Duration', bytes: 'UInt64', id: 'LogSegment', token: 'String', version: 'String', path: 'URL', error: 'any Error', text: 'String' })[type];
const param = ([name, field]) => `\`${camel(name)}\`: ${field.required ? swiftType(field.type) : `(${swiftType(field.type)})? = nil`}`;
const quote = JSON.stringify;
const swiftQuote = value => quote(value).replace(/\\u([0-9a-f]{4})/g, '\\u{$1}');
function swiftEvent(event) {
  const fields = Object.entries(event.fields);
  const parts = event.channel.split('/');
  const segments = parts.slice(1).map(part => part.startsWith('{') ? `\`${camel(part.slice(1, -1))}\`` : `LogSegment(${swiftQuote(part)})!`);
  return `public struct ${pascal(event.id)}: LogEvent {
    public static let id = ${swiftQuote(event.id)}
    public static let level: LogLevel = .${event.level}
    public static let messageTemplate = ${swiftQuote(event.message)}
    public static let ratePerMinute = ${event.rate}
    public static let owner = ${swiftQuote(event.owner)}
    public static let debugOnly = ${event.span === 'started'}
    public let channel: LogChannel
    public let fields: [String: LogFieldValue]
    public let operationID: String?

    public init(${[...fields.map(param), 'operationID: String? = nil'].join(', ')}) {
        self.operationID = operationID
        self.channel = LogChannel(.${parts[0]}, segments: [${segments.join(', ')}])
        ${fields.length ? 'var' : 'let'} _logValues: [String: LogFieldValue] = [:]
${fields.map(([name, field]) => field.required
  ? `        _logValues[${swiftQuote(name)}] = .${field.type}(\`${camel(name)}\`)`
  : `        if let value = \`${camel(name)}\` { _logValues[${swiftQuote(name)}] = .${field.type}(value) }`).join('\n')}
        self.fields = _logValues
    }
}
`;
}
function swiftSpan(event) {
  const base = pascal(event.id);
  const required = sorted(Object.entries(event.fields).filter(([, f]) => f.required));
  const optional = sorted(Object.entries(event.fields).filter(([, f]) => !f.required));
  const args = entries => entries.map(([name]) => `${camel(name)}: \`${camel(name)}\``);
  const terminalArgs = failed => [...required, ...optional, ['duration'], ...(failed ? [['error']] : [])].sort(([a], [b]) => a < b ? -1 : 1).map(([name]) => `${camel(name)}: \`${camel(name)}\``).concat('operationID: state.operationID');
  return `public struct ${base}Span: Sendable {
    private var state: LogSpanState
    private let emit: @Sendable (any LogEvent) -> Void
${required.map(([name, field]) => `    private let \`${camel(name)}\`: ${swiftType(field.type)}`).join('\n')}

    private init(${[...required.map(param), 'operationID: String', 'clock: LogSpanClock', 'emit: @escaping @Sendable (any LogEvent) -> Void'].join(', ')}) {
        state = LogSpanState(operationID: operationID, clock: clock)
        self.emit = emit
${required.map(([name]) => `        self.\`${camel(name)}\` = \`${camel(name)}\``).join('\n')}
    }

    public static func begin(${[...required.map(param), 'operationID: String = UUID().uuidString.lowercased()', 'clock: LogSpanClock = .continuous', 'emit: @escaping @Sendable (any LogEvent) -> Void'].join(', ')}) -> Self {
        let span = Self(${[...args(required), 'operationID: operationID', 'clock: clock', 'emit: emit'].join(', ')})
        // Started is a DEBUG event; the sink drops it unless verbose diagnostics are on.
        emit(${base}Started(${[...args(required), 'operationID: operationID'].join(', ')}))
        return span
    }

    public mutating func finish(${optional.map(param).join(', ')}) {
        guard let duration = state.end() else { return }
        emit(${base}Finished(${terminalArgs(false).join(', ')}))
    }

    public mutating func fail(_ error: any Error${optional.length ? ', ' + optional.map(param).join(', ') : ''}) {
        guard let duration = state.end() else { return }
        emit(${base}Failed(${terminalArgs(true).join(', ')}))
    }
}
`;
}
function rustEvents(events) {
  const variant = type => pascal(type);
  return `//! Generated event metadata; edit shared/logging/events/*.json instead.\n// Automatically generated by scripts/logging/generate-log-events.mjs. DO NOT EDIT.\n\nuse super::{EventMetadata, FieldMetadata, FieldType, LogLevel, SpanPhase};\n\n/// Sorted, immutable metadata for every expanded catalog event.\n#[rustfmt::skip]\npub static EVENTS: &[EventMetadata] = &[\n${events.map(event => `    EventMetadata {
        id: ${quote(event.id)},
        channel: ${quote(event.channel)},
        level: LogLevel::${variant(event.level)},
        message: ${quote(event.message)},
        fields: &[
${Object.entries(event.fields).map(([name, field]) => `            FieldMetadata { name: ${quote(name)}, field_type: FieldType::${variant(field.type)}, required: ${field.required}, description: ${quote(field.description)}, reason: ${field.reason ? `Some(${quote(field.reason)})` : 'None'} },`).join('\n')}
        ],
        span: ${event.span ? `Some(SpanPhase::${variant(event.span)})` : 'None'},
        rate: ${event.rate},
        owner: ${quote(event.owner)},
    },`).join('\n')}\n];\n`;
}
export async function planGeneration(root = ROOT) {
  const contract = await loadCatalog(root);
  const outputs = new Map([
    ['macos/Sources/LitheModuleAPI/Logging/LogEvents.generated.swift', '// Automatically generated by scripts/logging/generate-log-events.mjs. DO NOT EDIT.\nimport Foundation\n\n' + contract.events.map(swiftEvent).join('\n') + '\n' + contract.declarations.filter(e => e.span).map(swiftSpan).join('\n')],
    ['rust/lithe-core/src/diagnostics/catalog_generated.rs', rustEvents(contract.events)],
  ]);
  return { contract, outputs };
}
export async function generate(root = ROOT, check = false) {
  const { contract, outputs } = await planGeneration(root);
  const stale = [];
  for (const [relative, expected] of outputs) {
    let actual;
    try { actual = await readFile(path.join(root, relative), 'utf8'); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (actual === expected) continue;
    stale.push(relative);
    if (!check) {
      await mkdir(path.dirname(path.join(root, relative)), { recursive: true });
      await writeFile(path.join(root, relative), expected);
    }
  }
  if (check && stale.length) fail(`generated logging files drifted; run node scripts/logging/generate-log-events.mjs:\n${stale.join('\n')}`);
  return contract;
}
async function main() {
  const args = process.argv.slice(2);
  if (args.length > 1 || args.some(arg => arg !== '--check')) fail('usage: node scripts/logging/generate-log-events.mjs [--check]');
  const { events } = await generate(ROOT, args[0] === '--check');
  console.log(`${events.length} log events: ${ROOTS.map(root => `${root}=${events.filter(e => e.id.startsWith(root + '.')).length}`).join(', ')}`);
}
if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(path.resolve(process.argv[1]))).href) main().catch(error => { console.error(error.message); process.exitCode = 1; });
