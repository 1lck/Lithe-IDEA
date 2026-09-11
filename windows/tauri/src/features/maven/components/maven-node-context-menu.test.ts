import { describe, expect, test } from "bun:test";
import { resolveMavenModuleMenuAvailability } from "./maven-node-context-menu";

describe("Maven node context-menu availability", () => {
  test("keeps independent actions available for an idle runnable module", () => {
    expect(
      resolveMavenModuleMenuAvailability({
        busy: false,
        canRun: true,
        canDebug: true,
        debugging: false,
        reloading: false,
      }),
    ).toEqual({
      runDisabled: false,
      debugDisabled: false,
      buildDisabled: false,
      reloadDisabled: false,
    });
  });

  test("disables launch and build actions while another module operation is starting", () => {
    expect(
      resolveMavenModuleMenuAvailability({
        busy: true,
        canRun: true,
        canDebug: true,
        debugging: false,
        reloading: false,
      }),
    ).toEqual({
      runDisabled: true,
      debugDisabled: true,
      buildDisabled: true,
      reloadDisabled: true,
    });
  });

  test("disables only capabilities that are unavailable outside a Maven task", () => {
    expect(
      resolveMavenModuleMenuAvailability({
        busy: false,
        canRun: false,
        canDebug: true,
        debugging: true,
        reloading: true,
      }),
    ).toEqual({
      runDisabled: true,
      debugDisabled: true,
      buildDisabled: false,
      reloadDisabled: true,
    });
  });
});
