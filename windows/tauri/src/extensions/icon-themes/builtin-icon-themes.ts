import type { ExtensionManifest } from "../types/extension-manifest";

export const builtinIconThemes = [
  {
    id: "idea-icons",
    name: "IDEA Icons",
    load: () =>
      import("../bundled/icon-themes/idea/extension.json").then(
        (module) => module.default as ExtensionManifest,
      ),
  },
  {
    id: "symbols",
    name: "Symbols",
    load: () =>
      import("../bundled/icon-themes/symbols/extension.json").then(
        (module) => module.default as ExtensionManifest,
      ),
  },
  {
    id: "pierre-icons-minimal",
    name: "Pierre Icons (Minimal)",
    load: () =>
      import("../bundled/icon-themes/pierre/extension.json").then(
        (module) => module.default as ExtensionManifest,
      ),
  },
  {
    id: "pierre-icons",
    name: "Pierre Icons",
    load: () =>
      import("../bundled/icon-themes/pierre/extension.json").then(
        (module) => module.default as ExtensionManifest,
      ),
  },
  {
    id: "pierre-icons-complete",
    name: "Pierre Icons (Complete)",
    load: () =>
      import("../bundled/icon-themes/pierre/extension.json").then(
        (module) => module.default as ExtensionManifest,
      ),
  },
  {
    id: "material",
    name: "Material",
    load: () =>
      import("../bundled/icon-themes/material/extension.json").then(
        (module) => module.default as ExtensionManifest,
      ),
  },
] as const;
