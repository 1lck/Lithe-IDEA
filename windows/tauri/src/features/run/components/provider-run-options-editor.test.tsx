import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act, useState, type ChangeEvent, type ComponentProps } from "react";
import { createRoot, type Root } from "react-dom/client";
import * as virtualization from "@tanstack/react-virtual";
import * as inputControl from "@/ui/input";
import * as textareaControl from "@/ui/textarea";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import { ProviderRunOptionsEditor } from "./provider-run-options-editor";
import { RunConfigurationEditor } from "./run-configuration-editor";
import { EMPTY_GLOBAL_TOOLCHAIN, EMPTY_RUN_OPTIONS, type BuildProviderRunOptions, type RunConfiguration, type RunOptions } from "../types/run.types";
import argumentFixture from "../../../../../../shared/fixtures/run-configuration/argument-text.json";

let restoreDom: () => void, host: HTMLDivElement, root: Root;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
beforeEach(() => {
  restoreDom = installHappyDom(); previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT; actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
});
afterEach(() => { act(() => root.unmount()); host.remove(); actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct; restoreDom(); });

test("runtime argument rows retain exact values and preserve unrelated provider options and tool choices", () => {
  // The shared Input owns DOM events. Invoke its controlled callback here,
  // while the real editor, state and buttons handle every change.
  const control = spyOn(inputControl, "default").mockImplementation(((props: ComponentProps<typeof inputControl.default>) => {
    const { size: _size, variant: _variant, ...rest } = props;
    return <input {...rest} onInput={event => props.onChange?.(event as unknown as ChangeEvent<HTMLInputElement>)} />;
  }) as unknown as typeof inputControl.default);
  const textControl = spyOn(textareaControl, "default").mockImplementation(((props: ComponentProps<typeof textareaControl.default>) => {
    const { size: _size, variant: _variant, ...rest } = props;
    return <textarea {...rest} onInput={event => props.onChange?.(event as unknown as ChangeEvent<HTMLTextAreaElement>)} />;
  }) as unknown as typeof textareaControl.default);
  const values = argumentFixture.cases.flatMap(entry => entry.values);
  const virtual = spyOn(virtualization, "useVirtualizer").mockImplementation(((options: { count: number }) => ({
    getTotalSize: () => options.count * 36,
    getVirtualItems: () => Array.from({ length: options.count }, (_, index) => ({ index, key: index, start: index * 36, size: 36 })),
  })) as unknown as typeof virtualization.useVirtualizer);
  let latest: BuildProviderRunOptions | undefined;
  const initial: BuildProviderRunOptions = { runtimeArguments: values, entrypoint: "opaque entry",
    options: { offline: false }, tools: { "dev.example:compiler": { executable: "C:/tools/compiler.cmd" } } };
  function Probe() {
    const [value, setValue] = useState(initial); latest = value;
    return <ProviderRunOptionsEditor value={value} onChange={setValue} />;
  }
  try {
    act(() => root.render(<LocaleProvider language="en-US"><Probe /></LocaleProvider>));
    const arguments_ = Array.from(host.querySelectorAll<HTMLTextAreaElement>('textarea[aria-label^="Argument "]'));
    expect(arguments_.map(input => input.value)).toEqual(values);
    const entry = host.querySelector<HTMLInputElement>('#run-provider-entrypoint')!;
    act(() => { entry.value = "another/entry 雪"; entry.dispatchEvent(new Event("input", { bubbles: true })); });
    expect(latest?.runtimeArguments).toEqual(values);
    expect(latest?.entrypoint).toBe("another/entry 雪");
    const first = arguments_[0]!;
    act(() => { first.value = "  quoted \"value\" \\tail  "; first.dispatchEvent(new Event("input", { bubbles: true })); });
    expect(latest?.runtimeArguments[0]).toBe("  quoted \"value\" \\tail  ");
    act(() => Array.from(host.querySelectorAll<HTMLButtonElement>("button")).find(button => button.textContent?.includes("Add argument"))!.click());
    expect(latest?.runtimeArguments[latest.runtimeArguments.length - 1]).toBe("");
    act(() => host.querySelector<HTMLButtonElement>('button[aria-label="Remove"]')!.click());
    expect(latest?.runtimeArguments).toEqual([...values.slice(1), ""]);
    expect(latest?.options).toEqual(initial.options); expect(latest?.tools).toEqual(initial.tools);
    expect(initial.runtimeArguments).toEqual(values);
  } finally { virtual.mockRestore(); control.mockRestore(); textControl.mockRestore(); }
}, 5000);

