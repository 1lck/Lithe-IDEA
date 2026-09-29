import {
  ArrowsInIcon as ExitFullscreen,
  ArrowsOutIcon as FullScreen,
  CopyIcon as Restore,
  MinusIcon as Minimize,
  SquareIcon as Maximize,
} from "@/ui/icons";
import {
  minimizeCurrentWindow,
  toggleCurrentWindowFullscreen,
  toggleCurrentWindowMaximize,
} from "@/features/window/utils/window-actions";
import type { Action } from "../types/action.types";

interface WindowActionsParams {
  onClose: () => void;
  isMaximized: boolean;
  isFullscreen: boolean;
  operations?: WindowActionOperations;
}

interface WindowActionOperations {
  minimize: typeof minimizeCurrentWindow;
  toggleMaximize: typeof toggleCurrentWindowMaximize;
  toggleFullscreen: typeof toggleCurrentWindowFullscreen;
}

const windowActionOperations: WindowActionOperations = {
  minimize: minimizeCurrentWindow,
  toggleMaximize: toggleCurrentWindowMaximize,
  toggleFullscreen: toggleCurrentWindowFullscreen,
};

export const createWindowActions = (params: WindowActionsParams): Action[] => {
  const { onClose, isMaximized, isFullscreen, operations = windowActionOperations } = params;

  return [
    {
      id: "window-minimize",
      label: "Window: Minimize",
      description: "Minimize the window",
      icon: <Minimize />,
      category: "Window",
      action: runWindowAction(onClose, operations.minimize, "minimizing"),
    },
    {
      id: isMaximized ? "window-restore" : "window-maximize",
      label: isMaximized ? "Window: Restore" : "Window: Maximize",
      description: isMaximized ? "Restore the window" : "Maximize the window",
      icon: isMaximized ? <Restore /> : <Maximize />,
      category: "Window",
      action: runWindowAction(
        onClose,
        operations.toggleMaximize,
        isMaximized ? "restoring" : "maximizing",
      ),
    },
    {
      id: isFullscreen ? "window-exit-fullscreen" : "window-enter-fullscreen",
      label: isFullscreen ? "Window: Exit Fullscreen" : "Window: Enter Fullscreen",
      description: isFullscreen ? "Exit fullscreen mode" : "Enter fullscreen mode",
      icon: isFullscreen ? <ExitFullscreen /> : <FullScreen />,
      category: "Window",
      commandId: "window.toggleFullscreen",
      action: runWindowAction(onClose, operations.toggleFullscreen, "toggling fullscreen"),
    },
  ];
};

function runWindowAction(
  onClose: () => void,
  action: () => Promise<void>,
  operation: string,
): () => Promise<void> {
  return async () => {
    try {
      await action();
      onClose();
    } catch (error) {
      console.error(`Error ${operation}:`, error);
    }
  };
}
