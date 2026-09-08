export const BACKEND_UNAVAILABLE_TOOLTIP = "待开发";

export const backendCapabilities = {
  agent: false,
  database: false,
  debugger: true,
  docker: false,
  extensions: false,
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
