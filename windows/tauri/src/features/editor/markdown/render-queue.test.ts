import { expect, spyOn, test } from "bun:test";
import * as native from "@/platform/tauri-core";
import { renderMarkdown } from "./render";

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
