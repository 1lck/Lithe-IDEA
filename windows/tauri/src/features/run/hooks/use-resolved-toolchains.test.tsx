import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import type { ResolvedToolchains } from "../api/run-host-api";
import {
  useResolvedToolchains,
  type ResolvedToolchainDependencies,
} from "./use-resolved-toolchains";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: Error) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}

function resolvedJava(path: string): ResolvedToolchains {
  const java = {
    status: "resolved",
    path,
    version: "21.0.4",
    vendor: "",
    source: "javaHome",
  } as const;
  return {
    java,
    maven: { status: "notFound", message: null },
    mavenJava: { ...java, source: "projectJdk" },
  };
}

const scheduled: Array<{ task: () => void; cancelled: boolean }> = [];
const requests: Array<{
  javaHomePath: string;
  result: ReturnType<typeof deferred<ResolvedToolchains>>;
}> = [];
// The typing pause is driven by the test, so no real timer decides the order.
const dependencies: ResolvedToolchainDependencies = {
  schedule: (task) => {
    const entry = { task, cancelled: false };
    scheduled.push(entry);
    return () => {
      entry.cancelled = true;
    };
  },
  resolve: (_root, selection) => {
    const result = deferred<ResolvedToolchains>();
    requests.push({ javaHomePath: selection.javaHomePath, result });
    return result.promise;
  },
};

let restoreDom: () => void;
let host: HTMLDivElement;
let root: Root;
const actEnvironment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousActEnvironment: boolean | undefined;

function Probe({ javaHomePath }: { javaHomePath: string }) {
  const state = useResolvedToolchains("C:/work", javaHomePath, "", "", dependencies);
  return <output>{state.java.status === "resolved" ? state.java.path : state.java.status}</output>;
}

beforeEach(() => {
  scheduled.length = 0;
  requests.length = 0;
  restoreDom = installHappyDom();
  previousActEnvironment = actEnvironment.IS_REACT_ACT_ENVIRONMENT;
  actEnvironment.IS_REACT_ACT_ENVIRONMENT = true;
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});

afterEach(() => {
  act(() => root.unmount());
  host.remove();
  actEnvironment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  restoreDom();
});

test("a replaced selection never overwrites the newer result", async () => {
  // Event order: first selection resolves slowly, the user changes the path,
  // the new selection resolves, and only then the stale result arrives.
  act(() => root.render(<Probe javaHomePath="C:/jdk-17" />));
  expect(host.textContent).toBe("detecting");
  act(() => scheduled[0].task());

  act(() => root.render(<Probe javaHomePath="C:/jdk-21" />));
  expect(scheduled[0].cancelled).toBe(true);
  act(() => scheduled[1].task());
  expect(requests.map((request) => request.javaHomePath)).toEqual(["C:/jdk-17", "C:/jdk-21"]);

  await act(async () => requests[1].result.resolve(resolvedJava("C:/jdk-21")));
  expect(host.textContent).toBe("C:/jdk-21");
  await act(async () => requests[0].result.resolve(resolvedJava("C:/jdk-17")));
  expect(host.textContent).toBe("C:/jdk-21");
});

test("a failed resolution is reported instead of staying in detection", async () => {
  act(() => root.render(<Probe javaHomePath="" />));
  act(() => scheduled[0].task());
  await act(async () => requests[0].result.reject(new Error("host unavailable")));
  expect(host.textContent).toBe("failed");
});

test("typing before the pause ends resolves only the final selection", () => {
  act(() => root.render(<Probe javaHomePath="C:/j" />));
  act(() => root.render(<Probe javaHomePath="C:/jdk" />));
  expect(scheduled.map((entry) => entry.cancelled)).toEqual([true, false]);
  act(() => scheduled[1].task());
  expect(requests.map((request) => request.javaHomePath)).toEqual(["C:/jdk"]);
});
