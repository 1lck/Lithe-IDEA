export interface GitFileStageActionEvent {
  stopPropagation: () => void;
}

export interface GitFileStagePointerDownEvent extends GitFileStageActionEvent {
  preventDefault: () => void;
}

export function getGitFileStageActionState(
  staged: boolean,
  pending: boolean,
  disabled = false,
) {
  return {
    targetStaged: !staged,
    disabled: disabled || pending,
    busy: pending,
  };
}

export function prepareGitFileStageAction(event: GitFileStagePointerDownEvent) {
  event.preventDefault();
  event.stopPropagation();
}

export function activateGitFileStageAction(
  event: GitFileStageActionEvent,
  targetStaged: boolean,
  onStagedChange: (staged: boolean) => void,
) {
  event.stopPropagation();
  onStagedChange(targetStaged);
}
