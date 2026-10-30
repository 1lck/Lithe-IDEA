// Explicit integration fixture, not an SDK: exercises the production stdio
// transport and command -> host request -> versioned edit route.
let buffer = Buffer.alloc(0), nextID = 0, completed;
const pending = new Map();
function send(message) {
  const body = Buffer.from(JSON.stringify({ jsonrpc: "2.0", ...message }));
  process.stdout.write(`Content-Length: ${body.length}\r\n\r\n`);
  process.stdout.write(body);
}
function request(method, params) {
  const id = `fixture-${++nextID}`;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error("host request deadline")); }, 5000);
    pending.set(id, { resolve, reject, timer });
    send({ id, method, params });
  });
}
async function transform(context) {
  const capabilities = await request("lithe/host/getCapabilities", {});
  if (!capabilities.services.editor.methods.includes("lithe/host/editor/applyEdits")) throw new Error("edit not granted");
  const active = await request("lithe/host/editor/getActive", { context });
  const selected = await request("lithe/host/editor/getSelections", { context, documentID: active.documentID });
  const snapshot = await request("lithe/host/documents/getSnapshot", { context, documentID: active.documentID });
  if (snapshot.document.version !== selected.version) throw new Error("inconsistent snapshot");
  const result = await request("lithe/host/editor/applyEdits", { context, documentID: active.documentID,
    expectedVersion: selected.version, edits: [{ range: { start: selected.selections[0].anchor,
      end: selected.selections[0].active }, text: "DONE" }] });
  return { result, original: snapshot.text };
}
async function receive(message) {
  if (!message.method) {
    const waiter = pending.get(message.id);
    if (waiter) {
      pending.delete(message.id); clearTimeout(waiter.timer);
      message.error ? waiter.reject(new Error(message.error.data?.code ?? message.error.message)) : waiter.resolve(message.result);
    }
    return;
  }
  if (message.method === "initialize") {
    send({ id: message.id, result: { capabilities: { experimental: { litheFunctions: {
      version: 3, functions: [{ id: "fixture.result" }],
    } } } } });
  } else if (message.method === "lithe/host/commands/didRun") {
    completed = transform(message.params.context).then(value => ({ value }), error => ({ failure: error.message }));
  } else if (message.method === "lithe/function/invoke") {
    const result = completed ? await completed : { failure: "no command delivered" };
    send({ id: message.id, result });
  } else if (message.method === "shutdown") {
    send({ id: message.id, result: null });
  } else if (message.method === "exit") {
    process.exit(0);
  }
}
process.stdin.on("data", bytes => {
  buffer = Buffer.concat([buffer, bytes]);
  while (true) {
    const end = buffer.indexOf("\r\n\r\n");
    if (end < 0) break;
    const length = Number(/Content-Length:\s*(\d+)/i.exec(buffer.subarray(0, end).toString())?.[1]);
    if (!Number.isSafeInteger(length) || length > 2 ** 20) process.exit(2);
    if (buffer.length < end + 4 + length) break;
    const message = JSON.parse(buffer.subarray(end + 4, end + 4 + length).toString());
    buffer = buffer.subarray(end + 4 + length);
    void receive(message).catch(error => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
  }
});
process.stdin.on("end", () => process.exit(0));
