import { ExtensionProcessOwner } from "@/extensions/run/extension-process-owner";

/**
 * Process ownership for contract v1 plugin runs. The lifecycle rules are the
 * Worker extension model's (stop on disable/uninstall/workspace close), so
 * the same owner class is reused with a plugin-ID key.
 */
export const declarativePluginProcessOwner = new ExtensionProcessOwner();
