// Shared IPC channel names
export const IPC = {
  // File operations
  FILE_READ: 'file:read',
  FILE_WRITE: 'file:write',
  FILE_EXISTS: 'file:exists',
  FILE_STAT: 'file:stat',
  FILE_DELETE: 'file:delete',
  FILE_RENAME: 'file:rename',
  FILE_CREATE: 'file:create',
  FILE_REVEAL: 'file:reveal',
  FILE_PICK_DIRECTORY: 'file:pick-directory',

  // Project operations
  PROJECT_OPEN_DIALOG: 'project:open-dialog',
  PROJECT_SCAN: 'project:scan',
  PROJECT_WATCH_START: 'project:watch-start',
  PROJECT_WATCH_STOP: 'project:watch-stop',
  PROJECT_RECENT_LIST: 'project:recent-list',
  PROJECT_RECENT_ADD: 'project:recent-add',
  PROJECT_RECENT_REMOVE: 'project:recent-remove',

  // Terminal
  TERMINAL_CREATE: 'terminal:create',
  TERMINAL_WRITE: 'terminal:write',
  TERMINAL_RESIZE: 'terminal:resize',
  TERMINAL_DESTROY: 'terminal:destroy',
  TERMINAL_DATA: 'terminal:data',
  TERMINAL_EXEC: 'terminal:exec',
  TERMINAL_EXIT: 'terminal:exit',
  TERMINAL_COMPLETE: 'terminal:complete',
  TERMINAL_CD: 'terminal:cd',
  TERMINAL_CWD: 'terminal:cwd',
  TERMINAL_INTERRUPT: 'terminal:interrupt',

  // Local static server
  LOCAL_SERVER_START: 'local-server:start',
  LOCAL_SERVER_STOP: 'local-server:stop',
  LOCAL_SERVER_STATUS: 'local-server:status',
  LOCAL_SERVER_OPEN: 'local-server:open',

  // Git operations
  GIT_STATUS: 'git:status',
  GIT_LOG: 'git:log',
  GIT_DIFF: 'git:diff',
  GIT_BRANCH_LIST: 'git:branch-list',
  GIT_BRANCH_SWITCH: 'git:branch-switch',
  GIT_BRANCH_CREATE: 'git:branch-create',
  GIT_BRANCH_DELETE: 'git:branch-delete',
  GIT_COMMIT: 'git:commit',
  GIT_STAGE: 'git:stage',
  GIT_UNSTAGE: 'git:unstage',
  GIT_DISCARD: 'git:discard',
  GIT_STASH_LIST: 'git:stash-list',
  GIT_STASH_SAVE: 'git:stash-save',
  GIT_STASH_APPLY: 'git:stash-apply',
  GIT_STASH_DROP: 'git:stash-drop',
  GIT_CLONE: 'git:clone',
  GIT_GRAPH: 'git:graph',

  // Java / Maven
  JAVA_DISCOVER_JDKS: 'java:discover-jdks',
  JAVA_RUN: 'java:run',
  JAVA_DEBUG_START: 'java:debug-start',
  JAVA_DEBUG_STOP: 'java:debug-stop',
  MAVEN_DISCOVER: 'maven:discover',
  MAVEN_RUN: 'maven:run',
  MAVEN_SCAN_MODULES: 'maven:scan-modules',

  // LSP (JDT LS)
  LSP_START: 'lsp:start',
  LSP_STOP: 'lsp:stop',
  LSP_REQUEST: 'lsp:request',
  LSP_NOTIFY: 'lsp:notify',
  LSP_EVENT: 'lsp:event',

  // Search
  SEARCH_PROJECT: 'search:project',
  SEARCH_REPLACE: 'search:replace',

  // Local history
  LOCAL_HISTORY_LIST: 'local-history:list',
  LOCAL_HISTORY_GET: 'local-history:get',
  LOCAL_HISTORY_SAVE: 'local-history:save',
  LOCAL_HISTORY_RESTORE: 'local-history:restore',

  // Settings
  SETTINGS_GET: 'settings:get',
  SETTINGS_SET: 'settings:set',

  // Plugins (VS Code + IDEA)
  PLUGIN_LIST: 'plugin:list',
  PLUGIN_SET_ENABLED: 'plugin:set-enabled',
  PLUGIN_UNINSTALL: 'plugin:uninstall',
  PLUGIN_INSTALL_PATH: 'plugin:install-path',
  PLUGIN_INSTALL_DIALOG: 'plugin:install-dialog',
  PLUGIN_SEARCH_MARKET: 'plugin:search-market',
  PLUGIN_LIST_VERSIONS: 'plugin:list-versions',
  PLUGIN_INSTALL_MARKET: 'plugin:install-market',
  PLUGIN_EXPORT_MARKET: 'plugin:export-market',
  PLUGIN_EXPORT_INSTALLED: 'plugin:export-installed',
  PLUGIN_CONTRIBUTIONS: 'plugin:contributions',
  PLUGIN_OPEN_FOLDER: 'plugin:open-folder',
  PLUGIN_WEBVIEW_URL: 'plugin:webview-url',
  PLUGIN_HOST_ENSURE: 'plugin:host-ensure',
  PLUGIN_HOST_POST: 'plugin:host-post',
  PLUGIN_HOST_EVENT: 'plugin:host-event',

  // Plugin bridge: Extension Host → Renderer actions
  PLUGIN_OPEN_FILE: 'plugin:open-file-in-editor',
  PLUGIN_SHOW_DIFF: 'plugin:show-diff',
  PLUGIN_TERMINAL_SEND: 'plugin:terminal-send',
  /** Renderer → Extension Host: run a command registered by the plugin */
  PLUGIN_EXECUTE_COMMAND: 'plugin:execute-command',

  // App
  APP_CHECK_UPDATE: 'app:check-update'
} as const
