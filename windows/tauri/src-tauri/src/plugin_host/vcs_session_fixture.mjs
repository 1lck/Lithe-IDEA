// Native integration fixture: Core owns framing, negotiation and the child tree.
import { appendFileSync } from "node:fs";

const [receipt, expectedRoot] = process.argv.slice(2);
let input = Buffer.alloc(0);
function send(id, result, error) {
  const body = Buffer.from(
    JSON.stringify(error ? { jsonrpc: "2.0", id, error } : { jsonrpc: "2.0", id, result }),
  );
  process.stdout.write(`Content-Length: ${body.length}\r\n\r\n`);
  process.stdout.write(body);
}
function handle({ id, method, params }) {
  if (method === "exit") return process.exit(0);
  if (id === undefined) return;
  if (method === "initialize")
    return send(id, {
      capabilities: {
        experimental: {
          litheVcs: {
            version: 1,
            vcs: "fixture",
            capabilities: {
              status: 1,
              baseContent: 1,
              checkin: 1,
              rollback: 1,
              conflicts: 1,
              cleanup: 1,
              fileOperations: 1,
            },
          },
        },
      },
    });
  if (method === "shutdown") return send(id, null);
  if (method === "lithe/vcs/status")
    return send(id, {
      changes: [{ path: "conflict.txt", status: "conflicted" }],
    });
  if (["lithe/vcs/resolve", "lithe/vcs/cleanup", "lithe/vcs/fileOperation"].includes(method)) {
    appendFileSync(receipt, `${JSON.stringify({ method, params })}\n`);
    const fileOperation = method.endsWith("/fileOperation");
    const expected = fileOperation
      ? ["kind", "paths", "root", "tool"]
      : method.endsWith("/resolve")
        ? ["paths", "root", "tool"]
        : ["root", "tool"];
    if (
      JSON.stringify(Object.keys(params).sort()) !== JSON.stringify(expected) ||
      params.root.path !== expectedRoot ||
      params.tool !== null ||
      (fileOperation &&
        (!["add", "delete"].includes(params.kind) ||
          JSON.stringify(params.paths) !==
            (params.kind === "add" ? '["new.txt"]' : '["after.txt","before.txt"]'))) ||
      (method.endsWith("/resolve") && JSON.stringify(params.paths) !== '["conflict.txt"]')
    )
      return send(id, null, {
        code: -32602,
        message: "Unexpected typed VCS parameters",
      });
    return send(id, {});
  }
  send(id, null, { code: -32601, message: "Unsupported fixture request" });
}
process.stdin.on("data", (chunk) => {
  input = Buffer.concat([input, chunk]);
  if (input.length > 65536) return process.exit(2);
  while (true) {
    const end = input.indexOf("\r\n\r\n");
    if (end < 0) return;
    const match = /^Content-Length: (\d+)$/im.exec(input.subarray(0, end).toString());
    if (!match) return process.exit(2);
    const length = Number(match[1]);
    if (input.length < end + 4 + length) return;
    const body = input.subarray(end + 4, end + 4 + length);
    input = input.subarray(end + 4 + length);
    handle(JSON.parse(body));
  }
});
