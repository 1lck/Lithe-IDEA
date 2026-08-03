import * as http from 'http'
import * as fs from 'fs'
import * as path from 'path'
import { detectVscodeWebviewAssets } from './pluginProtocol'
import { getExtensionHost } from './extensionHost'

let server: http.Server | null = null
let port = 0
const roots = new Map<string, string>()

function mimeFor(filePath: string): string {
  const ext = path.extname(filePath).toLowerCase()
  switch (ext) {
    case '.html':
      return 'text/html; charset=utf-8'
    case '.js':
    case '.mjs':
      return 'text/javascript; charset=utf-8'
    case '.css':
      return 'text/css; charset=utf-8'
    case '.json':
      return 'application/json'
    case '.svg':
      return 'image/svg+xml'
    case '.png':
      return 'image/png'
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg'
    case '.gif':
      return 'image/gif'
    case '.webp':
      return 'image/webp'
    case '.woff':
      return 'font/woff'
    case '.woff2':
      return 'font/woff2'
    case '.ttf':
      return 'font/ttf'
    case '.wasm':
      return 'application/wasm'
    case '.mp3':
      return 'audio/mpeg'
    case '.map':
      return 'application/json'
    default:
      return 'application/octet-stream'
  }
}

/** Minimal Kilo/Cline-compatible extension state so the webview hydrates and renders. */
export function buildMockExtensionState(opts: {
  pluginName: string
  cwd?: string
  version?: string
}): Record<string, unknown> {
  return {
    apiConfiguration: {},
    version: opts.version || '0.0.0-lithe',
    clineMessages: [],
    taskHistoryFullLength: 0,
    taskHistoryVersion: 0,
    shouldShowAnnouncement: false,
    allowedCommands: [],
    deniedCommands: [],
    soundEnabled: false,
    soundVolume: 0.5,
    ttsEnabled: false,
    ttsSpeed: 1,
    diffEnabled: true,
    enableCheckpoints: true,
    language: 'zh-CN',
    writeDelayMs: 1000,
    mcpEnabled: true,
    alwaysAllowWrite: true,
    alwaysAllowReadOnly: true,
    currentApiConfigName: 'default',
    listApiConfigMeta: [],
    mode: 'code',
    customModePrompts: {},
    customSupportPrompts: {},
    experiments: {},
    customModes: [],
    cwd: opts.cwd || '',
    telemetrySetting: 'unset',
    renderContext: 'sidebar',
    hasCompletedOnboarding: false,
    hasOpenedModeSelector: false,
    autoApprovalEnabled: true,
    cloudUserInfo: null,
    cloudIsAuthenticated: false,
    cloudOrganizations: [],
    organizationAllowList: { allowAll: true, providers: {} },
    pinnedApiConfigs: {},
    codebaseIndexConfig: {
      codebaseIndexEnabled: false,
      codebaseIndexQdrantUrl: 'http://localhost:6333',
      codebaseIndexEmbedderProvider: 'openai',
      codebaseIndexEmbedderBaseUrl: '',
      codebaseIndexEmbedderModelId: ''
    },
    codebaseIndexModels: { ollama: {}, openai: {} },
    kilocodeDefaultModel: '',
    enterBehavior: 'send',
    sendMessageOnEnter: true,
    showTaskTimeline: true,
    reasoningBlockCollapsed: true
  }
}

/**
 * VS Code injects a large block of `--vscode-*` custom properties into every
 * webview based on the active color theme. Extension UIs (Kilo/Cline/Roo, the
 * webview-ui-toolkit, Tailwind presets) paint every button, input, dropdown,
 * border and badge from these tokens. Without them the markup still lays out
 * and text still inherits a colour — but every component renders transparent,
 * which reads as "only text, no controls". Emit a full dark-theme token set
 * tuned to Lithe's graphite palette.
 */
