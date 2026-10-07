import { expect, mock, test } from "bun:test";
import {
  attachCreatedModule,
  createWorkspaceModule,
  type ModuleCreationPorts,
  type ModuleRequest,
} from "./create-workspace-module";
const request: ModuleRequest = {
  workspaceRoot: "/workspace",
  parentPath: "/workspace",
  name: "child",
  source: "java",
};
function ports(): ModuleCreationPorts {
  return {
    activeRoot: () => "/workspace",
    create: mock(async () => "/workspace/child"),
    attach: mock(async () => true),
  };
}
test("Java module uses atomic scaffold and attaches without opening/replacing the project", async () => {
  const io = ports();
  expect(await createWorkspaceModule(request, io)).toEqual({
    path: "/workspace/child",
    attached: true,
    reason: null,
  });
  expect(io.create).toHaveBeenCalledWith({
    parentPath: "/workspace",
    name: "child",
    source: "java",
  });
  expect(io.attach).toHaveBeenCalledWith("/workspace/child");
});
test("Spring module forwards official generator selections without a parallel build model", async () => {
  const io = ports();
  const springOptions = {
    groupId: "com.example",
    artifactId: "child",
    packageName: "com.example.child",
    javaVersion: "17",
    bootVersion: "4.0.0",
    buildType: "gradle-project-kotlin" as const,
    dependencies: ["web"],
  };
  await createWorkspaceModule({ ...request, source: "spring-boot", springOptions }, io);
  expect(io.create).toHaveBeenCalledWith({
    parentPath: "/workspace",
    name: "child",
    source: "spring-boot",
    ...springOptions,
  });
});
test("invalid or remote destinations and missing Spring choices do not write", async () => {
  for (const invalid of [
    { name: "../escape" },
    { name: "NUL" },
    { parentPath: "remote://host/path" },
    { source: "spring-boot" as const },
  ]) {
    const io = ports();
    await expect(createWorkspaceModule({ ...request, ...invalid }, io)).rejects.toThrow();
    expect(io.create).not.toHaveBeenCalled();
    expect(io.attach).not.toHaveBeenCalled();
  }
});
test("workspace switch during generation retains folder but never attaches to the new workspace", async () => {
  const io = ports();
  io.create = mock(async () => {
    io.activeRoot = () => "/other";
    return "/workspace/child";
  });
  expect(await createWorkspaceModule(request, io)).toEqual({
    path: "/workspace/child",
    attached: false,
    reason: "workspaceChanged",
  });
  expect(io.attach).not.toHaveBeenCalled();
});
test("attachment failure returns recoverable path; retry does not generate again", async () => {
  const io = ports();
  io.attach = mock(async () => {
    throw new Error("watcher unavailable");
  });
  expect(await createWorkspaceModule(request, io)).toEqual({
    path: "/workspace/child",
    attached: false,
    reason: "moduleCreated",
  });
  io.attach = mock(async () => true);
  expect((await attachCreatedModule(request.workspaceRoot, "/workspace/child", io)).attached).toBe(
    true,
  );
  expect(io.create).toHaveBeenCalledTimes(1);
});
test("provider conflict propagates and does not attach an existing directory", async () => {
  const io = ports();
  io.create = mock(async () => {
    throw new Error("destination exists");
  });
  await expect(createWorkspaceModule(request, io)).rejects.toThrow("destination exists");
  expect(io.attach).not.toHaveBeenCalled();
});
