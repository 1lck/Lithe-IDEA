import { expect, test } from "bun:test";
import {
  languageServerFeedbackId,
  languageServerInteractiveToastOptions,
  languageServerPreparingToastOptions,
} from "./language-server-feedback-options";

test("uses one workspace identity across Java lifecycle path formats", () => {
  expect(languageServerFeedbackId("C:\\Work", "java")).toBe(
    languageServerFeedbackId("c:/work", "java"),
  );
});

test("keeps preparation non-blocking and restores interaction for its outcome", () => {
  expect(languageServerPreparingToastOptions("C:/Work", "java")).toEqual({
    id: "c:/work:java",
    duration: Number.POSITIVE_INFINITY,
    className: "pointer-events-none",
    closeButton: false,
  });
  expect(languageServerInteractiveToastOptions("c:\\work", "java")).toEqual({
    id: "c:/work:java",
    className: "",
    closeButton: true,
  });
});
