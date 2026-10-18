# Agent 笔记：用自建 Mac mini 承担 macOS CI

状态：已否决：自建 Runner 离线时没有回退，还让 fork 代码跑在一台长期存活的机器上

## 先说结论

2026-10-16 起，我们在一台 Mac mini 上注册了三个自建 Runner（GitHub Actions
的执行器，负责真正跑 job），想减少对 GitHub 托管 macOS 并发名额（全组织
同时最多 5 个）的占用。它确实有效，但 2026-10-18 这台机器上的 Runner 与 Xcode
同时消失，CI 没有自动回退到托管 Runner，排队的 job 一直卡住。现在 macOS CI
全部回到 GitHub 托管的 `macos-26`。以后如果再考虑自建 Runner，先解决“离线时
怎么办”和“fork 代码在哪里跑”这两个问题，再谈提速。

## 问题

GitHub Free 计划下，全组织同时最多运行 5 个托管 macOS job。多个 PR 同时推送时，
macOS job 经常排队，10-16 观察到最长排队约 16 分钟。同时，反复重跑和大量推送
让托管 macOS 的使用量偏高，维护者希望把最贵的那部分挪到自己的机器上。

## 提案

按当时最强的形态描述：同一台 M4/16 GB Mac mini 上注册三个独立 Runner，各自有
独立的安装和工作目录，带 `lithe-mac-mini` 标签，再按编译配置分成 debug 组和
release 组，让同一组 Runner 保留增量编译结果。一个选择脚本在 Linux 分类 job 里
统计仓库正在运行和排队的 job，优先把 PR 的 macOS lane 分给空闲的 Mac mini，
满了再用托管 Runner；push 到 `preview` 和手动运行只用 Mac mini。对开发者的影响是
大部分 macOS 验证更快，托管名额留给排队的 PR。

这套方案经过 #1258、#1262、#1268、#1279 逐步落地，实测过三并发。当时的效果：
全部 macOS job 在托管 Runner 上每小时约 228 分钟墙钟耗时（10-15 12:00 到 10-16
12:00），启用后降到每小时约 30～78 分钟（这是按 job 起止时间估算的墙钟分钟，不是
账单分钟）。

## 考虑过的备选方案

### 当前采用的方案

全部回到 GitHub 托管的 `macos-26`。代价是重新受 5 个并发名额限制，PR 多时会排队；
好处是没有需要人工维护的机器，不存在“Runner 不在线”的状态，fork 代码也只在
一次性的托管虚拟机里运行。

### 保留 Mac mini，只给可信的 PR 使用

需要把 fork 的 PR 单独分流，并且要在分类阶段知道 Runner 是否在线。选择脚本当时
只能统计排队和运行中的 job，看不到 Runner 在线状态；用有管理权限的令牌去查在线
状态，又会让 PR 工作流持有不该有的权限。这两项的维护成本高于当时的收益，没有
实现。

### 排队超时后自动取消重投

GitHub 在创建 job 时就固定了 `runs-on`，排队后不能改投另一个池。取消重投会浪费
已经排队的时间，实现也复杂，没有采用。

## 否决理由

三件事叠在一起，使这个方案的风险高于它节省的名额：

1. **离线时没有回退。** 选择脚本只统计 job，不知道 Runner 是否在线。Runner 离线
   时，被分到 Mac mini 的 job 会一直排队；push 到 `preview` 的运行更是强制只用
   Mac mini，不会回落到托管 Runner。2026-10-18 就有一个 PR 的 job 和一次
   `preview` push 的 job 在等离线的 Runner。
2. **Runner 随机器状态一起消失。** 10-18 约 14:27，这台机器上三套 Runner 的安装
   文件被清空（有两套只剩工作目录里的 `_work`，另一套的目录在家目录下找不到），同一时间 CI
   日志出现 `/Applications/Xcode.app/Contents/Developer` 不存在。机器疑似被重置，
   具体原因没有查明。系统服务（launchd）配置还在，但找不到要启动的程序，退出码
   为 78。这类服务是用户级的，依赖该用户登录桌面；重启后没有自动登录，Runner
   就不会回来。
3. **fork 代码跑在长期存活的机器上。** 文档与 workflow 允许 fork 提交到本仓库的
   PR 使用这些 Runner。保留构建输出的做法（`clean: false`）也不是对恶意代码的
   隔离边界。

另外两处环境差异也要记住：Mac mini 运行 macOS 27，而托管 Runner 是 macOS 26。
macOS 27 上 `CGWindowListCopyWindowInfo` 返回空，导致 WindowServer 透明度检查无法
执行（#1278，现在测试在窗口列表不可用时按原因跳过这一项）；机器上同时装有更新的
Command Line Tools，链接 x86_64 时曾解析到不兼容的 SDK。

未来可以重新评估的条件：使用不与其他用途共用的专用硬件；Runner 以不依赖登录的
方式自启并有离线告警；选择阶段能知道 Runner 是否在线并在离线时回退；fork 代码
只在每个 job 都全新的环境里运行。

## 适用范围

- `docs/ci-builds.md`
- `.github/workflows/ci-macos.yml`
- `.github/workflows/ci-plugins.yml`
- `.github/actions/setup-macos-toolchain/action.yml`
- `.agents/notes/implemented/process/2026-09-13-ci-build-cache-and-artifact-strategy.md`
