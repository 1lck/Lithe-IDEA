import { describe, expect, test } from "bun:test";
import platformContract from "../../../../../../shared/fixtures/maven/platform-contract-v1.json";
import sourceRootContract from "../../../../../../shared/fixtures/maven/source-roots-v1.json";
import { MAVEN_LIFECYCLE_PHASES, MAVEN_SOURCE_ROOT_KINDS } from "./maven.types";

describe("Maven platform contract", () => {
  test("keeps the Windows lifecycle phases aligned with the shared fixture", () => {
    expect(platformContract.lifecyclePhases).toEqual([...MAVEN_LIFECYCLE_PHASES]);
  });

  test("keeps Maven source-root kinds aligned with the shared fixture", () => {
    expect(sourceRootContract.kindOrder).toEqual([...MAVEN_SOURCE_ROOT_KINDS]);
  });
});
