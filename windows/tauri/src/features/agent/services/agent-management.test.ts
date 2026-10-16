import { describe, expect, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/agent/agent-management-v1.json";
import { installProgressEvent, parseAgentManagementStatus } from "./agent-management";

const status = fixture.responses.status;

describe("Agent management status", () => {
  test("reads the detected runtime and the whole catalog from the shared fixture", () => {
    const parsed = parseAgentManagementStatus(status);
    if (parsed === null) throw new Error("the fixture must parse");

    expect(parsed.environment.node).toEqual(status.environment.node);
    expect(parsed.environment.npm).toEqual(status.environment.npm);
    expect(parsed.agents.map((agent) => agent.id)).toEqual(["codex-acp", "claude-acp"]);
    expect(parsed.agents[0]?.installedVersion).toBe("1.13.1");
    expect(parsed.agents[0]?.cli?.detected?.version).toBe("0.156.1");
  });

  test("an agent without an install keeps its issues and installation owner", () => {
    const parsed = parseAgentManagementStatus(status);
    const claude = parsed?.agents[1];
    if (claude === undefined) throw new Error("the fixture must carry a second agent");

    expect(claude.installedVersion).toBeNull();
    expect(claude.cli?.detected).toBeNull();
    expect(claude.cli?.installation.source).toBe("missing");
    expect(claude.issues).toHaveLength(2);
  });

  test("a response outside the documented shape is rejected rather than half read", () => {
    expect(parseAgentManagementStatus(null)).toBeNull();
    expect(parseAgentManagementStatus("agents")).toBeNull();
    expect(parseAgentManagementStatus({ agents: "codex-acp" })).toEqual({
      environment: { node: null, npm: null },
      agents: [],
    });
    // An entry without an id cannot be installed or selected, so it is dropped.
    expect(parseAgentManagementStatus({ agents: [{ name: "Codex" }] })?.agents).toEqual([]);
  });
});

describe("Agent install progress", () => {
  test("reads the npm transfer the host reported", () => {
    expect(installProgressEvent(fixture.events.downloading)).toEqual({
      stage: "downloading",
      downloadedBytes: 25000000,
      bytesPerSecond: 75000,
      elapsedMilliseconds: 300000,
      idleMilliseconds: 0,
    });
    expect(installProgressEvent(fixture.events.waiting)?.idleMilliseconds).toBe(20000);
  });

  test("only an install progress event is reported", () => {
    expect(installProgressEvent({ kind: "agentInstallProgress" })).toBeNull();
    expect(installProgressEvent({ kind: "gitExecution", progress: {} })).toBeNull();
    expect(installProgressEvent(fixture.events.downloading.progress)).toBeNull();
    expect(installProgressEvent(null)).toBeNull();
  });
});
