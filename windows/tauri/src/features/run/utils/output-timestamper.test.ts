import { describe, expect, test } from "bun:test";
import {
  hasLeadingTime,
  leadingTimeLength,
  stampOutput,
  stampRunChunk,
} from "./output-timestamper";

const noon = new Date(2026, 7, 8, 10, 12, 33, 123);

describe("output timestamping", () => {
  test("stamps Maven lines that have no clock of their own", () => {
    const stamped = stampOutput(
      "[INFO] Building backend-api\n[ERROR] Port in use\n",
      false,
      noon,
    );
    const lines = stamped.split("\n");
    expect(lines[0]?.endsWith("[INFO] Building backend-api")).toBe(true);
    expect(lines[1]?.endsWith("[ERROR] Port in use")).toBe(true);
    expect(hasLeadingTime(lines[0] ?? "")).toBe(true);
    expect(hasLeadingTime(lines[1] ?? "")).toBe(true);
  });

  test("leaves Spring Boot timestamps alone", () => {
    const line = "2026-08-08T10:12:33.123  INFO 1 --- [main] Started App";
    expect(stampOutput(`${line}\n`, false, noon)).toBe(`${line}\n`);
  });

  test("does not stamp a continuation of a partial line", () => {
    expect(stampOutput("rest of message\n", true, noon)).toBe("rest of message\n");
  });

  test("preserves whether the chunk ended with a newline", () => {
    const stamped = stampOutput("partial", false, noon);
    expect(stamped.endsWith("\n")).toBe(false);
    expect(stamped.endsWith("partial")).toBe(true);
  });

  test("does not stamp blank lines", () => {
    expect(stampOutput("\n\n", false, noon)).toBe("\n\n");
  });

  test("measures the whole clock including fractional seconds", () => {
    expect(leadingTimeLength("10:12:33.123 [INFO] hello")).toBe("10:12:33.123 ".length);
  });

  test("reports no clock for a plain line", () => {
    expect(leadingTimeLength("[INFO] hello")).toBeUndefined();
  });

  test("stamps only the first fragment when a line is split across chunks", () => {
    const first = stampRunChunk("", "[INFO] Building", noon);
    const second = stampRunChunk(first, " backend-api\n", noon);
    expect(first.startsWith("10:12:33.123 ")).toBe(true);
    expect(second).toBe(" backend-api\n");
    expect(`${first}${second}`).toBe("10:12:33.123 [INFO] Building backend-api\n");
  });

  test("leaves Spring Boot timestamps that start with ANSI styling alone", () => {
    const line = "\u001b[32m2026-08-08T10:12:33.123  INFO 1 --- [main] Started App\u001b[0m";
    expect(hasLeadingTime(line)).toBe(true);
    expect(stampOutput(`${line}\n`, false, noon)).toBe(`${line}\n`);
  });

  test("stamps colored Maven lines that have no clock of their own", () => {
    const stamped = stampOutput("\u001b[1m[INFO]\u001b[0m Building\n", false, noon);
    expect(stamped.startsWith("10:12:33.123 ")).toBe(true);
    expect(stamped.endsWith("\u001b[1m[INFO]\u001b[0m Building\n")).toBe(true);
  });

  test("does not stamp an ANSI-only prefix when the timestamp arrives in the next chunk", () => {
    const first = stampRunChunk("", "\u001b[32m", noon);
    const second = stampRunChunk(first, "2026-08-08T10:12:33.123  INFO started\n", noon);
    expect(first).toBe("\u001b[32m");
    expect(second).toBe("2026-08-08T10:12:33.123  INFO started\n");
  });
});
