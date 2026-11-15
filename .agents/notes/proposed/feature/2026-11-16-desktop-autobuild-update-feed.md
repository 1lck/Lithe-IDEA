# Agent 笔记：AutoBuild 更新源与预发布版本号

状态：提议中

## 先说结论

桌面端客户端已经能从 AutoBuild 渠道检查更新（见 [更新渠道与更新对话框](../../implemented/feature/2026-11-15-desktop-update-channels-and-dialog.md)），但 `autobuild.json` 还没有发布。原因是每个 AutoBuild 包都沿用 `desktop/viva.toml` 的版本号（如 `0.7.0`），同一渠道里前后两次构建的版本相同，客户端看不出哪个更新。

本提案让 AutoBuild 的版本号带上预发布后缀 `0.7.0-autobuild.<UTC 时间>`，再像正式版一样签名发布 `autobuild.json`。这一步要先改 Lithe-IDEA/viva fork：Viva 的打包清单（manifest）现在只接受纯数字版本号。fork 的改动必须同时向上游 vivaui/viva 提 PR，并由维护者授权后才做。

## 问题

1. **同一渠道版本号相同。** `scripts/ci/desktop-autobuild/package-autobuild.sh` 用 `viva.toml` 的版本打包。客户端拿运行版本和 `autobuild.json` 比较，两次构建都是 `0.7.0`，永远不会提示更新。
2. **Viva 打包拒绝预发布版本号。** fork 的 `tools/manifest/manifest.go` 用 `^[0-9]+(\.[0-9]+){0,2}$` 校验版本，`viva package` 不接受 `0.7.0-autobuild.20261116100000`。
3. **各平台的版本字段格式不同。**
   - macOS：`update/install_darwin.go` 要求包内 `CFBundleShortVersionString` 与更新源版本完全一致；Apple 又要求这个字段和 `CFBundleVersion` 是点分数字。
   - Windows：`VERSIONINFO` 的文件版本只能是四段数字。
   - deb 和 rpm 对 `-` 有各自的含义：deb 用 `~` 表示“早于”，rpm 的 `Version` 不能含 `-`。
4. 比较本身没问题：Viva 的 `update.Compare` 已按 SemVer 2.0.0 排预发布版本，`0.7.0-autobuild.20261116` 早于 `0.7.0`，同一后缀按时间排序。

## 提案

### 1. Viva fork：清单接受 SemVer 预发布版本，按格式映射

- 清单版本允许 `MAJOR.MINOR.PATCH-<预发布>`，预发布部分按 SemVer 规则校验；不带后缀的版本行为不变。
- 每种格式写自己能接受的字段，同时把完整版本记在包里，供安装器核对：
  - macOS：`CFBundleShortVersionString` 写基础版本 `0.7.0`，`CFBundleVersion` 写数字构建号；完整版本写入单独的 Info.plist 键，`install_darwin.go` 改为核对这个键（缺省时退回 `CFBundleShortVersionString`，兼容旧包）。
  - Windows：文件版本写 `0.7.0.<构建号>`，产品版本字符串写完整版本。
  - deb 写 `0.7.0~autobuild.<时间>`；rpm 的 `Version` 写 `0.7.0`，`Release` 写 `autobuild.<时间>`。
- 先合进 fork `main`，同一分支向上游 vivaui/viva 提 PR；然后升级 `desktop/go.mod` 的 `replace`。Lithe 不在应用层改写打包结果来绕过。

### 2. Lithe：AutoBuild 版本号和更新源

- `package-autobuild.sh` 把版本设为 `<viva.toml 版本>-autobuild.<UTC YYYYMMDDHHMMSS>`，时间取工作流 `prepare` 的同一个时间戳，所有平台一致。
- `scripts/ci/desktop-release/publish-update-feed.sh` 增加渠道参数，AutoBuild 写 `autobuild.json`、`.sig` 和 `autobuild.notes.md`，并发组 `desktop-update-feed-autobuild`。私钥同样只交给发布更新源的任务。
- **增量补丁的基线**是当前 `autobuild.json` 提供的版本。滚动 release `desktop-AutoBuild` 会被新构建覆盖，所以必须在覆盖之前下载旧归档，并对照更新源摘要校验；取不到就只发布完整包。
- **日志**由上一次 AutoBuild commit 到本次 commit 之间的 first-parent 提交（PR 标题和编号）生成，超长截断并附 compare 链接。

## 考虑过的备选方案

### 版本号加第四段数字（`0.7.0.<构建号>`）

不用改预发布语义，Windows 也天然接受。

不采用：清单只允许三段，`update.Compare` 也不认第四段；这种版本还会比同号正式版“更新”，和“AutoBuild 朝着下一个正式版构建”的含义相反。

### 每次 AutoBuild 提升 PATCH（`0.7.<时间>`）

纯数字，Viva 不用改。

不采用：占用正式版的版本空间，`0.7.20261116` 会大于以后所有 `0.7.x` 正式版，跨渠道“等下一个正式版”的规则失效。

### Lithe 在 `viva package` 之后改写版本字段

不用等 fork。

不采用：改写会破坏 macOS 签名和 Windows 签名，也违反“Viva 的问题在 fork 修复，不在 Lithe 写绕过代码”的规则。

## 验收标准

- `viva package` 能打包 `0.7.0-autobuild.<时间>`，macOS、Windows、deb、rpm 各自的版本字段合法，签名和公证通过。
- 连续两次 AutoBuild 之后，装着前一次构建的客户端能发现、下载（含增量补丁）并安装后一次构建；补丁不可用时回退完整包。
- AutoBuild 用户切回正式版时，“等下一个正式版”只在更高的正式版出现时提示。
- `autobuild.notes.md` 首行版本与 `autobuild.json` 一致，对话框显示这次构建的提交列表。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh` 通过。

## 风险

- **macOS 版本核对改动影响已发布的包**：安装器新逻辑必须兼容没有新 Info.plist 键的旧包，否则正式版用户也更新不了。
- **上游不接受映射方案**：按 fork 维护规则以上游为准；在上游方案确定前，fork 补丁要保持小而可替换。
- **滚动 release 的旧字节**：发布顺序一旦颠倒（先覆盖再下载），这一轮只能发布完整包。

## 适用范围

- `desktop/viva.toml`
- `desktop/go.mod`
- `scripts/ci/desktop-autobuild/`
- `scripts/ci/desktop-release/publish-update-feed.sh`
- `.github/workflows/desktop-autobuild.yml`
