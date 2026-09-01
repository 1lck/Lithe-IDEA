import { describe, expect, test } from "bun:test";
import platformContract from "../../../../../../shared/fixtures/maven/platform-contract-v1.json";
import { MAVEN_LIFECYCLE_PHASES } from "./maven.types";

describe("Maven platform contract", () => {
  test("keeps the Windows lifecycle phases aligned with the shared fixture", () => {
    expect(platformContract.lifecyclePhases).toEqual([...MAVEN_LIFECYCLE_PHASES]);
  });
});