function vscodeThemeVariables(): string {
  const t = {
    // Base surfaces — mapped onto Lithe's layered graphite
    bg: '#17181b',
    bgEditor: '#131416',
    bgRaised: '#1f2124',
    bgElevated: '#2a2c30',
    bgPopup: '#222428',
    bgInput: '#111214',

    fg: 'rgba(255,255,255,0.86)',
    fgMuted: 'rgba(255,255,255,0.5)',
    fgFaint: 'rgba(255,255,255,0.34)',

    border: 'rgba(255,255,255,0.13)',
    borderSoft: 'rgba(255,255,255,0.075)',

    accent: '#4f94fa',
    accentHover: '#6aa4fb',
    accentPressed: '#3d7fd9',
    link: '#6badff',

    success: '#47b863',
    warning: '#e8a133',
    error: '#eb5454',

    hover: 'rgba(255,255,255,0.055)',
    hoverStrong: 'rgba(255,255,255,0.09)',
    selection: '#2b4a7d',

    uiFont:
      "'IBM Plex Sans','Segoe UI Variable','Segoe UI','PingFang SC','Microsoft YaHei UI',sans-serif",
    codeFont: "'JetBrains Mono','Cascadia Code','Consolas',monospace"
  }

  return `
  --vscode-font-family: ${t.uiFont};
  --vscode-font-size: 13px;
  --vscode-font-weight: normal;
  --vscode-editor-font-family: ${t.codeFont};
  --vscode-editor-font-size: 13px;
  --vscode-editor-font-weight: normal;

  --vscode-foreground: ${t.fg};
  --vscode-disabledForeground: ${t.fgFaint};
  --vscode-descriptionForeground: ${t.fgMuted};
  --vscode-errorForeground: ${t.error};
  --vscode-icon-foreground: ${t.fgMuted};
  --vscode-focusBorder: ${t.accent};
  --vscode-contrastBorder: transparent;
  --vscode-contrastActiveBorder: transparent;
  --vscode-widget-border: ${t.border};
  --vscode-widget-shadow: rgba(0,0,0,0.55);
  --vscode-sash-hoverBorder: ${t.accent};
  --vscode-selection-background: ${t.selection};

  /* Editor */
  --vscode-editor-background: ${t.bgEditor};
  --vscode-editor-foreground: ${t.fg};
  --vscode-editor-selectionBackground: ${t.selection};
  --vscode-editor-inactiveSelectionBackground: rgba(43,74,125,0.5);
  --vscode-editor-lineHighlightBackground: rgba(255,255,255,0.04);
  --vscode-editor-findMatchBackground: #9e6a03;
  --vscode-editor-findMatchHighlightBackground: rgba(234,92,0,0.33);
  --vscode-editorLineNumber-foreground: ${t.fgFaint};
  --vscode-editorLineNumber-activeForeground: ${t.fg};
  --vscode-editorCursor-foreground: ${t.accent};
  --vscode-editorWhitespace-foreground: rgba(255,255,255,0.16);
  --vscode-editorIndentGuide-background1: rgba(255,255,255,0.085);
  --vscode-editorIndentGuide-activeBackground1: rgba(255,255,255,0.24);
  --vscode-editorWarning-foreground: ${t.warning};
  --vscode-editorError-foreground: ${t.error};
  --vscode-editorInfo-foreground: ${t.accent};
  --vscode-editorGutter-addedBackground: ${t.success};
  --vscode-editorGutter-modifiedBackground: ${t.accent};
  --vscode-editorGutter-deletedBackground: ${t.error};

  /* Editor widgets / hovers / suggest */
  --vscode-editorWidget-background: ${t.bgPopup};
  --vscode-editorWidget-foreground: ${t.fg};
  --vscode-editorWidget-border: ${t.border};
  --vscode-editorHoverWidget-background: ${t.bgPopup};
  --vscode-editorHoverWidget-foreground: ${t.fg};
  --vscode-editorHoverWidget-border: ${t.border};
  --vscode-editorSuggestWidget-background: ${t.bgPopup};
  --vscode-editorSuggestWidget-foreground: ${t.fg};
  --vscode-editorSuggestWidget-border: ${t.border};
  --vscode-editorSuggestWidget-selectedBackground: ${t.selection};
  --vscode-editorSuggestWidget-highlightForeground: ${t.accent};

  /* Workbench surfaces */
  --vscode-sideBar-background: ${t.bg};
  --vscode-sideBar-foreground: ${t.fg};
  --vscode-sideBar-border: ${t.borderSoft};
  --vscode-sideBarSectionHeader-background: ${t.bgRaised};
  --vscode-sideBarSectionHeader-foreground: ${t.fg};
  --vscode-sideBarSectionHeader-border: ${t.borderSoft};
  --vscode-sideBarTitle-foreground: ${t.fgMuted};
  --vscode-panel-background: ${t.bgEditor};
  --vscode-panel-border: ${t.border};
  --vscode-panelTitle-activeForeground: ${t.fg};
  --vscode-panelTitle-inactiveForeground: ${t.fgMuted};
  --vscode-panelTitle-activeBorder: ${t.accent};
  --vscode-panelSection-border: ${t.border};
  --vscode-titleBar-activeBackground: ${t.bgRaised};
  --vscode-titleBar-activeForeground: ${t.fg};
  --vscode-titleBar-border: ${t.borderSoft};
  --vscode-statusBar-background: ${t.bgRaised};
  --vscode-statusBar-foreground: ${t.fg};
  --vscode-activityBar-background: ${t.bgRaised};
  --vscode-activityBar-foreground: ${t.fg};
  --vscode-activityBarBadge-background: ${t.accent};
  --vscode-activityBarBadge-foreground: #ffffff;

  /* Buttons */
  --vscode-button-background: ${t.accent};
  --vscode-button-foreground: #ffffff;
  --vscode-button-hoverBackground: ${t.accentHover};
  --vscode-button-border: transparent;
  --vscode-button-separator: rgba(255,255,255,0.4);
  --vscode-button-secondaryBackground: ${t.bgElevated};
  --vscode-button-secondaryForeground: ${t.fg};
  --vscode-button-secondaryHoverBackground: #3c3f45;
  --vscode-checkbox-background: ${t.bgInput};
  --vscode-checkbox-foreground: ${t.fg};
  --vscode-checkbox-border: ${t.border};
  --vscode-checkbox-selectBackground: ${t.accent};
  --vscode-checkbox-selectBorder: ${t.accent};
  --vscode-radio-activeBackground: ${t.accent};
  --vscode-radio-activeForeground: #ffffff;
  --vscode-radio-activeBorder: ${t.accent};
  --vscode-radio-inactiveBorder: ${t.border};

  /* Inputs */
  --vscode-input-background: ${t.bgInput};
  --vscode-input-foreground: ${t.fg};
  --vscode-input-border: ${t.border};
  --vscode-input-placeholderForeground: ${t.fgFaint};
  --vscode-inputOption-activeBackground: rgba(79,148,250,0.28);
  --vscode-inputOption-activeForeground: ${t.fg};
  --vscode-inputOption-activeBorder: ${t.accent};
  --vscode-inputOption-hoverBackground: ${t.hoverStrong};
  --vscode-inputValidation-errorBackground: #5a1d1d;
  --vscode-inputValidation-errorForeground: ${t.fg};
  --vscode-inputValidation-errorBorder: ${t.error};
  --vscode-inputValidation-warningBackground: #5a4413;
  --vscode-inputValidation-warningBorder: ${t.warning};
  --vscode-inputValidation-infoBackground: #1d3a5a;
  --vscode-inputValidation-infoBorder: ${t.accent};

  /* Dropdown / select */
  --vscode-dropdown-background: ${t.bgPopup};
  --vscode-dropdown-listBackground: ${t.bgPopup};
  --vscode-dropdown-foreground: ${t.fg};
  --vscode-dropdown-border: ${t.border};

  /* Badges / keybinding chips */
  --vscode-badge-background: ${t.bgElevated};
  --vscode-badge-foreground: ${t.fg};
  --vscode-keybindingLabel-background: rgba(255,255,255,0.1);
  --vscode-keybindingLabel-foreground: ${t.fg};
  --vscode-keybindingLabel-border: ${t.border};
  --vscode-keybindingLabel-bottomBorder: ${t.border};

  /* Lists & trees */
  --vscode-list-hoverBackground: ${t.hover};
  --vscode-list-hoverForeground: ${t.fg};
  --vscode-list-activeSelectionBackground: ${t.selection};
  --vscode-list-activeSelectionForeground: #ffffff;
  --vscode-list-activeSelectionIconForeground: #ffffff;
  --vscode-list-inactiveSelectionBackground: #34383c;
  --vscode-list-inactiveSelectionForeground: ${t.fg};
  --vscode-list-focusBackground: ${t.selection};
  --vscode-list-focusForeground: #ffffff;
  --vscode-list-focusOutline: ${t.accent};
  --vscode-list-highlightForeground: ${t.accent};
  --vscode-list-dropBackground: rgba(79,148,250,0.18);
  --vscode-list-errorForeground: ${t.error};
  --vscode-list-warningForeground: ${t.warning};
  --vscode-tree-indentGuidesStroke: rgba(255,255,255,0.085);
  --vscode-tree-tableColumnsBorder: ${t.borderSoft};

  /* Quick input / command palette */
  --vscode-quickInput-background: ${t.bgPopup};
  --vscode-quickInput-foreground: ${t.fg};
  --vscode-quickInputList-focusBackground: ${t.selection};
  --vscode-quickInputList-focusForeground: #ffffff;
  --vscode-quickInputTitle-background: ${t.bgElevated};
  --vscode-pickerGroup-foreground: ${t.accent};
  --vscode-pickerGroup-border: ${t.border};

  /* Text content */
  --vscode-textLink-foreground: ${t.link};
  --vscode-textLink-activeForeground: ${t.accentHover};
  --vscode-textPreformat-foreground: #d7ba7d;
  --vscode-textPreformat-background: rgba(255,255,255,0.08);
  --vscode-textCodeBlock-background: ${t.bgInput};
  --vscode-textBlockQuote-background: ${t.bgRaised};
  --vscode-textBlockQuote-border: ${t.accent};
  --vscode-textSeparator-foreground: ${t.border};

  /* Scrollbars */
  --vscode-scrollbar-shadow: rgba(0,0,0,0.4);
  --vscode-scrollbarSlider-background: rgba(255,255,255,0.12);
  --vscode-scrollbarSlider-hoverBackground: rgba(255,255,255,0.2);
  --vscode-scrollbarSlider-activeBackground: rgba(255,255,255,0.28);

  /* Progress / toolbar / banner */
  --vscode-progressBar-background: ${t.accent};
  --vscode-toolbar-hoverBackground: ${t.hoverStrong};
  --vscode-toolbar-activeBackground: ${t.hoverStrong};
  --vscode-banner-background: ${t.bgElevated};
  --vscode-banner-foreground: ${t.fg};
  --vscode-banner-iconForeground: ${t.accent};
  --vscode-notifications-background: ${t.bgPopup};
  --vscode-notifications-foreground: ${t.fg};
  --vscode-notifications-border: ${t.border};
  --vscode-notificationsErrorIcon-foreground: ${t.error};
  --vscode-notificationsWarningIcon-foreground: ${t.warning};
  --vscode-notificationsInfoIcon-foreground: ${t.accent};

  /* Diff / merge */
  --vscode-diffEditor-insertedTextBackground: rgba(71,184,99,0.18);
  --vscode-diffEditor-removedTextBackground: rgba(235,84,84,0.2);
  --vscode-diffEditor-insertedLineBackground: rgba(71,184,99,0.12);
  --vscode-diffEditor-removedLineBackground: rgba(235,84,84,0.12);
  --vscode-diffEditor-border: ${t.border};

  /* Charts (used by usage/token graphs) */
  --vscode-charts-foreground: ${t.fg};
  --vscode-charts-lines: ${t.border};
  --vscode-charts-red: ${t.error};
  --vscode-charts-blue: ${t.accent};
  --vscode-charts-yellow: ${t.warning};
  --vscode-charts-orange: #d18616;
  --vscode-charts-green: ${t.success};
  --vscode-charts-purple: #b180d7;

  /* Terminal (Kilo renders command output blocks) */
  --vscode-terminal-background: ${t.bgEditor};
  --vscode-terminal-foreground: ${t.fg};
  --vscode-terminal-ansiBlack: #1b1d20;
  --vscode-terminal-ansiRed: #eb5454;
  --vscode-terminal-ansiGreen: #47b863;
  --vscode-terminal-ansiYellow: #e8a133;
  --vscode-terminal-ansiBlue: #4f94fa;
  --vscode-terminal-ansiMagenta: #b180d7;
  --vscode-terminal-ansiCyan: #3bb1c8;
  --vscode-terminal-ansiWhite: #d4d4d4;
  --vscode-terminal-ansiBrightBlack: #6b6f76;
  --vscode-terminal-ansiBrightRed: #f07178;
  --vscode-terminal-ansiBrightGreen: #6ecf85;
  --vscode-terminal-ansiBrightYellow: #f0c674;
  --vscode-terminal-ansiBrightBlue: #6aa4fb;
  --vscode-terminal-ansiBrightMagenta: #c79be4;
  --vscode-terminal-ansiBrightCyan: #5fc9dd;
  --vscode-terminal-ansiBrightWhite: #ffffff;

  /* Git decorations */
  --vscode-gitDecoration-addedResourceForeground: ${t.success};
  --vscode-gitDecoration-modifiedResourceForeground: ${t.warning};
  --vscode-gitDecoration-deletedResourceForeground: ${t.error};
  --vscode-gitDecoration-untrackedResourceForeground: ${t.success};
  --vscode-gitDecoration-ignoredResourceForeground: ${t.fgFaint};
  --vscode-gitDecoration-conflictingResourceForeground: ${t.warning};

  /* Symbol icons used by the mention/@ picker */
  --vscode-symbolIcon-fileForeground: ${t.fg};
  --vscode-symbolIcon-folderForeground: ${t.fg};
  --vscode-symbolIcon-classForeground: #ee9d28;
  --vscode-symbolIcon-methodForeground: #b180d7;
  --vscode-symbolIcon-functionForeground: #b180d7;
  --vscode-symbolIcon-variableForeground: ${t.accent};
  --vscode-symbolIcon-constantForeground: ${t.fg};
  --vscode-symbolIcon-interfaceForeground: #75beff;
  --vscode-symbolIcon-propertyForeground: ${t.fg};
  --vscode-symbolIcon-keywordForeground: ${t.fg};
  --vscode-symbolIcon-textForeground: ${t.fg};

  /* Legacy webview-ui-toolkit aliases some builds still read */
  --vscode-settings-headerForeground: ${t.fg};
  --vscode-settings-dropdownBackground: ${t.bgPopup};
  --vscode-settings-dropdownBorder: ${t.border};
  --vscode-settings-textInputBackground: ${t.bgInput};
  --vscode-settings-textInputForeground: ${t.fg};
  --vscode-settings-textInputBorder: ${t.border};
  --vscode-settings-checkboxBackground: ${t.bgInput};
  --vscode-settings-checkboxForeground: ${t.fg};
  --vscode-settings-checkboxBorder: ${t.border};
  --vscode-settings-rowHoverBackground: ${t.hover};
  --vscode-settings-focusedRowBackground: ${t.hover};
  --vscode-settings-modifiedItemIndicator: ${t.accent};
  --vscode-menu-background: ${t.bgPopup};
  --vscode-menu-foreground: ${t.fg};
  --vscode-menu-border: ${t.border};
  --vscode-menu-selectionBackground: ${t.selection};
  --vscode-menu-selectionForeground: #ffffff;
  --vscode-menu-separatorBackground: ${t.border};
  --vscode-editorGroup-border: ${t.border};
  --vscode-editorGroupHeader-tabsBackground: ${t.bgRaised};
  --vscode-tab-activeBackground: ${t.bgRaised};
  --vscode-tab-activeForeground: ${t.fg};
  --vscode-tab-inactiveBackground: ${t.bg};
  --vscode-tab-inactiveForeground: ${t.fgMuted};
  --vscode-tab-border: ${t.borderSoft};
  --vscode-tab-activeBorderTop: ${t.accent};
  --vscode-peekViewResult-background: ${t.bgRaised};
  --vscode-peekViewEditor-background: ${t.bgEditor};
  --vscode-peekViewTitle-background: ${t.bgElevated};
  --vscode-debugToolBar-background: ${t.bgPopup};
  --vscode-debugIcon-breakpointForeground: ${t.error};`
}

