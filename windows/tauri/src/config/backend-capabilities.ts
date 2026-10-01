export const BACKEND_UNAVAILABLE_TOOLTIP = "待开发";

export const backendCapabilities = {
  // The Agent host is the shared `lithe-agent-host`, so the Windows panel's
  // management commands are backed. `aiChat` is the legacy `features/ai` family
  // that never had a Windows backend and is removed by #957.
  agent: true,
  aiChat: false,
  database: false,
  debugger: true,
  docker: false,
  extensions: true,
  git: true,
  github: false,
  remote: false,
  run: true,
  runActions: false,
  terminal: true,
  wsl: false,
} as const;

export type BackendCapability = keyof typeof backendCapabilities;

export function isBackendCapabilityAvailable(capability: BackendCapability): boolean {
  return backendCapabilities[capability];
}
