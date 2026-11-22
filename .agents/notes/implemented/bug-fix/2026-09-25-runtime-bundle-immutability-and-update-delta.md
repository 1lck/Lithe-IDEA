# Agent 笔记：运行时保持发布程序包不变以支持增量更新

状态：已实现

## 先说结论

Sparkle 增量更新（differential update，只下载两个版本之间差异的更新包）依赖上一版 app bundle 的精确字节基线。所以 Lithe 运行时不能往已安装的程序包（macOS app bundle 或 Windows 安装目录）里写任何东西。缓存、索引、日志、插件状态和语言服务状态都要放进平台缓存等可写目录；需要可写配置的外部进程，由宿主把包内只读输入复制到缓存后再启动。

## 问题

外部进程（例如 Equinox/OSGi 框架）会往它被指定的配置目录里写框架状态。如果这个目录指向安装包内的资源，第一次启动后包内就多出运行时文件：

- macOS：发布包被运行时修改后，Sparkle 的 delta 以干净的发布包为源，更新时出现 `Source doesn't have expected hash`，只能回退下载完整 ZIP。完整包下载成功，会掩盖 bundle 已经被修改这件事。
- Windows：安装目录里的状态文件会随用户安装或系统安装的权限而变得不可写或残留旧状态。

普通资源读取没有问题，问题在于把资源路径当成了可写目录。只检查应用能不能启动，证明不了这一点；要比较一次完整工作流前后安装目录的文件清单。

## 决策