function buildSidebarHtml(
  pluginId: string,
  root: string,
  title: string,
  cwd: string,
  useHost = false
): string {
  const hasCodicon = fs.existsSync(path.join(root, 'assets', 'codicons', 'codicon.css'))
  const base = `/p/${encodeURIComponent(pluginId)}/webview-ui/build/`
  const images = `/p/${encodeURIComponent(pluginId)}/assets/images`
  const icons = `/p/${encodeURIComponent(pluginId)}/assets/icons`
  const audio = `/p/${encodeURIComponent(pluginId)}/webview-ui/audio`
  const material = `/p/${encodeURIComponent(pluginId)}/assets/vscode-material-icons/icons`
  const codicon = `/p/${encodeURIComponent(pluginId)}/assets/codicons/codicon.css`
  const mockState = buildMockExtensionState({ pluginName: title, cwd })

  return `<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width,initial-scale=1,shrink-to-fit=no" />
    <base href="${base}" />
    <link rel="stylesheet" href="./assets/index.css" />
    ${hasCodicon ? `<link rel="stylesheet" href="${codicon}" />` : ''}
    <script>
      window.IMAGES_BASE_URI = ${JSON.stringify(images)};
      window.ICONS_BASE_URI = ${JSON.stringify(icons)};
      window.AUDIO_BASE_URI = ${JSON.stringify(audio)};
      window.MATERIAL_ICONS_BASE_URI = ${JSON.stringify(material)};
      window.KILOCODE_BACKEND_BASE_URL = "";
      (function () {
        var state = undefined;
        var pluginId = ${JSON.stringify(pluginId)};
        var bootState = ${JSON.stringify(mockState)};
        function hydrate(from) {
          var n = 0;
          function send() {
            try {
              window.postMessage({ type: "state", state: bootState, __litheBoot: from + "-" + n }, "*");
            } catch (e) {}
            n += 1;
            if (n < 8) setTimeout(send, 80 * n);
          }
          send();
        }
        window.acquireVsCodeApi = function () {
          return {
            postMessage: function (data) {
              try {
                window.parent.postMessage({ __lithePlugin: true, pluginId: pluginId, direction: "to-host", data: data }, "*");
              } catch (e) {}
              ${
                useHost
                  ? '// Extension Host owns state replies'
                  : `if (data && data.type === "webviewDidLaunch") {
                setTimeout(function () { hydrate("launch"); }, 0);
              }`
              }
            },
            getState: function () { return state; },
            setState: function (next) { state = next; return state; }
          };
        };
        ${
          useHost
            ? '// Host mode: wait for real postStateToWebview'
            : `setTimeout(function () { hydrate("timeout"); }, 600);`
        }
      })();
    </script>
    <title>${String(title).replace(/[<>&]/g, '')}</title>
    <style>
      /* VS Code theme contract — extension UIs paint every control from these. */
      :root {${vscodeThemeVariables()}
      }

      html, body, #root {
        height: 100%;
        margin: 0;
        background: var(--vscode-sideBar-background);
        color: var(--vscode-foreground);
      }
      body {
        font-family: var(--vscode-font-family);
        font-size: var(--vscode-font-size);
        font-weight: var(--vscode-font-weight);
        overflow: hidden;
      }
      *, *::before, *::after { box-sizing: border-box; }

      /* Match VS Code's webview scrollbar treatment */
      ::-webkit-scrollbar { width: 10px; height: 10px; }
      ::-webkit-scrollbar-track { background: transparent; }
      ::-webkit-scrollbar-thumb {
        background: var(--vscode-scrollbarSlider-background);
        border-radius: 5px;
      }
      ::-webkit-scrollbar-thumb:hover { background: var(--vscode-scrollbarSlider-hoverBackground); }
      ::-webkit-scrollbar-thumb:active { background: var(--vscode-scrollbarSlider-activeBackground); }
      ::-webkit-scrollbar-corner { background: transparent; }
    </style>
  </head>
  <body class="vscode-dark vscode-body" data-vscode-theme-kind="vscode-dark" data-vscode-theme-name="Lithe Graphite Dark" data-vscode-theme-id="Lithe Graphite Dark">
    <div id="root"></div>
    <script type="module" src="./assets/index.js"></script>
  </body>
</html>`
}

