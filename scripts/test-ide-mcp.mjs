import assert from "node:assert/strict";
import test from "node:test";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { createInterface } from "node:readline";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const executable = process.env.LITHE_MCP_TEST_EXECUTABLE || path.join(root,"rust/target/debug", process.platform === "win32" ? "lithe-mcp.exe" : "lithe-mcp");

test("stdio MCP negotiates, discovers IDE tools, routes calls and reports tool failures", {timeout:15000}, async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(),"lithe-mcp-protocol-"));
  t.after(()=>rm(directory,{recursive:true,force:true}));
  const requests = [];
  const server = createServer(async (request,response) => {
    assert.equal(request.headers.authorization,"Bearer fixture-private-token");
    let body = "";
    for await (const chunk of request) body += chunk;
    const call = JSON.parse(body);
    requests.push(call);
    response.setHeader("content-type","application/json");
    response.end(JSON.stringify(call.name === "lithe_project_inspect" ? {workspaceID:"fixture-project",error:null} : {ok:false,error:{code:"PERMISSION_DENIED",message:"Enable execution in Lithe"}}));
  });
  await new Promise((resolve,reject)=>{server.once("error",reject);server.listen(0,"127.0.0.1",resolve);});
  t.after(()=>{server.closeAllConnections();server.close();});
  const connection = path.join(directory,"connection.json");
  await writeFile(connection,JSON.stringify({endpoint:`http://127.0.0.1:${server.address().port}/call`,token:"fixture-private-token"}),{mode:0o600});
  const child = spawn(executable,["--connection",connection],{stdio:["pipe","pipe","pipe"]});
  const pending = new Map();
  let stderr = "";
  child.stderr.setEncoding("utf8").on("data",data=>{stderr = (stderr+data).slice(-8192);});
  const lines = createInterface({input:child.stdout});
  lines.on("line",line=>{const message = JSON.parse(line);pending.get(message.id)?.resolve(message);});
  const rejectPending = error => { for (const request of pending.values()) request.reject(error); };
  child.on("error",rejectPending);
  child.on("exit",()=>rejectPending(new Error(`MCP helper exited: ${stderr}`)));
  const watchdog = setTimeout(()=>child.kill("SIGKILL"),12000);
  t.after(async ()=>{
    clearTimeout(watchdog);
    lines.close();
    child.stdin.destroy();
    rejectPending(new Error("Test finished"));
    if (child.exitCode !== null || child.signalCode !== null || !child.pid) return;
    await new Promise((resolve,reject)=>{
      const timer = setTimeout(()=>reject(new Error("MCP helper did not exit after termination")),2000);
      child.once("exit",()=>{clearTimeout(timer);resolve();});
      child.kill("SIGKILL");
    });
  });
  let sequence = 0;
  const send = (method,params) => new Promise((resolve,reject)=>{
    const id = ++sequence;
    const timer = setTimeout(()=>{pending.delete(id);reject(new Error(`Timed out: ${method}; ${stderr}`));},3000);
    const finish = callback => value => {clearTimeout(timer);pending.delete(id);callback(value);};
    pending.set(id,{resolve:finish(resolve),reject:finish(reject)});
    child.stdin.write(JSON.stringify({jsonrpc:"2.0",id,method,params})+"\n");
  });
  const initialized = await send("initialize",{protocolVersion:"2025-11-25",capabilities:{},clientInfo:{name:"lithe-fixture",version:"1"}});
  assert.equal(initialized.result.serverInfo.name,"lithe");
  child.stdin.write(JSON.stringify({jsonrpc:"2.0",method:"notifications/initialized"})+"\n");
  const listed = await send("tools/list",{});
  assert.ok(listed.result.tools.some(tool=>tool.name==="lithe_environment_configure"));
  assert.ok(listed.result.tools.some(tool=>tool.name==="lithe_operation_output"));
  assert.ok(!listed.result.tools.some(tool=>/write_file|shell/.test(tool.name)));
  const inspected = await send("tools/call",{name:"lithe_project_inspect",arguments:{}});
  assert.equal(inspected.result.structuredContent.workspaceID,"fixture-project");
  assert.notEqual(inspected.result.isError,true,"a nullable domain error field is a successful inspection");
  const denied = await send("tools/call",{name:"lithe_maven_execute",arguments:{goals:["verify"]}});
  assert.equal(denied.result.isError,true);
  assert.equal(denied.result.structuredContent.error.code,"PERMISSION_DENIED");
  assert.equal(requests.length,2);
});
