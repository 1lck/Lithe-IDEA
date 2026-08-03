import { app, shell, BrowserWindow } from 'electron'
import { join } from 'path'
import { electronApp, optimizer, is } from '@electron-toolkit/utils'
import { registerFileHandlers } from './services/fileService'
import { registerProjectHandlers } from './services/projectService'
import { registerTerminalHandlers } from './services/terminalService'
import { registerGitHandlers } from './services/gitService'
import { registerJavaHandlers } from './services/javaService'
import { registerSearchHandlers } from './services/searchService'
import { registerLocalHistoryHandlers, registerSettingsHandlers } from './services/settingsService'
import { registerLocalServerHandlers, stopLocalServerOnQuit } from './services/localServerService'
import {
  getCachedPluginPath,
  mapInstalledPluginPaths,
  registerPluginHandlers
} from './services/pluginService'
import {
  registerPluginProtocolHandler,
  registerPluginProtocolScheme
} from './services/pluginProtocol'
import { ensurePluginStaticServer } from './services/pluginStaticServer'

// Privileged custom scheme must be registered before app ready.
registerPluginProtocolScheme()

function appIconPath(): string {
  if (app.isPackaged) {
    return join(process.resourcesPath, 'icon.png')
  }
  return join(__dirname, '../../resources/icon.png')
}

function createWindow(): void {
  const mainWindow = new BrowserWindow({
    width: 1440,
    height: 900,
    minWidth: 980,
    minHeight: 640,
    show: false,
    frame: false,
    titleBarStyle: 'hidden',
    titleBarOverlay: {
      color: '#25282b',
      symbolColor: '#dbdbdb',
      height: 40
    },
    backgroundColor: '#25282b',
    icon: appIconPath(),
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      sandbox: false,
      webviewTag: true
    }
  })

  mainWindow.on('ready-to-show', () => {
    mainWindow.show()
  })

  mainWindow.webContents.setWindowOpenHandler((details) => {
    shell.openExternal(details.url)
    return { action: 'deny' }
  })

  if (is.dev && process.env['ELECTRON_RENDERER_URL']) {
    mainWindow.loadURL(process.env['ELECTRON_RENDERER_URL'])
  } else {
    mainWindow.loadFile(join(__dirname, '../renderer/index.html'))
  }
}

app.whenReady().then(() => {
  electronApp.setAppUserModelId('com.lithe.ide.windows')

  registerPluginProtocolHandler((pluginId) => getCachedPluginPath(pluginId))

  app.on('browser-window-created', (_, window) => {
    optimizer.watchWindowShortcuts(window)
  })

  registerFileHandlers()
  registerProjectHandlers()
  registerTerminalHandlers()
  registerGitHandlers()
  registerJavaHandlers()
  registerSearchHandlers()
  registerLocalHistoryHandlers()
  registerSettingsHandlers()
  registerLocalServerHandlers()
  registerPluginHandlers()

  // Warm protocol path cache + static asset server for plugin webviews
  void mapInstalledPluginPaths().then(() => ensurePluginStaticServer())

  createWindow()

  app.on('activate', function () {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  stopLocalServerOnQuit()
  app.quit()
})
