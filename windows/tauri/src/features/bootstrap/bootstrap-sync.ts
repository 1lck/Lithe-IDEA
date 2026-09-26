import { initializeKeymaps } from "@/features/keymaps/services/keymaps-init";

export function runSynchronousBootstrapSteps() {
  initializeKeymaps();
}
