# Test 面板截图

- [修改前的控制台](before-dark-console.png)：用户在本轮界面调整早期提供的原始截图，作为共享控制台样式的视觉基线；不是对审核 head 的重建截图。
- [修改后：深色、右侧收起](after-dark-collapsed.png)：真实 Maven 单测试通过，保留结果状态、绿色状态条和共享 INFO 高亮。
- [修改后：浅色、右侧展开](after-light-expanded.png)：相同真实测试结果，展开 Performance，核对禁用动作、标题、分隔线和控制台。

截图仅证明对应的可见状态。Gradle 已有 daemon 的进程归属和 JFR 错误生命周期分别由显式真实集成测试、受控异步回归覆盖；这三张截图不作为这些异步路径的证明。

新建 Gradle 演示项目在完整应用导入后出现“无可用测试提供方”，因此完整 Gradle 产品入口仍待验收；执行适配层的 Gradle worker 归属真实集成已经通过，不将两层证据混为一谈。

左侧结果树补充验收：[深色](tree-dark.png)、[浅色](tree-light.png)。演示数据含通过、断言失败、执行错误和跳过；核对13pt常规文字、16pt原始状态/箭头SVG、共享边距和选中样式，并操作分组折叠/展开。

摘要样式补充：[深色](summary-dark.png)、[浅色](summary-light.png)。真实混合测试结果显示“2 tests failed, 3 passed, 1 ignored”及灰色总数；原生双击类名验证折叠/再次展开，叶子双击保持结果、没有启动新测试。

## 测试发现列表

- `discovery-dark.png`、`discovery-light.png`：本次重建应用中的真实未运行列表，显示工作区分组、共享Java文件、类与方法原始图标。已检查运行后通过/错误/失败/跳过状态、关闭运行后回到发现树，以及主题恢复为深色。
- `LanguageTestPresentationTests` 6项通过，覆盖明暗原始资源尺寸、发现分组与方法图标、结果状态优先和共享文件类型分类。