1. **已发布的 app bundle 和 Windows 安装目录都是只读发行物。** 构建脚本可以生成资源，运行时只能读取。规则写在 `develop-lithe` Skill 的“已安装程序包运行时只读”一节。
2. **需要可写配置的外部进程：复制输入，不共享目录。** 平台交出只读的安装包路径和平台缓存目录；宿主或 Core 在启动进程前，把包内唯一的输入文件复制到缓存，按输入哈希选定目录，并把该目录作为可写配置传给进程。输入变化时自动换到新目录；复制出的副本缺失或损坏时原子地重写。缓存路径解析后若落入安装目录，直接拒绝启动。Java 语言服务的具体实现已迁到 [lithe-plugin-java](https://github.com/Lithe-IDEA/lithe-plugin-java)，宿主不再持有它。
3. **打包的 IDE 辅助程序作为构建输入嵌入客户端二进制，运行时安装到应用数据目录。** Viva 的 IDE API 需要 `lithe-mcp` 可执行文件。它由 `scripts/desktop/build-desktop-core.sh` 从固定 Core 检出按 `features=mcp` 构建到暂存目录，`scripts/desktop/package-desktop.sh` 再把它作为 `desktop/internal/idehelp/lithe-mcp.bin` 以构建标签嵌入 Go 二进制，打包结束或失败时删除该生成文件。客户端第一次使用连接时把嵌入字节原子写到应用数据目录的 `ide-host/bin/`，已有文件哈希一致时直接复用。安装包本身不新增可执行文件，运行时也不需要定位自己的可执行文件；开发运行由 `desktop-go.sh` 用 `LITHE_IDE_HELPER` 指向暂存目录里的辅助程序。
4. **会写本地文件的工作流，都要在“装好的程序包”里跑一遍，并比较前后文件清单。** 静态检查只能看出代码有没有从可执行文件推导路径，看不出写入最终落在哪里。`desktop/internal/installedpackagetest` 的做法是：
   - 把测试二进制复制进一个仿造的安装包：macOS 是 `Lithe.app/Contents/MacOS/`，Windows 和 Linux 是 `Lithe/`。
   - 把 HOME、USERPROFILE、LOCALAPPDATA、APPDATA 指向临时目录，再从副本重新执行同一个测试。
   - 副本先确认 `installedpackage.Root()` 解析到仿造的包根，再跑真实的生产路径。
   - 父进程比较包内每一项的类型、权限位、大小和 SHA-256。

   Go 测试在 macOS、Windows、Linux CI 上都会运行，所以每个平台的生产解析路径都能覆盖到。目前列入的工作流有五个：
   - 远程连接时安装服务端构建（`remoteserver.Resolve`）；Core 随后从用户缓存读取并上传，Core 的远程客户端不写本地文件。
   - 打开远程文件夹时创建占位锚点（`remoteplaceholder.Ensure`）。
   - IDE API 辅助程序安装（`idehelp.Install`）。
   - Windows ConPTY 安装（`conpty` 的安装）。
   - 插件包的解压、安装和卸载（`pluginpkg`）。

   日志、偏好、登录环境缓存这类普通状态写入，直接从 `os.UserConfigDir`、`os.UserCacheDir` 或 `LOCALAPPDATA` 取目录，不安装、不解压任何东西，所以不逐个列入，由静态检查兜底。

   `verify-runtime-bundle-immutability.sh` 列出这些测试，并要求每个测试体内保留 `installedpackagetest.Run(t)`。测试被删、改名，或者调用被移到别的函数，脚本都会失败。新增会写本地文件的运行时工作流时，同一次改动里补这样一个测试，并把它加进脚本的清单。

正确做法：平台交出只读的安装包路径和平台缓存目录，宿主生成可写副本后再交给进程使用。
不要这样做：在不同平台或不同代码路径各自复制一份配置目录；把缓存目录放进安装包里的某个子目录；在更新前清理 app bundle。

## 考虑过的备选方案

- **让外部进程的级联配置读取安装目录（Equinox cascaded）**：否决。级联会让新版本读到旧版本留在安装目录里的运行时状态。只复制输入文件，完全不读安装目录里的运行时文件。
- **在每次 Sparkle 更新前清理 app bundle**：否决。清理发生得太晚，修不了已经生成的 delta 源哈希；清理失败也会回退，而且让更新器去修改发行物。
- **把外部进程状态放进用户项目或 `.lithe/`**：否决。运行状态写进工作区会制造项目噪声并污染 Git。
- **只把配置目录设为只读**：否决。外部进程会把启动失败变成难以诊断的权限错误。

## 后果

- 增量更新以干净的 app bundle 为基线。外部进程首次启动只增加用户缓存，不改变已安装的程序包。
- 已经被旧版本写过的安装目录：macOS 在这次更新时回退完整 ZIP 一次，替换后的 bundle 是干净的；Windows 安装目录里的旧状态文件可能残留，但新版本不再读写它们。
- 派生的副本目录属于缓存，长期未使用时由保留策略清理。

## 验证

- `desktop/internal/idehelp` 测试：辅助程序首次安装、同字节复用、旧版本原子替换、未嵌入时报告缺失。运行 `cd desktop && ../scripts/desktop/desktop-go.sh test -race ./internal/idehelp/`。
- 打包后检查 `.app` 内没有 `lithe-mcp` 文件，且 `desktop/internal/idehelp/lithe-mcp.bin` 已清理。
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：
  - 静态检查运行时只通过 `installedpackage` 定位程序包，且这个包不写文件。
  - 要求决策 4 列出的工作流测试都还在，并且都经过 `installedpackagetest.Run(t)`。
  - `scripts/desktop/verify/test-runtime-bundle-immutability.mjs` 覆盖这些规则。
- 安装包不变的工作流测试：`cd desktop && ../scripts/desktop/desktop-go.sh test ./internal/installedpackagetest ./internal/remoteserver ./internal/remoteplaceholder ./internal/idehelp ./internal/localshell/conpty ./internal/pluginpkg -run 'LeavesTheInstalledPackageUnchanged|TestRunFailsWhenTheWorkflowWritesIntoThePackage'`。其中 `TestRunFailsWhenTheWorkflowWritesIntoThePackage` 证明：工作流往包里写一个文件，就会被报告为新增项并导致测试失败。
- `./scripts/agent-notes/verify-agent-notes.sh`

## 适用范围

- `desktop/internal/idehelp/`
- `desktop/internal/installedpackage/`
- `desktop/internal/installedpackagetest/`
- `desktop/internal/remoteserver/`、`desktop/internal/remoteplaceholder/`、`desktop/internal/localshell/conpty/`、`desktop/internal/pluginpkg/` 的安装包不变测试
- `scripts/desktop/build-desktop-core.sh`
- `scripts/desktop/package-desktop.sh`
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`
- `.agents/skills/develop-lithe/SKILL.md`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/contracts/rust-core-api.md`
