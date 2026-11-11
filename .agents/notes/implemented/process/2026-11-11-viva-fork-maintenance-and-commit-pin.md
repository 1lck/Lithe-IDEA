# Agent 笔记：Viva 由 Lithe-IDEA/viva 维护，发版固定到 fork 的 commit

状态：已实现

## 先说结论

Lithe 桌面端构建时用的 Viva 源码，来自组织仓库 [Lithe-IDEA/viva](https://github.com/Lithe-IDEA/viva)（上游 [vivaui/viva](https://github.com/vivaui/viva) 的 fork，即分叉仓库），由 `desktop/go.mod` 的 `replace` 固定到其中一个 commit。Viva 的问题先在 fork 修好并合进 fork 的 `main`，Lithe 当天改 `replace` 用上；同一个修复分支同时向上游提 PR。发版只认 `desktop/go.mod` 和 `desktop/go.sum` 固定的 commit，不等上游合入或打 tag。

## 问题

- 上游 PR 什么时候合入不由 Lithe 决定。只能等上游的话，Lithe 要么把问题挂着，要么在应用层写绕过代码，上游修好后还得再删。例子是 List 滚动请求那一帧显示旧偏移（[#1820](https://github.com/1lck/Lithe-IDEA/issues/1820)）。
- 依赖个人 fork 或本地路径不可靠：个人仓库的权限和存续不归组织；本地路径只有本机能构建，CI 和其他开发者无法复现。
- Go 的 `go run <包>@<版本>` 和 `go install <包>@<版本>` 会忽略 `go.mod` 的 `replace`。仓库脚本原来就用这种写法取 Viva 命令行工具（图标编译器、打包工具）。一旦用了 fork，这些脚本会悄悄改用上游同版本号的工具，和应用实际链接的源码不一致；fork 独有的 commit 上游根本没有，会直接失败。

## 决策

### `desktop/go.mod` 的写法

```text
require github.com/vivaui/viva <fork 所基于的上游 commit 的伪版本>
replace github.com/vivaui/viva => github.com/Lithe-IDEA/viva <fork commit 的伪版本>
```

- 代码里的 import 路径不变，仍是 `github.com/vivaui/viva/...`。fork 的 `go.mod` 保持 `module github.com/vivaui/viva`，不改模块名，这样同一个修复分支可以原样向上游提 PR。
- 真正参与构建的是 `replace` 指向的版本。`require` 写 fork 当前合入的上游 commit，读者一眼能看出基线是上游的哪一版。
- fork 没有 tag，伪版本（pseudo-version，Go 用“时间戳 + 12 位 commit hash”生成的版本号）就是 commit ID。`desktop/go.sum` 里只留 `replace` 目标的条目；它的哈希和上游同一 commit 的哈希不同，这是正常的。
- 不要用本地路径 `replace`（`=> ../viva`）提交。本地调试可以临时用，提交前必须换回 fork 的 commit。

### fork 的分支规则

- fork 的 `main` 是集成分支，内容是“上游 `main` + 还没被上游合入的 Lithe 修复”。Lithe 只固定 fork `main` 上的 commit。
- 同步上游只用 merge（没有本地补丁时快进）。不 rebase，不 force push。Lithe 已发布版本固定的 commit 必须一直能取到，否则旧版本无法重新构建。
- 修复从上游 `main` 切分支（例如 `fix/list-scroll-request-offset`），推到 fork，从这个分支向 vivaui/viva 提 PR，同时把它合进 fork `main`。上游 PR 按上游的 `CONTRIBUTING.md` 和 PR 模板准备：格式、`go vet`、`go test`、涉及绘制/布局/输入的基准、可视证据、边界与成本。
- 上游要求修改时，在同一分支追加 commit，再把更新合进 fork `main`；不改写已经合进 `main` 的历史。
- 上游合入后，下次同步上游时补丁自然消失。在 fork 里运行 `git log upstream/main..main` 应该只剩尚未合入上游的补丁，每一条都要有对应的上游 PR。
- 上游拒绝的补丁不长期留在 fork：先和上游讨论替代做法，或把能力移到 Lithe 应用层，然后用 revert commit 从 fork `main` 移除。

### 升级固定的 commit

1. 用 `go -C desktop list -m github.com/Lithe-IDEA/viva@<fork commit>` 得到 fork 伪版本；用 `go -C desktop list -m github.com/vivaui/viva@<上游基线 commit>` 得到上游伪版本。上游基线就是 fork 里 `git merge-base upstream/main main` 的结果。
2. 用 `go -C desktop mod edit` 同时改写 `-require` 和 `-replace`，再运行 `go -C desktop mod tidy` 更新 `go.sum`。
3. 正确做法：`replace` 的目标写伪版本，并且这个 commit 在 fork `main` 上。不要这样做：指向修复分支上还没合进 `main` 的 commit；以后修复分支被删或改写，这个版本就可能取不到。

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

## 后果

- Lithe 能当天用上自己的 Viva 修复，不必在应用层写绕过代码。
- 维护成本：要定期把上游合进 fork `main`，并跟进每个上游 PR。没进上游的补丁越多，同步时冲突越多，所以补丁要尽快送上游。
- fork `main` 不能 force push。建议在 GitHub 给 Lithe-IDEA/viva 的 `main` 开启分支保护，禁止强制推送和删除。
- 第一次通过 goproxy.cn 查询新的 fork 伪版本时，校验和数据库代理偶尔返回 404（“temporarily unavailable”），重试即可。这不是 `go.sum` 错误。
- 只构建 `desktop/` 的开发者不受影响，`go build`、`go test` 会自动遵守 `replace`。

## 验证

- `./scripts/desktop/desktop-go.sh test ./...`
- `./scripts/desktop/generate-desktop-icons.sh` 与 `./scripts/desktop/generate-desktop-file-icons.sh`：用 fork 源码构建的编译器重新生成，输出与已提交的 `icons.go`、`icons_tree.go` 逐字节一致。
- `./scripts/desktop/desktop-go.sh --exec go run github.com/vivaui/viva/cmd/viva vet ./...`
- `./scripts/agent-notes/verify-agent-notes.sh`
- 在 fork 里检查 `git log upstream/main..main`，确认每个补丁都有对应的上游 PR。

## 适用范围

- `desktop/go.mod`
- `desktop/go.sum`
- `scripts/desktop/generate-desktop-icons.sh`
- `scripts/desktop/generate-desktop-file-icons.sh`
- `scripts/desktop/package-desktop.sh`
- [Lithe-IDEA/viva](https://github.com/Lithe-IDEA/viva)
