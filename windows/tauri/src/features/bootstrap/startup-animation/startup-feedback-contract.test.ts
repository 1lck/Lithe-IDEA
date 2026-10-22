import { expect, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/settings/startup-feedback-v1.json";
import {
  STARTUP_FADE_OUT_DURATION_MS,
  STARTUP_FAILURE_CODES,
  STARTUP_MINIMUM_VISIBLE_DURATION_MS,
  STARTUP_STAGES,
} from "./startup-stages";

test("the Windows startup phases match the shared startup feedback contract", () => {
  expect(STARTUP_STAGES.map((stage) => stage.id).join(",")).toBe(
    fixture.stages.map((stage) => stage.id).join(","),
  );
  expect(STARTUP_STAGES.map((stage) => stage.order).join(",")).toBe(
    fixture.stages.map((stage) => stage.order).join(","),
  );
  expect(STARTUP_STAGES.map((stage) => stage.labelKey).join(",")).toBe(
    fixture.stages.map((stage) => stage.labelKey).join(","),
  );
  expect(STARTUP_STAGES.map((stage) => stage.progress).join(",")).toBe(
    fixture.stages.map((stage) => stage.progress).join(","),
  );
  expect(STARTUP_STAGES.map((stage) => stage.labels.en).join(",")).toBe(
    fixture.stages.map((stage) => stage.labels.en).join(","),
  );
  expect(STARTUP_STAGES.map((stage) => stage.labels.zhHans).join(",")).toBe(
    fixture.stages.map((stage) => stage.labels.zhHans).join(","),
  );
});

test("the Windows startup timings match the shared startup feedback contract", () => {
  expect(STARTUP_MINIMUM_VISIBLE_DURATION_MS).toBe(fixture.minimumVisibleDurationMs);
  expect(STARTUP_FADE_OUT_DURATION_MS).toBe(fixture.fadeOutDurationMs);
});

test("the Windows startup failure codes match the shared startup feedback contract", () => {
  expect(STARTUP_FAILURE_CODES.join(",")).toBe(fixture.failureCodes.join(","));
});
