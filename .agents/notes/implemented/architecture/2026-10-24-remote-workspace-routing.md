# Agent 笔记：远程工作区按根目录路由

状态：已实现

## 先说结论

远程文件夹以“本地占位根目录”的身份打开成工作区：根目录是 `Application Support/Lithe/RemoteWorkspaces/` 下的一个空目录，工作台照常拿到一个文件 URL；这个根目录下面的所有文件都在远端。文件树和编辑器经过的两个端口 `WorkspaceOperations` 和 `WorkspaceFileOperations` 外面各包了一层路由：URL 落在远程根目录下就交给远端，其余原样交给本地实现。第一版只让文件树、打开、编辑和保存走远端；Git、搜索、构建、语言服务和终端在远程工作区里看到的仍是本地空目录。

## 问题

工作台的所有功能都以“工作区根目录是一个本地文件 URL”为前提：窗口、会话恢复、项目设置、文件树、编辑器都按 URL 识别。如果为远程项目换一种 URL（例如自定义 scheme），几乎每个功能都要改；而一次性把所有功能都接到远端，改动面太大，也无法分步验证。

## 决策

- **占位根目录**：`MacRemoteWorkspaceRoots` 在 `Application Support/Lithe/RemoteWorkspaces/<连接 id>/<远程路径哈希>/<文件夹名>` 创建一个空目录，用它作为工作区根。目录名是远程文件夹名，所以项目名显示正确。它不在 app bundle 里，不影响签名和 Sparkle 增量包；里面没有用户数据，跨启动保留，让按根目录保存的项目状态得以延续。
- **注册表**：`RemoteWorkspaceRegistry` 记录每个占位根对应的连接、远程路径和 Core 会话 id。打开远程项目时登记，同一个根再次打开时，旧会话会被替换并断开。
- **路由**：组合根（`MacServiceContainer`，负责组装依赖的地方）把本地实现包进 `RemoteRoutingWorkspaceOperations` 和 `RemoteRoutingFileOperations`。路由层对端口里的**每个**方法都显式转发：如果只覆盖一部分，没覆盖的方法会悄悄走协议扩展里的默认实现，本地文件的行为就变了。
- **文档版本**：和本地一样，文档标识是读到的原始字节的 SHA-256。远端用大小和修改时间做冲突检测，所以路由层为每个读到的标识记住远端版本（最多 512 个），保存时把它作为 `expected` 传给 `remote.writeFile`；不认识的标识会先读当前内容比对哈希。文件变了就返回冲突，不覆盖。
- **最近项目**：占位根目录不进“最近项目”，因为它离开连接就只是个空目录；重新打开要走“远程开发”窗口。

### 正确做法

新增一种需要读写工作区文件的能力时，通过这两个端口访问文件，远程工作区就会自动可用。

### 不要这样做

- 不要在功能代码里用 `FileManager` 直接读工作区下的文件：在远程工作区里它只会看到空目录。
- 不要从占位根目录推导“这是远程项目”再写特殊分支，应该询问 `RemoteWorkspaceRegistry`。

## 考虑过的备选方案

### 为远程文件使用自定义 URL scheme

语义最清楚，但工作台里几乎所有地方都假定是文件 URL，第一步就要改全部功能。

### 把远程目录同步到本地再打开

现有功能全都能直接用，但大项目同步慢、两边会不一致，构建和运行也会发生在本地而不是项目所在的机器上，和整体远程开发设计（构建、LSP 都在远端运行）相冲突。

## 后果

- 远程工作区第一版：文件树按需列目录、打开和保存 UTF-8 文件（含 BOM）、保存时检测冲突。
- 暂不支持：新建、删除、重命名、复制（报“不支持”）；外部修改监听；Git、搜索、构建、语言服务和远端终端。这些要逐个接到 `lithe-remote-client` 已有的远端能力上。
- 连接在工作区关闭后仍保留，直到 App 退出。

## 验证

```bash
./scripts/test-macos.sh --filter RemoteConnections
./scripts/verify-service-boundaries.sh
```

## 适用范围

- `macos/Sources/Lithe/Services/Remote/RemoteWorkspaceRouting.swift`
- `macos/Sources/Lithe/Platform/MacOS/Remote/MacRemoteWorkspaceRoots.swift`
- `macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift`
- `macos/Sources/Lithe/Models/AppModel/AppModel+RemoteConnections.swift`
