// Controlled protocol peer only. Production framing, negotiation, selectors,
// validation, cancellation and process ownership stay in the existing Core.
import { appendFileSync, existsSync, mkdirSync, watch } from "node:fs";
import path from "node:path";
const argv = process.argv.slice(2);
const state = argv[argv.indexOf("--state-dir") + 1];
if (!state || !path.isAbsolute(state)) throw new Error("native state directory required");
mkdirSync(state, { recursive: true });
const evidence = (event, extra = {}) => appendFileSync(path.join(state, "native-events.jsonl"),
  JSON.stringify({ event, pid: process.pid, workspace: process.cwd(), ...extra }) + "\n");
const send = (message) => {
  const body = Buffer.from(JSON.stringify({ jsonrpc: "2.0", ...message }));
  process.stdout.write(`Content-Length: ${body.length}\r\n\r\n`);
  process.stdout.write(body);
};
const trees = new Map();
const pending = new Map();
const registrations = new Map();
let registration = 0;
const methods = ["nodes", "inspect", "reset", "rename", "add", "remove", "reverse", "empty", "large", "slow", "fail", "sourceError", "invalid"];
const functions = ["tree", "list"].flatMap((kind) => methods.map((method) => `${kind}.${method}`))
  .concat(["form.nodes", "form.changed", "form.slow", "form.fail", "buttons.inspect", "buttons.withdraw", "buttons.restore"]);
const defaults = (kind) => kind === "tree"
  ? [{ id: "root", label: "Workflow root", children: [{ id: "group", label: "Workflow group", children: [{ id: "leaf", label: "中文 leaf" }] }] }, { id: "other", label: "Other root" }]
  : Array.from({ length: 30 }, (_, i) => ({ id: `row-${i}`, label: `Workflow row ${i}` }));
