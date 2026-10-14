import { expect, test } from "bun:test";
import { loadDefaultProjectLocation } from "./new-project-model";

function harness() {
  let resolve!: (value: string) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<string>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  const home = { promise, resolve, reject };
  let location = "";
  const cancel = loadDefaultProjectLocation(
    () => home.promise,
    (update) => {
      location = update(location);
    },
  );
  return {
    home,
    cancel,
    choose: (value: string) => {
      location = value;
    },
    current: () => location,
  };
}

test("fills an untouched location with the native default", async () => {
  const h = harness();
  h.home.resolve("D:/home");
  await h.home.promise;
  expect(h.current()).toBe("D:/home");
});

test("a late home-directory answer never replaces a location the user typed", async () => {
  const h = harness();
  h.choose("D:/projects");
  h.home.resolve("C:/Users/example");
  await h.home.promise;
  expect(h.current()).toBe("D:/projects");
});

test("closing the wizard retires its pending default-location answer", async () => {
  const h = harness();
  h.cancel();
  h.home.resolve("D:/home");
  await h.home.promise;
  expect(h.current()).toBe("");
});

test("failure to read the home directory leaves the user's location intact", async () => {
  const h = harness();
  h.choose("D:/projects");
  h.home.reject(new Error("Home directory unavailable"));
  await h.home.promise.catch(() => {});
  expect(h.current()).toBe("D:/projects");
});
