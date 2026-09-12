import { expect, mock, test } from "bun:test";
import {
  activateGitFileStageAction,
  getGitFileStageActionState,
  prepareGitFileStageAction,
} from "./git-file-stage-action";

test("Git file stage action resolves stage and unstage state", () => {
  expect(getGitFileStageActionState(false, false)).toEqual({
    targetStaged: true,
    disabled: false,
    busy: false,
  });
  expect(getGitFileStageActionState(true, true)).toEqual({
    targetStaged: false,
    disabled: true,
    busy: true,
  });
  expect(getGitFileStageActionState(false, false, true).disabled).toBe(true);
});

test("Git file stage action blocks row pointer handling", () => {
  const preventDefault = mock(() => {});
  const stopPropagation = mock(() => {});

  prepareGitFileStageAction({ preventDefault, stopPropagation });

  expect(preventDefault).toHaveBeenCalledTimes(1);
  expect(stopPropagation).toHaveBeenCalledTimes(1);
});

test("Git file stage action changes only the staged state", () => {
  const stopPropagation = mock(() => {});
  const onStagedChange = mock(() => {});

  activateGitFileStageAction({ stopPropagation }, false, onStagedChange);

  expect(stopPropagation).toHaveBeenCalledTimes(1);
  expect(onStagedChange).toHaveBeenCalledTimes(1);
  expect(onStagedChange).toHaveBeenCalledWith(false);
});
