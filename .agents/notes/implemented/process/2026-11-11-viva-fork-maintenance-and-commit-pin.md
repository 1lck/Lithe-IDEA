# Agent 笔记：Viva 由 Lithe-IDEA/viva 维护，发版固定到 fork 的 commit

状态：已实现

## 先说结论

Lithe 桌面端构建时用的 Viva 源码，来自组织仓库 [Lithe-IDEA/viva](https://github.com/Lithe-IDEA/viva)（上游 [vivaui/viva](https://github.com/vivaui/viva) 的 fork，即分叉仓库），由 `desktop/go.mod` 的 `replace` 固定到其中一个 commit。这个仓库 2026-11-14 改名为 Lithe-IDEA/Lithe-viva，旧地址会自动跳转，`desktop/go.mod` 仍写旧路径。Viva 的问题先在 fork 修好并合进 fork 的 `main`，Lithe 当天改 `replace` 用上；同一个修复分支同时向上游提 PR。发版只认 `desktop/go.mod` 和 `desktop/go.sum` 固定的 commit，不等上游合入或打 tag。

每次发布桌面端之前，先把上游同步进 fork `main`：我们自己的补丁全部合入，和上游方案冲突时以上游为准，Lithe 里已经能换成上游新写法的绕过代码一并删除，最后写一份同步报告。做法见“发版前同步上游”。

## 问题

- 上游 PR 什么时候合入不由 Lithe 决定。只能等上游的话，Lithe 要么把问题挂着，要么在应用层写绕过代码，上游修好后还得再删。例子是 List 滚动请求那一帧显示旧偏移（[#1820](https://github.com/1lck/Lithe-IDEA/issues/1820)）。
- 依赖个人 fork 或本地路径不可靠：个人仓库的权限和存续不归组织；本地路径只有本机能构建，CI 和其他开发者无法复现。
- Go 的 `go run <包>@<版本>` 和 `go install <包>@<版本>` 会忽略 `go.mod` 的 `replace`。仓库脚本原来就用这种写法取 Viva 命令行工具（图标编译器、打包工具）。一旦用了 fork，这些脚本会悄悄改用上游同版本号的工具，和应用实际链接的源码不一致；fork 独有的 commit 上游根本没有，会直接失败。
- fork 和上游的差距如果只在想起来时才处理，会越积越大：2026-11-15 时 fork `main` 已经落后上游 86 个提交。上游可能已经用另一种写法解决了我们补丁解决的问题，两套写法并存，fork 就越来越偏离上游，每次同步都要重复解同一批冲突。Lithe 里为旧版 Viva 写的绕过代码（清单见 [#1821](https://github.com/1lck/Lithe-IDEA/issues/1821)），上游修好后如果没人去删，就会一直留着。
- 同步 PR 被 squash（压成一个提交）合入后，fork 和上游的共同历史就断了。fork #16 合入后成了只有一个父提交的 `609dd47`。从此 `git log upstream/main..main` 会把上游早已有的提交也算成 fork 独有，看不出哪些补丁还没进上游，下次同步还要在同一批文件上再解一次冲突。`609dd47` 在 Windows 上还编译失败：上游和 fork 的补丁用了同一个窗口消息号。这个问题一直没被发现，因为合并后只在 macOS 上跑过测试。

## 决策

### `desktop/go.mod` 的写法

```text
require github.com/vivaui/viva <fork 所基于的上游 commit 的伪版本>
replace github.com/vivaui/viva => github.com/Lithe-IDEA/viva <fork commit 的伪版本>
```

- 代码里的 import 路径不变，仍是 `github.com/vivaui/viva/...`。fork 的 `go.mod` 保持 `module github.com/vivaui/viva`，不改模块名，这样同一个修复分支可以原样向上游提 PR。
- 真正参与构建的是 `replace` 指向的版本。`require` 写 fork 当前合入的上游 commit，读者一眼能看出基线是上游的哪一版。
- fork 的补丁 commit 没有自己的 tag，`replace` 写伪版本（pseudo-version，Go 用“最近的 tag + 时间戳 + 12 位 commit hash”生成的版本号，例如 `v0.6.1-0.20261111063413-7edac95eed01`），它就代表 commit ID。`require` 写 fork 所基于的上游 tag；基线不是 tag 时写上游 commit 的伪版本。`desktop/go.sum` 里只留 `replace` 目标的条目；它的哈希和上游同一 commit 的哈希不同，这是正常的。
- 不要用本地路径 `replace`（`=> ../viva`）提交。本地调试可以临时用，提交前必须换回 fork 的 commit。

### fork 的分支规则

- fork 的 `main` 是集成分支，内容是“上游 `main` + 还没被上游合入的 Lithe 修复”。Lithe 只固定 fork `main` 上的 commit。
- 同步上游只用 merge（没有本地补丁时快进）。同步 PR 在 GitHub 上选 “Create a merge commit” 合入，不 squash；修复补丁的 PR 可以 squash。不 rebase，不 force push。Lithe 已发布版本固定的 commit 必须一直能取到，否则旧版本无法重新构建。
- GitHub 不会自动同步 fork：分支只在创建 fork 时复制一次，Release 从不复制，tag 在默认的“只复制 main 分支”下也不会带过来。所以同步是手动的：merge 上游 `main` 之后，用 `git push <fork> 'refs/tags/*:refs/tags/*'` 把上游的 tag 原样推到 fork，推之前先确认本地 tag 和 `git ls-remote --tags --refs <上游>` 完全一致。tag 必须同步，否则 fork commit 的伪版本没有基线，只能写成 `v0.0.0-…`，看不出基于上游哪个版本。
- fork 不建 Release，也不复制上游的 Release。Lithe 从源码构建 Viva 命令行工具，用不到 Release 里的二进制；复制过来会多出一个看起来像官方的下载渠道，而 Homebrew/Scoop 清单仍然指向上游。上游的 `release.yml` 在推送 `v*` tag 时触发，fork 的工作流目前没有启用；以后要在 fork 启用 Actions，先停用这个工作流和上游 CI。
- 修复从上游 `main` 切分支（例如 `fix/list-scroll-request-offset`），推到 fork，从这个分支向 vivaui/viva 提 PR，同时把它合进 fork `main`。上游 PR 按上游的 `CONTRIBUTING.md` 和 PR 模板准备：格式、`go vet`、`go test`、涉及绘制/布局/输入的基准、可视证据、边界与成本。
- 上游要求修改时，在同一分支追加 commit，再把更新合进 fork `main`；不改写已经合进 `main` 的历史。
- 上游合入后，下次同步上游时补丁自然消失。在 fork 里运行 `git log upstream/main..main` 应该只剩尚未合入上游的补丁，每一条都要有对应的上游 PR。
- 上游拒绝的补丁不长期留在 fork：先和上游讨论替代做法，或把能力移到 Lithe 应用层，然后用 revert commit 从 fork `main` 移除。

### 升级固定的 commit

1. 用 `go -C desktop list -m github.com/Lithe-IDEA/viva@<fork commit>` 得到 fork 伪版本；用 `go -C desktop list -m github.com/vivaui/viva@<上游基线 commit>` 得到上游伪版本。上游基线就是 fork 里 `git merge-base upstream/main main` 的结果。
2. 用 `go -C desktop mod edit` 同时改写 `-require` 和 `-replace`，再运行 `go -C desktop mod tidy` 更新 `go.sum`。
3. 正确做法：`replace` 的目标写伪版本，并且这个 commit 在 fork `main` 上。不要这样做：指向修复分支上还没合进 `main` 的 commit；以后修复分支被删或改写，这个版本就可能取不到。

### 发版前同步上游

每次发布桌面端（`desktop-v*` 预发布版和稳定版）之前做一次。发版时由 `.agents/skills/release-lithe/SKILL.md` 检查 fork 的状态；发现差距就停下来提醒用户，由用户授权后才按下面的步骤做。Lithe 的固定版本升级合入 main 以后，才开始写发布说明，因为同步会改变这个版本包含的内容。

1. **盘点。** 在 fork 的克隆里 fetch 上游和 fork，然后列出四样东西：
   - `git log --oneline main..upstream/main`：上游有、fork 还没有的提交。
   - `git log --oneline --cherry-mark --right-only upstream/main...main`：fork 独有的提交，也就是我们自己的补丁。上游用 squash 合入我们的 PR 后，fork 里原来的提交仍会出现在这里；内容和上游某个提交相同的标为 `=`，其余标为 `+`，标 `+` 的要逐个对照对应上游 PR 的状态。
   - `gh pr list --repo Lithe-IDEA/Lithe-viva --state open`：还没合进 fork `main` 的补丁。
   - Lithe 里的绕过代码：[#1821](https://github.com/1lck/Lithe-IDEA/issues/1821) 中未完成的项，以及 `desktop/` 里引用 Viva PR 或 Issue（`vivaui/viva#`、`Lithe-IDEA/viva#`、`Lithe-viva#`）的注释和被跳过的测试。
2. **合入上游。** 从 fork `main` 切一个同步分支，`git merge upstream/main`，推到 fork 后开 PR，用 merge commit 合进 fork `main`，然后补推上游的 tag（见“fork 的分支规则”）。
3. **合入我们自己的补丁。** 每个 open 的 fork PR，先把同步后的 fork `main` merge 进自己的分支，解决冲突、跑测试，再合进 fork `main`。全部合入，只有被上游方案取代的才关闭（见第 4 步）。没做完或测试不过、合不进来的，在报告里列出来，由用户决定这次发版要不要等它。fork 独有、还没有上游 PR 的补丁，按“fork 的分支规则”从上游 `main` 切分支补提上游 PR。
4. **冲突以上游为准。** 我们的补丁和上游改了同一处，或者上游用另一种做法解决了同一个问题时：
   - 保留上游的实现，删掉我们的写法。冲突块取上游一侧；已经合进 fork `main` 的补丁用 revert 撤掉。Lithe 的调用点改用上游的 API。
   - 关闭对应的上游 PR 和 fork PR，在评论里写明被上游哪个提交取代。
   - 上游的做法缺少 Lithe 需要的能力时，仍然先换成上游的做法，再在它上面补一个小补丁，并按“fork 的分支规则”向上游提 PR。
   - 正确做法：上游提供了和 fork 补丁作用相同的 API，就让 Lithe 改用上游的 API，并 revert fork 的补丁。不要这样做：在冲突块里把两边的代码都留下，或者为了迁就 Lithe 的旧调用，去改上游 API 的名字或签名。
5. **检查另一个平台。** fork `main` 每合入一次，都在 fork 里运行 `GOOS=windows GOARCH=amd64 go build ./...` 和 `GOOS=windows GOARCH=arm64 go build ./...`，在 macOS 上也能发现 Windows 的编译错误（`609dd47` 的重复消息号就会在这里报错）。
6. **删掉 Lithe 里的旧绕过。** 从最新 main 切一个分支，把 `replace` 升到同步后的 fork `main`（见“升级固定的 commit”）。然后对照新版本，逐项检查第 1 步列出的绕过代码：上游已经有合适做法的，改用新写法，删掉旧逻辑，恢复因此被跳过的测试，并更新 #1821。还不能删的，在报告里写明还缺什么，以及对应哪个 PR 或 Issue。固定版本升级和这些删除放在同一个 Lithe PR 里。
7. **写同步报告。** 报告写进第 6 步那个 Lithe PR 的说明里，同时发给用户。报告包括：
   - 基线：同步前后 fork `main` 的 commit、合入的上游提交范围、新的固定伪版本。
   - 上游带来的、会影响 Lithe 的变化：新增或改名的 API、行为变化。
   - 我们每一个补丁的结果：已经进了上游、仍然只在 fork 里（附上游 PR）、被上游方案取代（附取代它的上游提交和 revert）、这次新合入。
   - 每一处冲突：在哪个文件、按上游怎么解决、Lithe 跟着改了什么。
   - 删掉的绕过代码，以及改用的新写法；还留着的绕过代码，以及原因。
   - 验证：运行了哪些命令、在哪些平台上、结果如何。没有跑的检查也要写明原因。

### 列表身份兼容检查

升级含行标识检查的 Viva 时，检查所有 `ListState.Key` 和 `TreeState.Key`：包括不可选择的加载页脚也必须返回 0 至 2^31−1 的唯一标识。不能用负数表达“不能选择”，也不能对摘要做截断来代替唯一编号。Git 历史视图保留 0 给加载页脚、提交从 1 编号，提交重排时复用原编号；是否允许选择仍由原来的交互逻辑决定。新建项目侧栏为两个标题固定保留 0/1，条目从 2 开始，过滤隐藏分组不改编号；Git 控制台也为刷新时暂缺的行保留 0，真实行从 1 编号。此处是 Viva 呈现身份，留在视图，不改变 Core 的提交模型。回归 `TestLogCommitKeysKeepFooterInRangeAndSeparate` 覆盖范围、唯一性和重排稳定性。

### 需要 Viva 命令行工具的脚本

- 从 `desktop/go.mod` 解析出的源码目录构建：先 `go -C desktop mod download github.com/vivaui/viva`，再用 `go -C desktop list -m -f '{{.Dir}}' github.com/vivaui/viva` 得到目录，然后 `go -C <目录> build ./cmd/viva`。这样会遵守 `replace`，并用 Viva 自己的 `go.mod` 和 `go.sum`，不依赖桌面模块的 `go.sum`。
- 在 `desktop/` 模块里临时运行工具时，用不带版本的 `go run github.com/vivaui/viva/cmd/viva`，它也遵守 `replace`。
- 不要再写 `go run` 或 `go install` 的 `github.com/vivaui/viva/cmd/viva@<版本>`。
- 打包脚本按“实际构建的源码版本”（有 `replace` 时取它的伪版本）缓存工具；本地路径替换没有版本，每次都重新构建。

### 发版和 PR 说明

发版构建直接使用 `desktop/go.mod` 和 `desktop/go.sum` 固定的 commit，不需要上游 tag。改动 Viva 固定版本的 PR，要在说明里写清楚新固定的 fork commit、它比上游多出的补丁，以及每个补丁对应的上游 PR。

## 考虑过的备选方案

- **只依赖上游，等上游合入和发版**：修复周期不可控。Lithe 会积累只为等上游而存在的绕过代码，上游修好后还要再清理。
- **依赖个人 fork**：仓库归个人，组织成员不能维护，权限和存续也没有保证。
- **提交本地路径 `replace`**：只有本机能构建，CI 和其他开发者都无法复现。
- **fork 另开 `lithe` 分支，`main` 只跟上游一致**：多一层分支，而 fork 的 `main` 本身没人用。把集成放在 `main`，打开 fork 看到的就是 Lithe 实际使用的代码。
- **把 fork 的模块名改成 `github.com/Lithe-IDEA/viva`**：所有 import 都要改；向上游提 PR 时还得再改回去，补丁不能原样复用。
- **用 `go.mod` 的 `tool` 指令声明 Viva 命令行工具**：会把打包、签名等工具依赖写进桌面模块的 `go.mod` 和 `go.sum`，和应用依赖混在一起。从模块目录构建，用 Viva 自己的依赖清单就够了。
- **只在出问题或需要上游新功能时才同步**：2026-11-15 的 86 个提交差距就是这样攒出来的。差距越大，一次同步要解的冲突越多，也越难看清上游已经替我们解决了哪些问题。
- **冲突时保留我们的补丁**：fork 会永久偏离上游，每次同步都要重新解同一处冲突；同一个问题的两种写法并存，Lithe 也不知道该用哪个 API。
- **同步 PR 用 squash 合入**：会断开 fork 和上游的共同历史，见“问题”里 `609dd47` 的例子。
- **用 CI 定时自动同步**：冲突要人来判断按上游怎么改、Lithe 跟着改什么，自动化做不了；仓库也不增加额外的 CI 步骤，Actions 用量有限。改为发版时由 release-lithe 检查并提醒。

## 后果

- Lithe 能当天用上自己的 Viva 修复，不必在应用层写绕过代码。
- 维护成本：每次发布桌面端之前都要把上游合进 fork `main`、合入我们的补丁、清理 Lithe 里的旧绕过并写同步报告，并持续跟进每个上游 PR。没进上游的补丁越多，同步时冲突越多，所以补丁要尽快送上游。
- 每次发版前都同步，差距一直保持在一个发版周期以内，冲突少、容易判断；代价是发版要等同步和固定版本升级合入 main。
- 冲突以上游为准，有时要放弃我们已经合入的写法，并修改 Lithe 的调用点。换来的是 fork 的补丁越来越少，最终回到只依赖上游。
- fork `main` 不能 force push。建议在 GitHub 给 Lithe-IDEA/viva 的 `main` 开启分支保护，禁止强制推送和删除。
- 第一次通过 goproxy.cn 查询新的 fork 伪版本时，校验和数据库代理偶尔返回 404（“temporarily unavailable”），重试即可。这不是 `go.sum` 错误。
- 只构建 `desktop/` 的开发者不受影响，`go build`、`go test` 会自动遵守 `replace`。

## 验证

- `./scripts/desktop/desktop-go.sh test ./...`
- `./scripts/desktop/generate-desktop-icons.sh` 与 `./scripts/desktop/generate-desktop-file-icons.sh`：用 fork 源码构建的编译器重新生成，输出与已提交的 `icons.go`、`icons_tree.go` 逐字节一致。
- `./scripts/desktop/desktop-go.sh --exec go run github.com/vivaui/viva/cmd/viva vet ./...`
- `./scripts/agent-notes/verify-agent-notes.sh`
- 在 fork 里检查 `git log upstream/main..main`，确认每个补丁都有对应的上游 PR。
- 同步上游或合入补丁后，在 fork 里运行 `go test ./...`、`GOOS=windows GOARCH=amd64 go build ./...` 和 `GOOS=windows GOARCH=arm64 go build ./...`。
- 同步后在 fork 里运行 `git merge-base --is-ancestor upstream/main main`，确认上游 `main` 已经是 fork `main` 的祖先，共同历史没有断开。

## 适用范围

- `.agents/skills/release-lithe/SKILL.md`
- `desktop/go.mod`
- `desktop/go.sum`
- `scripts/desktop/generate-desktop-icons.sh`
- `scripts/desktop/generate-desktop-file-icons.sh`
- `scripts/desktop/package-desktop.sh`
- [Lithe-IDEA/viva](https://github.com/Lithe-IDEA/viva)