const flatten = (nodes) => nodes.flatMap((node) => [node, ...flatten(node.children ?? [])]);
function result(functionID, params) {
  const [kind, action] = functionID.split(".");
  if (kind === "form") {
    if (action === "nodes") return { nodes: [] };
    if (action === "fail") throw { code: -32020, message: "Controlled form error", data: { code: "workflow.form" } };
    return { message: JSON.stringify(params.values) };
  }
  if (kind === "buttons") return { message: "Workflow inspect succeeded" };
  if (!trees.has(kind)) trees.set(kind, { nodes: defaults(kind), invalid: false, failed: false });
  const data = trees.get(kind);
  if (action === "nodes") {
    if (data.failed) throw { code: -32020, message: "Controlled source error", data: { code: "workflow.source" } };
    return { nodes: data.invalid ? [{ id: "duplicate", label: "A" }, { id: "duplicate", label: "B" }] : data.nodes };
  }
  const selected = flatten(data.nodes).find((node) => node.id === params.selectedID);
  if (action === "rename" && selected) selected.label += " renamed";
  if (action === "reverse") data.nodes.reverse();
  if (action === "reset") trees.set(kind, { nodes: defaults(kind), invalid: false, failed: false });
  if (action === "add") data.nodes.push({ id: `added-${data.nodes.length}`, label: "Added node" });
  if (action === "remove") {
    const remove = (nodes) => nodes.filter((node) => node.id !== params.selectedID).map((node) => ({ ...node, ...(node.children ? { children: remove(node.children) } : {}) }));
    data.nodes = remove(data.nodes);
  }
  if (action === "empty") data.nodes = data.nodes.length ? [] : defaults(kind);
  if (action === "large") data.nodes = Array.from({ length: 600 }, (_, i) => ({ id: `bulk-${i}`, label: `Bulk ${i} 中文` }));
  if (action === "sourceError") data.failed = true;
  if (action === "invalid") data.invalid = true;
  if (action === "fail") throw { code: -32020, message: "Controlled action error", data: { code: "workflow.action" } };
  return { message: `Workflow ${action} succeeded` };
}
function handle(message) {
  if (!message.method && registrations.has(message.id)) {
    const done = registrations.get(message.id);
    registrations.delete(message.id);
    evidence("registration", { id: message.id, result: message.result, error: message.error });
    done(message);
    return;
  }
  evidence("request", { method: message.method, id: message.id, params: message.params });
  const reply = (value) => send({ id: message.id, result: value });
  if (message.method === "initialize") return reply({ capabilities: { experimental: {
    litheBuild: { version: 1 }, litheFunctions: { version: 1, functions: functions.map((id) => ({ id })) },
  } }, serverInfo: { name: "controlled-native-workflow", version: "1.0.0" } });
  if (message.method === "shutdown") return reply(null);
  if (message.method === "exit") return process.exit(0);
  if (message.method === "$/cancelRequest") {
    const cancel = pending.get(message.params?.id);
    if (cancel) { cancel(); pending.delete(message.params.id); evidence("cancelled", { id: message.params.id }); }
    return;
  }
  if (message.method === "lithe/build/model") return reply({ format: "litheBuildModel", version: 1,
    projects: [{ name: "Workflow project", path: "." }, { name: "Nested project", path: "nested" }],
    targets: [{ project: ".", name: "Workflow tests", path: ".", tags: ["test"] }], tasks: [], contentRoots: [], optionValues: {} });
  if (message.method === "lithe/build/dependencies") return reply({ format: "litheDependencies", version: 1,
    dependencies: [{ name: "workflow-dependency", version: "1.0.0", children: [] }] });
  if (message.method === "lithe/function/invoke") {
    const { functionID, operationID, params = {} } = message.params;
    if (functionID === "buttons.withdraw" || functionID === "buttons.restore") {
      const withdraw = functionID === "buttons.withdraw";
      const id = `registration-${++registration}`;
      const timer = setTimeout(() => {
        registrations.delete(id);
        pending.delete(message.id);
        send({ id: message.id, error: { code: -32603, message: "Registration acknowledgement deadline" } });
      }, 5000);
      pending.set(message.id, () => {
        clearTimeout(timer);
        registrations.delete(id);
      });
      registrations.set(id, (response) => {
        clearTimeout(timer);
        pending.delete(message.id);
        if (response.error) send({ id: message.id, error: response.error });
        else reply({ message: withdraw ? "Workflow rename withdrawn" : "Workflow rename restored" });
      });
      send({ id, method: withdraw ? "lithe/function/unregister" : "lithe/function/register",
        params: withdraw ? { ids: ["tree.rename"] } : { functions: [{ id: "tree.rename" }] } });
      return;
    }
    if (functionID.endsWith(".slow")) {
      send({ method: "lithe/function/progress", params: { operationID, message: "Controlled native operation waiting", percentage: 25 } });
      let closed = false;
      const release = path.join(process.cwd(), ".lithe-acceptance/native-release");
      const finish = () => {
        if (closed) return;
        closed = true; watcher.close(); clearTimeout(timer); pending.delete(message.id);
      };
      const watcher = watch(path.dirname(release), () => {
        if (existsSync(release)) { finish(); reply({ message: "Controlled native operation released" }); }
      });
      watcher.on("error", () => { finish(); send({ id: message.id, error: { code: -32603, message: "Fixture watch failed" } }); });
      const timer = setTimeout(() => { finish(); send({ id: message.id, error: { code: -32603, message: "Fixture deadline" } }); }, 30000);
      pending.set(message.id, finish);
      if (existsSync(release)) { finish(); reply({ message: "Controlled native operation released" }); }
      return;
    }
    try { return reply(result(functionID, params)); }
    catch (error) { return send({ id: message.id, error }); }
  }
  if (message.id !== undefined) send({ id: message.id, error: { code: -32601, message: "Unknown fixture method" } });
}
let buffer = Buffer.alloc(0);
process.stdin.on("data", (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  if (buffer.length > 2 * 1024 * 1024) process.exit(2);
  for (;;) {
    const end = buffer.indexOf("\r\n\r\n");
    if (end < 0) break;
    const length = Number(/Content-Length: (\d+)/i.exec(buffer.subarray(0, end).toString())?.[1]);
    if (!Number.isSafeInteger(length) || length > 1024 * 1024) process.exit(2);
    if (buffer.length < end + 4 + length) break;
    const message = JSON.parse(buffer.subarray(end + 4, end + 4 + length));
    buffer = buffer.subarray(end + 4 + length);
    handle(message);
  }
});
process.stdin.on("end", () => process.exit(0));
process.once("exit", () => { for (const close of pending.values()) close(); evidence("exit"); });
evidence("started", { argv });
