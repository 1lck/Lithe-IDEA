import { expect, spyOn, test } from "bun:test";
import * as native from "@/platform/tauri-core";
import { renderMarkdown, renderMarkdownWhenReady } from "./render";

test("many notebook cells have bounded native work and aborted queued cells never invoke Core", async () => {
 const releases: Array<() => void> = []; let active = 0; let peak = 0;
 const invoke = spyOn(native, "invoke").mockImplementation(async () => {
  active++; peak = Math.max(peak, active);
  await new Promise<void>(resolve => releases.push(resolve)); active--;
  return { html: "<p>safe</p>" } as never;
 });
 const controllers = Array.from({length:66}, () => new AbortController());
 const requests = controllers.map((controller,index) => renderMarkdown(String(index), controller.signal).catch(error => error));
 try {
  expect(invoke).toHaveBeenCalledTimes(2);
  await expect(renderMarkdown("overflow")).rejects.toThrow("capacity");
  controllers.forEach(controller => controller.abort());
  releases.splice(0).forEach(release => release());
  const results = await Promise.all(requests);
  expect(results.every(result => result instanceof DOMException && result.name === "AbortError")).toBe(true);
  expect(peak).toBe(2); expect(invoke).toHaveBeenCalledTimes(2);
 } finally {
  controllers.forEach(controller => controller.abort()); releases.splice(0).forEach(release => release());
  await Promise.all(requests); invoke.mockRestore();
 }
});

test("mounted previews wait for capacity and eventually render after a burst", async () => {
 const releases: Array<() => void> = [];
 let active = 0; let peak = 0;
 const invoke = spyOn(native, "invoke").mockImplementation(async () => {
  active++; peak = Math.max(peak, active);
  await new Promise<void>(resolve => releases.push(resolve));
  active--;
  return { html: "<p>safe</p>" } as never;
 });
 const controllers = Array.from({length:70}, () => new AbortController());
 const requests = controllers.map((controller,index) => renderMarkdownWhenReady(String(index), controller.signal).catch(error => error));
 try {
  expect(invoke).toHaveBeenCalledTimes(2);
  for (let index = 0; index < requests.length; index++) {
   // Each completion drains one native job through a known microtask boundary.
   for (let turn = 0; turn < 20 && !releases[index]; turn++) await Promise.resolve();
   expect(releases[index]).toBeDefined();
   releases[index]!();
  }
  expect(await Promise.all(requests)).toEqual(Array(70).fill("<p>safe</p>"));
  expect(peak).toBe(2);
 } finally {
  controllers.forEach(controller => controller.abort());
  releases.forEach(release => release());
  await Promise.all(requests);
  invoke.mockRestore();
 }
});

test("a preview cancelled while waiting for capacity never starts native work", async () => {
 const releases: Array<() => void> = [];
 const invoke = spyOn(native, "invoke").mockImplementation(async () => {
  await new Promise<void>(resolve => releases.push(resolve));
  return { html: "<p>safe</p>" } as never;
 });
 const controllers = Array.from({length:67}, () => new AbortController());
 const requests = controllers.map((controller,index) => renderMarkdownWhenReady(String(index), controller.signal).catch(error => error));
 try {
  controllers[66]!.abort();
  const cancelled = await requests[66];
  expect(cancelled).toBeInstanceOf(DOMException);
  expect(cancelled.name).toBe("AbortError");
  expect(invoke).toHaveBeenCalledTimes(2);
 } finally {
  controllers.forEach(controller => controller.abort());
  releases.forEach(release => release());
  await Promise.all(requests);
  invoke.mockRestore();
 }
});