test("large saved runtime argument lists mount only visible controls and retain all values", () => {
  const virtual = spyOn(virtualization, "useVirtualizer").mockImplementation((() => ({
    getTotalSize: () => 1024 * 36,
    getVirtualItems: () => Array.from({ length: 10 }, (_, index) => ({ index, key: index, start: index * 36, size: 36 })),
  })) as unknown as typeof virtualization.useVirtualizer);
  const values = Array.from({ length: 1024 }, (_, index) => `argument ${index}`);
  let changed = false;
  try {
    act(() => root.render(<LocaleProvider language="zh-CN"><ProviderRunOptionsEditor value={{ runtimeArguments: values, entrypoint: "", options: {} }}
      onChange={() => { changed = true; }} /></LocaleProvider>));
    expect(host.querySelectorAll("textarea").length).toBe(10);
    expect(host.querySelectorAll("input").length).toBe(1);
    const add = Array.from(host.querySelectorAll<HTMLButtonElement>("button")).find(button => button.textContent?.includes("添加参数"))!;
    expect(add.disabled).toBe(true); expect(changed).toBe(false); expect(values).toHaveLength(1024);
  } finally { virtual.mockRestore(); }
}, 5000);

test("opening an older provider selector does not materialize a new saved override", () => {
  let changed = false;
  act(() => root.render(<LocaleProvider language="en-US"><ProviderRunOptionsEditor onChange={() => { changed = true; }} /></LocaleProvider>));
  expect(host.querySelectorAll("input").length).toBe(1); expect(changed).toBe(false);
}, 5000);

test("the Run dialog saves provider runtime choices through its existing explicit save action", async () => {
  const control = spyOn(inputControl, "default").mockImplementation(((props: ComponentProps<typeof inputControl.default>) => {
    const { size: _size, variant: _variant, ...rest } = props;
    return <input {...rest} onInput={event => props.onChange?.(event as unknown as ChangeEvent<HTMLInputElement>)} />;
  }) as unknown as typeof inputControl.default);
  const textControl = spyOn(textareaControl, "default").mockImplementation(((props: ComponentProps<typeof textareaControl.default>) => {
    const { size: _size, variant: _variant, ...rest } = props;
    return <textarea {...rest} onInput={event => props.onChange?.(event as unknown as ChangeEvent<HTMLTextAreaElement>)} />;
  }) as unknown as typeof textareaControl.default);
  const providerOptions: BuildProviderRunOptions = { runtimeArguments: ["first", ""], entrypoint: "original", options: { offline: false },
    tools: { "dev.example:compiler": { executable: "C:/tools/compiler.cmd" } } };
  const configuration: RunConfiguration = { id: "provider-run", name: "Provider task", provider: "build", kindTitle: "Task",
    execution: "task", category: "project", cwd: ".", args: [], env: {}, jvmArguments: [], programArguments: [], profiles: [],
    mavenSkipTests: null, javaHomePath: "", mavenExecutablePath: "", mavenJavaHomePath: "", toolchains: {}, source: "local", disabled: false,
    buildProvider: { pluginID: "dev.example.engine", buildSystemID: "engine", root: ".", run: "task", projectID: "project", targetID: "target", userArguments: [] } };
  let saved: RunOptions | undefined, scope: string | undefined, closed = false;
  try {
    act(() => root.render(<LocaleProvider language="en-US"><RunConfigurationEditor root="C:/fixture" configuration={configuration}
      diagnostics={[]} mavenSelection={null} options={{ ...EMPTY_RUN_OPTIONS, providerRunOptions: providerOptions }} saveError={null}
      discoveredJava={[]} discoveredMaven={[]} discoveredRuntimes={[]} globalToolchain={EMPTY_GLOBAL_TOOLCHAIN}
      onClose={() => { closed = true; }} onSave={async (options, _toolchain, selectedScope) => { saved = options; scope = selectedScope; return true; }} /></LocaleProvider>));
    expect(host.querySelector("#run-vm-args")).toBeNull();
    const runtime = host.querySelector<HTMLTextAreaElement>('textarea[aria-label="Argument 1"]')!;
    const entry = host.querySelector<HTMLInputElement>("#run-provider-entrypoint")!;
    act(() => { runtime.value = "  quoted \"argument\"\nnext line  "; runtime.dispatchEvent(new Event("input", { bubbles: true })); });
    act(() => { entry.value = "opaque/entry 雪"; entry.dispatchEvent(new Event("input", { bubbles: true })); });
    expect(saved).toBeUndefined(); expect(closed).toBe(false);
    await act(async () => { Array.from(host.querySelectorAll<HTMLButtonElement>("button")).find(button => button.textContent === "Save")!.click(); });
    expect(saved?.providerRunOptions).toEqual({ ...providerOptions, runtimeArguments: ["  quoted \"argument\"\nnext line  ", ""], entrypoint: "opaque/entry 雪" });
    expect(scope).toBe("local"); expect(closed).toBe(true);
    expect(providerOptions.runtimeArguments).toEqual(["first", ""]);
  } finally { control.mockRestore(); textControl.mockRestore(); }
}, 5000);
