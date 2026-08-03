import { protocol, net } from 'electron'
import * as fs from 'fs'
import * as path from 'path'
import { pathToFileURL } from 'url'

const SCHEME = 'lithe-plugin'

/** Must run before app.whenReady(). */
export function registerPluginProtocolScheme(): void {
  protocol.registerSchemesAsPrivileged([
    {
      scheme: SCHEME,
      privileges: {
        standard: true,
        secure: true,
        supportFetchAPI: true,
        corsEnabled: true,
        stream: true,
        bypassCSP: true
      }
    }
  ])
}

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
    case '.map':
      return 'application/json'
    case '.mp3':
      return 'audio/mpeg'
    case '.wav':
      return 'audio/wav'
    default:
      return 'application/octet-stream'
  }
}

function pluginAssetUrl(pluginId: string, relPath: string): string {
  const clean = relPath.replace(/\\/g, '/').replace(/^\/+/, '')
  return `${SCHEME}://${encodeURIComponent(pluginId)}/${clean.split('/').map(encodeURIComponent).join('/')}`
}

export function pluginSidebarUrl(pluginId: string): string {
  // Must live under webview-ui/build so Vite chunk imports (assets/…) resolve.
  return pluginAssetUrl(pluginId, 'webview-ui/build/__lithe_sidebar.html')
}

export function detectVscodeWebviewAssets(root: string): boolean {
  return (
    fs.existsSync(path.join(root, 'webview-ui', 'build', 'assets', 'index.js')) &&
    fs.existsSync(path.join(root, 'webview-ui', 'build', 'assets', 'index.css'))
  )
}

function buildSidebarHtml(pluginId: string, root: string, title: string): string {
  // Relative to webview-ui/build/__lithe_sidebar.html
  const css = './assets/index.css'
  const js = './assets/index.js'
  const codicon = pluginAssetUrl(pluginId, 'assets/codicons/codicon.css')
  const images = pluginAssetUrl(pluginId, 'assets/images')
  const icons = pluginAssetUrl(pluginId, 'assets/icons')
  const audio = pluginAssetUrl(pluginId, 'webview-ui/audio')
  const material = pluginAssetUrl(pluginId, 'assets/vscode-material-icons/icons')
  const hasCodicon = fs.existsSync(path.join(root, 'assets', 'codicons', 'codicon.css'))

  // Relaxed CSP so the static UI can boot without a full Extension Host.
  const csp = [
    "default-src 'none'",
    `font-src ${SCHEME}: data:`,
    `style-src ${SCHEME}: 'unsafe-inline'`,
    `img-src ${SCHEME}: data: https: http:`,
    `media-src ${SCHEME}: data:`,
    `script-src ${SCHEME}: 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval'`,
    `connect-src ${SCHEME}: https: http: ws: wss:`
  ].join('; ')

  return `<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width,initial-scale=1,shrink-to-fit=no" />
    <meta http-equiv="Content-Security-Policy" content="${csp}" />
    <base href="${pluginAssetUrl(pluginId, 'webview-ui/build/')}" />
    <link rel="stylesheet" href="${css}" />
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
        window.acquireVsCodeApi = function () {
          return {
            postMessage: function (data) {
              try {
                window.parent.postMessage({ __lithePlugin: true, pluginId: pluginId, direction: 'to-host', data: data }, '*');
              } catch (e) {}
            },
            getState: function () { return state; },
            setState: function (next) { state = next; return state; }
          };
        };
      })();
    </script>
    <title>${title.replace(/[<>&]/g, '')}</title>
    <style>
      html, body, #root { height: 100%; margin: 0; background: #1e1f22; color: #dbdbdb; }
      .lithe-host-banner {
        position: sticky; top: 0; z-index: 9999;
        padding: 6px 10px; font: 11px/1.4 system-ui, sans-serif;
        background: #3d2e12; color: #f0d9a8; border-bottom: 1px solid #6a5224;
      }
    </style>
  </head>
  <body>
    <div class="lithe-host-banner">
      Lithe is showing this plugin’s webview UI. The VS Code Extension Host is not running yet — chat / agent actions will not work until a host is added.
    </div>
    <div id="root"></div>
    <script type="module" src="${js}"></script>
  </body>
</html>`
}

type ResolveRoot = (pluginId: string) => string | null

/** Call inside app.whenReady after plugins dirs exist. */
export function registerPluginProtocolHandler(resolveRoot: ResolveRoot): void {
  protocol.handle(SCHEME, async (request) => {
    try {
      const url = new URL(request.url)
      const pluginId = decodeURIComponent(url.hostname || '')
      const rel = decodeURIComponent(url.pathname.replace(/^\/+/, ''))
      if (!pluginId) {
        return new Response('Missing plugin id', { status: 400 })
      }
      const root = resolveRoot(pluginId)
      if (!root) {
        return new Response('Plugin not found', { status: 404 })
      }

      if (
        rel === 'webview-ui/build/__lithe_sidebar.html' ||
        rel === '__lithe_sidebar.html' ||
        rel === ''
      ) {
        const title = path.basename(root)
        const html = buildSidebarHtml(pluginId, root, title)
        return new Response(html, {
          headers: {
            'content-type': 'text/html; charset=utf-8',
            'cache-control': 'no-cache'
          }
        })
      }

      const abs = path.resolve(root, rel)
      const rootResolved = path.resolve(root)
      const absLower = abs.toLowerCase()
      const rootLower = rootResolved.toLowerCase()
      if (absLower !== rootLower && !absLower.startsWith(rootLower + path.sep.toLowerCase()) && !absLower.startsWith(rootLower + '\\') && !absLower.startsWith(rootLower + '/')) {
        return new Response('Forbidden', { status: 403 })
      }
      if (!fs.existsSync(abs) || fs.statSync(abs).isDirectory()) {
        return new Response('Not found', { status: 404 })
      }

      // Prefer net.fetch(file://) for streaming large JS bundles
      const fileUrl = pathToFileURL(abs).href
      const res = await net.fetch(fileUrl)
      const headers = new Headers(res.headers)
      headers.set('content-type', mimeFor(abs))
      headers.set('access-control-allow-origin', '*')
      return new Response(res.body, { status: res.status, headers })
    } catch (err: any) {
      return new Response(err?.message || 'Protocol error', { status: 500 })
    }
  })
}

export function pluginProtocolScheme(): string {
  return SCHEME
}
