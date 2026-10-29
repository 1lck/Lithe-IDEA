import {
  BugIcon,
  GearIcon,
  MagnifyingGlassIcon,
  PlusIcon,
  ProblemsToolWindowIcon,
  RefreshIcon,
  RunToolWindowIcon,
  TerminalWindowIcon,
  TrashIcon,
  VcsIcon,
} from "@/ui/icons";
import componentsLight from "./icons/idea/expui/toolwindows/toolWindowComponents@20x20.svg?url";
import componentsDark from "./icons/idea/expui/toolwindows/toolWindowComponents@20x20_dark.svg?url";
import pluginLight from "./icons/idea/expui/nodes/plugin.svg?url";
import pluginDark from "./icons/idea/expui/nodes/plugin_dark.svg?url";
import databaseLight from "./icons/idea/database/expui/dbms@20x20.svg?url";
import databaseDark from "./icons/idea/database/expui/dbms@20x20_dark.svg?url";
import servicesLight from "./icons/idea/expui/toolwindows/services@20x20.svg?url";
import servicesDark from "./icons/idea/expui/toolwindows/services@20x20_dark.svg?url";
import resetLight from "./icons/idea/expui/general/reset.svg?url";
import resetDark from "./icons/idea/expui/general/reset_dark.svg?url";

// Core's declarative.rs HOST_IDS is authoritative. These fixed resources are
// byte-identical to the approved macOS WorkbenchContributionIcon assets; no
// plugin-controlled path or dynamic icon import crosses this presentation map.
const hostIcons = {
  "tool-window": { light: componentsLight, dark: componentsDark, size: 20 },
  plugin: { light: pluginLight, dark: pluginDark, size: 16 },
  database: { light: databaseLight, dark: databaseDark, size: 20 },
  services: { light: servicesLight, dark: servicesDark, size: 20 },
  terminal: TerminalWindowIcon,
  search: MagnifyingGlassIcon,
  refresh: RefreshIcon,
  reset: { light: resetLight, dark: resetDark, size: 16 },
  run: RunToolWindowIcon,
  debug: BugIcon,
  settings: GearIcon,
  add: PlusIcon,
  remove: TrashIcon,
  git: VcsIcon,
  problems: ProblemsToolWindowIcon,
} as const;

export function PluginHostIcon({ host, className }: { host: string; className?: string }) {
  // Core rejects unknown IDs. Keep this adapter closed even for unvalidated
  // callers (including object prototype names), rather than guessing an icon.
  if (!Object.prototype.hasOwnProperty.call(hostIcons, host)) return null;
  const icon = hostIcons[host as keyof typeof hostIcons];
  if (!("light" in icon)) {
    const Icon = icon;
    return <Icon className={className} />;
  }
  return (
    <svg
      aria-hidden="true"
      className={`lithe-idea-icon ${className ?? ""}`}
      viewBox={`0 0 ${icon.size} ${icon.size}`}
      width="1em"
      height="1em"
      fill="none"
    >
      <image
        href={icon.light}
        className="lithe-idea-icon-light"
        width={icon.size}
        height={icon.size}
      />
      <image
        href={icon.dark}
        className="lithe-idea-icon-dark"
        width={icon.size}
        height={icon.size}
      />
    </svg>
  );
}
