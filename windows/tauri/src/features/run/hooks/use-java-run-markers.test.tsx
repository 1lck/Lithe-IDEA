import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import type { JavaRunMarker, JavaRunSources } from "../services/java-run-markers";
import { useJavaRunMarkers } from "./use-java-run-markers";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: Error) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

const scope = { workspaceId: "run-marker-test", root: "C:/work" };
const emptySources: JavaRunSources = { mainMethods: [], testItems: [] };
const marker: JavaRunMarker = {
  line: 9, endLine: 9, kind: "main", label: "App.main()", mainClass: "demo.App", status: "none",
};
const requests: ReturnType<typeof deferred<JavaRunSources>>[] = [];
const projections: ReturnType<typeof deferred<JavaRunMarker[]>>[] = [];
let subscriptions = 0;
const dependencies = {
  discover: () => {
    const request = deferred<JavaRunSources>();
    requests.push(request);
    return request.promise;
  },
  project: () => {
    const projection = deferred<JavaRunMarker[]>();
    projections.push(projection);
    return projection.promise;
  },
  whenPrepared: () => {
    subscriptions++;
    return () => { subscriptions--; };
  },
  trace: () => {},
};

let restoreDom: () => void;
let host: HTMLDivElement;
let root: Root;
const actEnvironment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousActEnvironment: boolean | undefined;

function Editor({ source, file = "C:/work/App.java" }: { source: string; file?: string }) {
  const state = useJavaRunMarkers(scope, file, source, true, true, "ready", dependencies);
  return <>{state.markers.map((value) => <button key={value.label} data-line={value.line}>{value.label}</button>)}</>;
}

beforeEach(() => {
  requests.length = 0;
  projections.length = 0;
  subscriptions = 0;
  restoreDom = installHappyDom();
  previousActEnvironment = actEnvironment.IS_REACT_ACT_ENVIRONMENT;
  actEnvironment.IS_REACT_ACT_ENVIRONMENT = true;
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});

afterEach(async () => {
  try {
    await act(async () => {
      root.unmount();
      // Release every controlled operation even when an assertion fails.
      for (const request of requests) request.resolve(emptySources);
      for (const projection of projections) projection.resolve([]);
      await Promise.allSettled([...requests, ...projections].map((operation) => operation.promise));
    });
    expect(subscriptions).toBe(0);
  } finally {
    host.remove();
    if (previousActEnvironment === undefined) delete actEnvironment.IS_REACT_ACT_ENVIRONMENT;
    else actEnvironment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
    restoreDom();
  }
});

async function render(source: string, file?: string) {
  await act(async () => root.render(<Editor source={source} file={file} />));
}

async function discover(index: number) {
  await act(async () => {
    requests[index]!.resolve(emptySources);
    await requests[index]!.promise;
  });
}

async function project(index: number, markers = [marker]) {
  await act(async () => {
    projections[index]!.resolve(markers);
    await projections[index]!.promise;
  });
}

test("editing disables old targets while discovery is pending and after it fails", async () => {
  await render("class App {}");
  await discover(0);
  await project(0);
  expect(host.querySelector("button")?.getAttribute("data-line")).toBe("9");

  await render("\n\nclass App {}");
  expect(host.querySelector("button")).toBeNull();
  await act(async () => {
    requests[1]!.reject(new Error("JDT unavailable"));
    await requests[1]!.promise.catch(() => {});
  });
  expect(host.querySelector("button")).toBeNull();
});

test("a late projection cannot restore pre-edit positions", async () => {
  await render("class App {}");
  await discover(0);
  await render("\n\nclass App {}");
  await project(0);
  expect(host.querySelector("button")).toBeNull();
  await discover(1);
  await project(1, [{ ...marker, line: 11, endLine: 11 }]);
  expect(host.querySelector("button")?.getAttribute("data-line")).toBe("11");
});

test("a late discovery from a closed file cannot become another file's targets", async () => {
  await render("class App {}");
  await render("class Other {}", "C:/work/Other.java");
  await discover(0);
  expect(projections).toHaveLength(0);
  expect(host.querySelector("button")).toBeNull();
  await discover(1);
  await project(0, [{ ...marker, label: "Other.main()", mainClass: "demo.Other" }]);
  expect(host.textContent).toBe("Other.main()");
});
