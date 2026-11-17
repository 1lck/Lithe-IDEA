# Agent 笔记：内置界面与编辑器字体随发行包分发

状态：已实现

## 先说结论

界面文字默认使用随发行包提供的 Inter，编辑器与显式等宽内容使用 JetBrains Mono，终端使用 Nerd Font Mono 的选择顺序。字体文件由构建时编译进可执行文件，运行时不下载、不读安装目录，也不要求用户自行安装。字体的注册与缓存只写入平台的用户缓存目录，不改变签名和 Sparkle 增量更新的发行基线。

## 问题

依赖用户安装字体会让界面随机器变化，也无法保证网页式编辑器可用。Inter 与 JetBrains Mono 各有多个字重，如果只打包 Regular 与 SemiBold，Medium 与 Bold 请求会被合成或匹配到错误的字重，界面层次会变化。

## 决策

- **字体源文件集中在 `desktop/internal/bundledfont/fonts`。** 目录包含 Inter 4.1 的静态字型（含斜体）、JetBrains Mono 2.304 的静态字型、Nerd Font Mono 的终端字型，以及各自的许可文本；`NOTICE.txt` 列出每个字型的 SHA-256。`TestTheFontFolderMatchesItsManifest` 核对文件、哈希和字型数量。
- **字重按字型名称精确匹配。** 界面请求的 Regular、Medium、SemiBold、Bold 必须对应真实字型，不能靠合成字重。
- **编译进可执行文件，只在打包时启用。** 发行构建使用 `lithe_bundled_fonts` 构建标签把目录编译进去，app bundle 中没有字体文件；开发、测试和其它平台的构建默认不含字体，回退到系统字体。
- **注册只在当前进程内生效。** 字型按内容摘要暂存到用户缓存目录后再注册，不安装到系统，也不写入安装目录。
- **终端字体有独立顺序。** 终端先选已安装的 MesloLGS 等 Nerd Font Mono，再选打包的 JetBrainsMono Nerd Font Mono，然后是 JetBrains Mono，最后是系统等宽字体（`desktop/internal/workbench/fonts.go` 的 `firstAvailableFamily`）。终端不跟随编辑器字体族设置。
- **字体不增加运行时写入。** 字体文件不在运行时下载、解压或修改，不跨工作树复制。

## 考虑过的备选方案

- **只给根视图设置默认字体。** 未采用。显式字体和原生文本控件会覆盖根视图设置。
- **依赖用户安装字体。** 未采用。版本随机器变化，且无法保证编辑器和终端可用。
- **在 `viva package` 之后往 `.app` 复制字体。** 未采用。会破坏打包器已经完成的签名。
- **所有构建都嵌入字体。** 未采用。每个测试二进制会多链接约 25 MB，并且测试会往用户缓存写字体。

## 后果

- 发行版的可执行文件约增加 25 MB；启动时注册全部字型有可测量的耗时，缓存摘要算法的选择会影响这一耗时。
- 中文等字体未覆盖的字形继续由系统回退渲染，这是预期行为。
- 字体文件属于构建输入，修改字体需要同时更新 `NOTICE.txt` 与 `docs/ci-builds.md` 的说明。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/bundledfont/ ./internal/workbench/ -run 'Font|Register' -count=1`
- `scripts/desktop/desktop-go.sh test -tags lithe_bundled_fonts ./internal/bundledfont/ -count=1`
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：检查运行时资源路径不写入发行目录。
- 打包后的安装包需核对字型清单与许可信息，并在真实窗口中确认界面、编辑器与终端的字重。

## 适用范围

- `desktop/internal/bundledfont/bundledfont.go`
- `desktop/internal/bundledfont/embedded.go`
- `desktop/internal/workbench/fonts.go`
- `desktop/internal/workbench/fonts_bundled.go`
- `scripts/desktop/package-desktop.sh`
