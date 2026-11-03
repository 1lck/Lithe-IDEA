import { afterEach, describe, expect, test } from "bun:test";
import {
  createHiddenModelRefresh,
  isMonacoModelOnlyHidden,
  registerMonacoSurface,
  resetMonacoSurfacesForTests,
} from "./surface-visibility";

const URI = "lithe:/C:/work/Main.java";

afterEach(() => {
  resetMonacoSurfacesForTests();
});

describe("Monaco surface visibility", () => {
  test("never treats a model without registered surfaces as hidden", () => {
    expect(isMonacoModelOnlyHidden(URI)).toBe(false);
    const refresh = createHiddenModelRefresh(() => {});
    expect(refresh.skipIfHidden(URI)).toBe(false);
  });

  test("treats a model as hidden only while every surface showing it is hidden", () => {
    const first = registerMonacoSurface(URI, false);
    expect(isMonacoModelOnlyHidden(URI)).toBe(true);

    const second = registerMonacoSurface(URI, true);
    expect(isMonacoModelOnlyHidden(URI)).toBe(false);

    second.setVisible(false);
    expect(isMonacoModelOnlyHidden(URI)).toBe(true);

    first.dispose();
    second.dispose();
    expect(isMonacoModelOnlyHidden(URI)).toBe(false);
  });

  test("refreshes once when a skipped model is shown again", () => {
    let refreshes = 0;
    const refresh = createHiddenModelRefresh(() => {
      refreshes++;
    });
    const surface = registerMonacoSurface(URI, false);

    expect(refresh.skipIfHidden(URI)).toBe(true);
    expect(refresh.skipIfHidden(URI)).toBe(true);
    surface.setVisible(true);
    expect(refreshes).toBe(1);

    surface.setVisible(false);
    surface.setVisible(true);
    expect(refreshes).toBe(1);
    refresh.dispose();
  });

  test("ignores updates after dispose and repeated visibility values", () => {
    let refreshes = 0;
    const refresh = createHiddenModelRefresh(() => {
      refreshes++;
    });
    const surface = registerMonacoSurface(URI, false);
    refresh.skipIfHidden(URI);

    surface.setVisible(false);
    surface.dispose();
    surface.dispose();
    surface.setVisible(true);

    expect(refreshes).toBe(0);
    expect(isMonacoModelOnlyHidden(URI)).toBe(false);
    refresh.dispose();
  });
});