/**
 * Inject Lithe's postMessage bridge + a shim `acquireVsCodeApi` on top of the
 * HTML that resolveWebviewView produced. The extension already wrote all its
 * CSP / nonce / script tags — we only prepend a small `<script>` (with the
 * same nonce so CSP allows it) that:
 *   - proxies webview.postMessage → parent frame → main → extension host
 *   - forwards inbound host messages onto window.postMessage so the extension
 *     UI's message listener sees them
 */
function wrapHostHtml(pluginId: string, html: string, _cwd: string): string {
  // Try to extract the CSP nonce so our injected <script> passes CSP.
  let nonce = ''
  const nonceMatch = html.match(/'nonce-([A-Za-z0-9+/=]+)'/)
  if (nonceMatch) nonce = nonceMatch[1]

  const nonceAttr = nonce ? ` nonce="${nonce}"` : ''
  const themeVars = vscodeThemeVariables()

  const bridge = `<script${nonceAttr}>
(function () {
  var pluginId = ${JSON.stringify(pluginId)};
  var savedState = undefined;

  window.acquireVsCodeApi = function () {
    return {
      postMessage: function (data) {
        try {
          window.parent.postMessage(
            { __lithePlugin: true, pluginId: pluginId, direction: 'to-host', data: data },
            '*'
          );
        } catch (e) {}
      },
      getState: function () { return savedState; },
      setState: function (next) { savedState = next; return next; }
    };
  };

  // Inbound messages arrive already on window (parent → iframe postMessage).
  // Extension UI listens on window 'message'. Nothing else to do here.
})();
</script>
<style${nonceAttr}>
:root {${themeVars}
}
html, body {
  background: var(--vscode-sideBar-background);
  color: var(--vscode-foreground);
  font-family: var(--vscode-font-family);
  font-size: var(--vscode-font-size);
}
::-webkit-scrollbar { width: 10px; height: 10px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: var(--vscode-scrollbarSlider-background); border-radius: 5px; }
::-webkit-scrollbar-thumb:hover { background: var(--vscode-scrollbarSlider-hoverBackground); }
::-webkit-scrollbar-thumb:active { background: var(--vscode-scrollbarSlider-activeBackground); }
</style>`

  // Inject just before </head>; fall back to prepending inside <html> if not
  // found (unlikely but safe).
  if (/<\/head>/i.test(html)) {
    return html.replace(/<\/head>/i, bridge + '</head>')
  }
  return bridge + html
}

