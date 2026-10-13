import { expect, mock, test } from "bun:test";
import { createJavaPackage, createJavaType } from "./create-java-entry";

function operations(occupied = false) {
  return {
    exists: mock(async () => occupied),
    mkdir: mock(async () => {}),
    create: mock(async (_path: string, _content: string) => {}),
  };
}
test("creates dot-separated package folders without writing a file", async () => {
  const io = operations();
  const result = await createJavaPackage("D:/app", "com.example", io);
  expect(result.replace(/\\/g, "/")).toBe("D:/app/com/example");
  expect(io.mkdir).toHaveBeenCalledTimes(1);
  expect(io.create).not.toHaveBeenCalled();
});
test("creates the final text before opening and never blanks an existing file", async () => {
  const io = operations();
  await createJavaType(
    { sourceRoot: "D:/app", name: "Service", kind: "interface", packageName: "demo" },
    io,
  );
  expect(io.create.mock.calls[0][1]).toBe("package demo;\n\npublic interface Service {\n}\n");
  const existing = operations(true);
  await expect(
    createJavaType(
      { sourceRoot: "D:/app", name: "Service", kind: "class", packageName: "demo" },
      existing,
    ),
  ).rejects.toThrow("javaEntry.exists");
  expect(existing.create).not.toHaveBeenCalled();
  expect(existing.mkdir).not.toHaveBeenCalled();
});
test("invalid names perform no filesystem writes, and native conflicts propagate", async () => {
  const io = operations();
  await expect(createJavaPackage("D:/app", "../outside", io)).rejects.toThrow();
  expect(io.mkdir).not.toHaveBeenCalled();
  io.create = mock(async () => {
    throw new Error("javaEntry.exists");
  });
  await expect(
    createJavaType({ sourceRoot: "D:/app", name: "App", kind: "class", packageName: "" }, io),
  ).rejects.toThrow("javaEntry.exists");
});
