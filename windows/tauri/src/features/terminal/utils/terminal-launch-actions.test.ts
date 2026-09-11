import { expect, mock, test } from "bun:test";
import { createDefaultTerminalHandler } from "./terminal-launch-actions";

test("default terminal action does not forward a UI event as a profile ID", () => {
  const createTerminalWithProfile = mock((_profileId?: string) => {});
  const handleDefaultTerminal = createDefaultTerminalHandler(createTerminalWithProfile);

  (handleDefaultTerminal as (event: unknown) => void)({ type: "click" });

  expect(createTerminalWithProfile).toHaveBeenCalledTimes(1);
  expect(createTerminalWithProfile).toHaveBeenCalledWith();
});
