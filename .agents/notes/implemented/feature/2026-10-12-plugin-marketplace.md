# Agent 笔记：插件市场与插件仓库源

状态：已实现

## 先说结论

插件市场列出“插件仓库源”（一个 JSON 索引）中的插件，默认源是官方索引，另外可以添加第三方源（HTTPS 索引地址，或 GitHub 仓库地址自动指向根目录的索引文件）。索引格式、校验与信任判断只在 Rust Core 中计算，桌面端只负责下载、展示与确认。官方插件各自按自己的标签发布，不跟随 Lithe 版本发版。

## 问题

插件下载入口若写死在宿主里，每个新插件都要改宿主代码；插件跟着 Lithe 版本发布，插件没改也要重新发版，插件改了又要等宿主发版。第三方开发者也无法分发插件，用户无法判断插件包的作者和它会运行什么程序。

## 决策

- **索引按“插件 → 版本 → 各平台下载包”组织。** 每个下载包写明平台、下载地址与 SHA-256。Core 负责格式检查、命名空间检查、平台匹配和插件 API 版本判断；不合法的条目被单独忽略，不会让整个源失效。
- **下载地址限定为插件自己仓库的 GitHub Release `.zip` 资产。** 这样“来源仓库”一栏不能伪造。
- **语言。** 索引的 `description` 使用英文作为默认文本，`localizedDescriptions` 按语言标签提供翻译；界面按 Lithe 设置的语言选择，找不到时显示默认文本。
- **官方源只接受签名包，第三方源只接受不签名的包。** 第三方源不能声明 `dev.lithe.*` 命名空间；官方已知插件的签名要求由宿主固定，包不能自行降级。
- **安装前必须确认。** 市场包的流程是：下载，与索引的 SHA-256 比对（不匹配则不解压），检查声明与包内容，Core 审查，用户确认，安装。确认时展示全部权限与程序，不能只展示差异。
- **市场图标使用索引声明的 SVG。** 列表与详情按原色显示，复用桌面端已有的 Viva SVG 编译器，不为市场增加第二套渲染器。无资源、加载中、下载或编译失败时使用原有缩写头像，失败在后台边界记录一次。只为可见条目读取，同一地址共用结果；缓存仅属于当前市场页，刷新索引、离开页面或关闭窗口时释放，不写发行包或磁盘。PNG 和编译器不支持的 SVG 当前仍降级。
- **资源上限。** 下载时边收边计数，超过 512 MiB 立即中止；索引超过 5 MiB 也会被拒绝。ZIP 解压前检查中央目录声明的展开大小与文件数，解压过程中也要实测，因为压缩包可以谎报大小。
- **下载不限总时长，断开后续传。** 下载连续一分钟没有收到数据时以超时结束（`ErrArchiveStalled`，界面显示“操作超时”），整体不限时长，审查窗口可以随时取消；只有解包与检查（`Installer.Prepare`）保留 5 分钟上限。下载断开或被取消时，设置窗口的 `ArchiveSession` 保留已收到的字节，同一归档（下载地址和 SHA-256 都相同）的下次下载用 `Range` 只请求剩下的部分。服务器不支持或回答的范围不对时从头下载；续上的归档与索引摘要不符时拒绝并删掉保留的字节，下一次从头下载。会话在磁盘上最多留一份文件：上次校验通过的归档，或被切断的传输；下载别的归档或关闭设置窗口时删掉。
- **安装记录保存来源与内容摘要。** 市场来源与磁盘来源分别记录，内容摘要绑定本次批准的字节，不证明发布者身份。同 ID 的本地插件不会因为市场出现同名条目而被市场接管。
- **社区源预置但信任相同。** 预置的社区源与用户手动添加的第三方源信任相同：插件标为“社区”，安装前必须确认；用户删除后不会被自动加回。

## 考虑过的备选方案

- **官方插件随 Lithe 发版。** 未采用。插件与宿主已经解耦，绑定在一起会让无关改动触发重新发布。
- **社区插件也由 Lithe 签名。** 未采用。需要审核流程与签名基础设施，成本过高；现阶段使用固定 SHA-256、安装确认和内容摘要复查。
- **允许任意 HTTPS 下载地址。** 未采用。来源仓库无法与下载物对应。
- **为市场再引入一套完整 SVG/位图渲染依赖。** 未采用。本次只接通现有 SVG 能力，保持安装包和运行时依赖不变；复杂 SVG 与 PNG 需要以后在 Viva 统一支持。
- **把索引校验写在界面层。** 未采用。不同平台需要同样的规则，应只在 Core 写一次。

## 后果

- 新插件只要进入某个索引，宿主不需要改代码。
- 索引是社区维护的数据，它的收录与版本追踪规则写在 Lithe Store 的仓库中，主仓库只保存源地址。
- 当前 Viva 桌面端可以读取并展示经 Core 校验的市场列表与详情；设置窗口的安装流程（`desktop/internal/workbench/plugins.go`）经 `ArchiveSession` 调用下载器，再交给 `plugininstall` 解包、审查和安装，安装后的启用与卸载见 [Viva 确认安装即启用插件](../bug-fix/2026-11-13-viva-plugin-install-enables-and-uninstall-cleans-state.md)。
- 磁盘包可以离线安装，但没有仓库更新来源，替换时需要用户重新选择包并确认。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/core ./internal/marketplace ./internal/settingswindow -count=1`：覆盖市场索引、来源与详情。
- `scripts/desktop/desktop-go.sh test -race ./internal/marketplace -count=3`：覆盖下载校验、超限、重定向、取消后的清理、断开后续传、服务器不支持范围时从头下载、保留的字节有误时拒绝、无数据超时与不限总时长。
- `scripts/desktop/desktop-go.sh test ./internal/workbench -run TestMarketplaceDownloadIsNotBoundedByThePreparationTime -count=1`：下载请求不带解包的时间上限。
- `scripts/desktop/desktop-go.sh test ./internal/pluginicons ./internal/marketplace ./internal/settingswindow -run "Test(CompileSVG|FetchIcon|MarketplaceSVG)" -count=1`：覆盖 SVG 原色、降级、共享读取、失败缓存、限额与离页取消。带 `vivahead lithevisual` 标签的 `TestVisualMarketplaceSVG` 生成中英文和明暗主题的加载前后截图；它是离线合成条目，不代表真实市场或原生窗口验收。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：检查资源路径不写入发行目录。
- 索引与来源的共享夹具（`TestMarketplaceIndexFixture`、`TestMarketplaceValidatesCommunityStore`）位于 `desktop/internal/core/marketplace_test.go`。

## 适用范围

- `desktop/internal/core/marketplace.go`
- `desktop/internal/marketplace/archive_session.go`
- `desktop/internal/marketplace/download.go`
- `desktop/internal/marketplace/service.go`
- `desktop/internal/marketplace/icon.go`
- `desktop/internal/settingswindow/marketplace_icons.go`
- `desktop/internal/settingswindow/marketplace_view.go`
- `desktop/internal/workbench/plugins.go`
- `shared/platform-feature-matrix/features/plugin-marketplace.json`
- 索引契约的权威来源：[Lithe-core-rust `shared/plugins/contract/v1/`](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/shared/plugins/contract/v1)
