# Java Support 安装引导的界面验证

这些截图对应 #1483 的 review 补验，由真实 SwiftUI/AppKit 视图生成。
通知使用现有通知模型和展开操作；新建项目页使用真实 Core 生成器目录、空插件
清单和隔离偏好。市场动作由测试记录，不会联网、安装插件、创建项目或执行工具。

| 场景 | 浅色 | 深色 |
| --- | --- | --- |
| Java 缺包通知，展开全文 | [截图](java-missing-notification-light.png) | [截图](java-missing-notification-dark.png) |
| 新建项目页的 Java/Maven/Spring 模板安装入口 | [截图](java-new-project-light.png) | [截图](java-new-project-dark.png) |

本轮修复改变缺包判断，没有调整布局。卸载后的 `.removed` 快照在重启后允许
显示通知；仍有待重启变更的副本、已安装但禁用的副本继续使用原管理流程。
回归另外通过真实包存储执行安装、卸载、启动准备和重新扫描，核对移除快照下的
Java 文件与 Maven 项目提示，不把单独渲染通知当作完整卸载流程的证明。

复验入口：

```bash
LITHE_JAVA_GUIDANCE_CAPTURE_DIR="$PWD/.artifacts/test-stability/java-installation-guidance" \
  ./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh \
  -- --filter 'PluginBundledPublisherTrustTests|PluginInstallationGuidancePresentationTests'
```

测试使用默认桌面隔离模式，仍创建并关闭真实窗口。截图证明原生视图的绘制和
按钮动作，不证明桌面合成、真实市场下载、正式双架构发行或 Windows 独立分发。

本轮计时报告 `pr1483-review-macos` 共 75 项测试、5 组套件通过；完整冷编译与测试
分别执行，最终测试仍使用原有计时上限和默认桌面隔离。
