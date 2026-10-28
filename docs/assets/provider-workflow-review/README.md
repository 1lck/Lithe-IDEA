# Provider 工作流的原生视图检查

这些截图对应 PR #1517 的 review 补验，来自真实 SwiftUI/AppKit 视图。
Build 侧使用真实 Rust Core 计划和受控 Provider 回复，Run 侧使用现有 RunService
和进程替身；没有启动构建工具、Provider 后端或应用子进程。

| 场景 | 浅色 | 深色 |
| --- | --- | --- |
| 展开前的 Build 树 | [截图](build-collapsed-light.png) | [截图](build-collapsed-dark.png) |
| 展开后的测试清单与 Debug 入口 | [截图](build-discovery-debug-light.png) | [截图](build-discovery-debug-dark.png) |
| 缺少 generated.json 时的 Provider Run 输出 | [截图](provider-run-output-light.png) | [截图](provider-run-output-dark.png) |

Build 的前后两图是同一版本的折叠/展开状态对照，不是 preview 与 PR 的代码版本
对照。通过共享树的原生无障碍操作展开，测试同时等待发现的用例和 Debug 入口出现，
不注入私有视图状态。本轮两处修复改变异步生命周期，没有调整界面布局。

复验方式：

```bash
LITHE_BUILD_CAPTURE_DIR="$PWD/.artifacts/test-stability/provider-ui" \
  ./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh \
  -- --filter 'ProviderWorkflowPresentationTests|preparedProviderOutputRendersWithoutGeneratedConfigurations'
```

默认桌面隔离仍创建真实窗口并截图，结束时关闭窗口、清理工作区和服务；不证明
WindowServer 合成、跨应用焦点、真实发行包完整工作流或 Windows 已通过验收。
本地逐项计时结果见忽略的 `.artifacts/test-stability/pr1517-review-macos.html`
和对应 JSON/JUnit：358 项测试、15 组套件通过。