function safeJoin(root: string, rel: string): string | null {
  const abs = path.resolve(root, rel)
  const rootResolved = path.resolve(root)
  const a = abs.toLowerCase()
  const r = rootResolved.toLowerCase()
  if (a !== r && !a.startsWith(r + path.sep.toLowerCase()) && !a.startsWith(r + '\\') && !a.startsWith(r + '/')) {
    return null
  }
  return abs
}

export function updatePluginStaticRoots(map: Map<string, string>): void {
  roots.clear()
  for (const [id, p] of map) roots.set(id, p)
}

export function getPluginStaticPort(): number {
  return port
}

export function pluginWebviewHttpUrl(pluginId: string): string | null {
  if (!port) return null
  if (!roots.has(pluginId)) return null
  const root = roots.get(pluginId)!
  if (!detectVscodeWebviewAssets(root)) return null
  return `http://127.0.0.1:${port}/p/${encodeURIComponent(pluginId)}/webview-ui/build/__lithe_sidebar.html`
}

export async function ensurePluginStaticServer(): Promise<number> {
  if (server && port) return port

  server = http.createServer((req, res) => {
    try {
      const url = new URL(req.url || '/', `http://127.0.0.1`)
      const parts = url.pathname.split('/').filter(Boolean)
      // /p/:pluginId/...
      if (parts[0] !== 'p' || parts.length < 2) {
        res.writeHead(404)
        res.end('Not found')
        return
      }
      const pluginId = decodeURIComponent(parts[1])
      const root = roots.get(pluginId)
      if (!root) {
        res.writeHead(404)
        res.end('Plugin not found')
        return
      }
      const rel = parts.slice(2).map(decodeURIComponent).join('/')

      if (rel === 'webview-ui/build/__lithe_sidebar.html' || rel === '__lithe_sidebar.html') {
        const cwd = url.searchParams.get('cwd') || ''
        const useHost = url.searchParams.get('host') === '1'

        // If the Extension Host is running and produced real HTML from
        // resolveWebviewView, serve that (it has the correct nonce, CSP,
        // script/style references etc. that the extension itself set up).
        if (useHost) {
          const hostHandle = getExtensionHost(pluginId)
          if (hostHandle?.status === 'running' && hostHandle.resolvedHtml) {
            const hostHtml = wrapHostHtml(pluginId, hostHandle.resolvedHtml, cwd)
            res.writeHead(200, {
              'content-type': 'text/html; charset=utf-8',
              'cache-control': 'no-cache',
              'access-control-allow-origin': '*'
            })
            res.end(hostHtml)
            return
          }
        }

        const html = buildSidebarHtml(pluginId, root, pluginId, cwd, useHost)
        res.writeHead(200, {
          'content-type': 'text/html; charset=utf-8',
          'cache-control': 'no-cache',
          'access-control-allow-origin': '*'
        })
        res.end(html)
        return
      }

      const abs = safeJoin(root, rel)
      if (!abs || !fs.existsSync(abs) || fs.statSync(abs).isDirectory()) {
        res.writeHead(404)
        res.end('Not found')
        return
      }
      res.writeHead(200, {
        'content-type': mimeFor(abs),
        'cache-control': 'public, max-age=60',
        'access-control-allow-origin': '*'
      })
      fs.createReadStream(abs).pipe(res)
    } catch (err: any) {
      res.writeHead(500)
      res.end(err?.message || 'error')
    }
  })

  await new Promise<void>((resolve, reject) => {
    server!.once('error', reject)
    server!.listen(0, '127.0.0.1', () => {
      const addr = server!.address()
      port = typeof addr === 'object' && addr ? addr.port : 0
      resolve()
    })
  })

  return port
}
