import { Window } from "happy-dom";

const DOM_GLOBALS = [
  "window",
  "self",
  "document",
  "navigator",
  "Element",
  "HTMLElement",
  "HTMLInputElement",
  "HTMLTextAreaElement",
  "Node",
  "Event",
  "EventTarget",
  "KeyboardEvent",
  "MutationObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;

export function installHappyDom(): () => void {
  const window = new Window({ url: "http://localhost" });
  const previousGlobals = new Map<string, PropertyDescriptor | undefined>();

  for (const key of DOM_GLOBALS) {
    previousGlobals.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    const value = key === "window" || key === "self" ? window : window[key];
    Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });
  }

  return () => {
    window.close();
    for (const [key, descriptor] of previousGlobals) {
      if (descriptor) {
        Object.defineProperty(globalThis, key, descriptor);
      } else {
        Reflect.deleteProperty(globalThis, key);
      }
    }
  };
}
