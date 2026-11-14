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
- **资源上限。** 下载时边收边计数，超过 512 MiB 立即中止；索引超过 5 MiB 也会被拒绝。ZIP 解压前检查中央目录声明的展开大小与文件数，解压过程中也要实测，因为压缩包可以谎报大小。
- **安装记录保存来源与内容摘要。** 市场来源与磁盘来源分别记录，内容摘要绑定本次批准的字节，不证明发布者身份。同 ID 的本地插件不会因为市场出现同名条目而被市场接管。
- **社区源预置但信任相同。** 预置的社区源与用户手动添加的第三方源信任相同：插件标为“社区”，安装前必须确认；用户删除后不会被自动加回。

## 考虑过的备选方案

- **官方插件随 Lithe 发版。** 未采用。插件与宿主已经解耦，绑定在一起会让无关改动触发重新发布。
- **社区插件也由 Lithe 签名。** 未采用。需要审核流程与签名基础设施，成本过高；现阶段使用固定 SHA-256、安装确认和内容摘要复查。
- **允许任意 HTTPS 下载地址。** 未采用。来源仓库无法与下载物对应。
- **把索引校验写在界面层。** 未采用。不同平台需要同样的规则，应只在 Core 写一次。

## 后果

- 新插件只要进入某个索引，宿主不需要改代码。
- 索引是社区维护的数据，它的收录与版本追踪规则写在 Lithe Store 的仓库中，主仓库只保存源地址。
- 当前 Viva 桌面端可以读取并展示经 Core 校验的市场列表与详情；下载器（`desktop/internal/marketplace/download.go`）已实现校验与大小限制，但还没有生产调用者，解压、签名验证、安装审批和安装尚未接通，因此市场界面不能作为插件安装已经完成的证据。
- 磁盘包可以离线安装，但没有仓库更新来源，替换时需要用户重新选择包并确认。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/core ./internal/marketplace ./internal/settingswindow -count=1`：覆盖市场索引、来源与详情。
- `scripts/desktop/desktop-go.sh test -race ./internal/marketplace -count=3`：覆盖下载校验、超限、重定向、取消后的清理。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：检查资源路径不写入发行目录。
- 索引与来源的共享夹具（`TestMarketplaceIndexFixture`、`TestMarketplaceValidatesCommunityStore`）位于 `desktop/internal/core/marketplace_test.go`。

## 适用范围

- `desktop/internal/core/marketplace.go`
- `desktop/internal/marketplace/download.go`
- `desktop/internal/marketplace/service.go`
- `desktop/internal/settingswindow/marketplace_view.go`
- `shared/platform-feature-matrix/features/plugin-marketplace.json`
- 索引契约的权威来源：[Lithe-core-rust `shared/plugins/contract/v1/`](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/shared/plugins/contract/v1)
