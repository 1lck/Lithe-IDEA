# Agent 笔记：macOS 测试窗口的桌面隔离

状态：已实现

## 先说结论

日常 macOS 界面测试继续创建真实窗口、处理原生事件和验证弹窗，但默认将测试
进程内的窗口设为完全透明，并阻止该进程主动激活应用。测试无需暂停，也不减少
已有用例。需要验证桌面合成效果、真实激活或人工观察时，显式使用可见模式。

## 问题

原生界面测试中的 `orderFront`、`makeKeyAndOrderFront` 和产品弹窗会把临时窗口
放到使用者桌面上。批量运行时，空白宿主、Agent 活动卡片、设置和比较窗口反复
出现，影响开发者使用其他应用。直接隐藏应用会改变窗口可见性、焦点与弹窗生命周期。

## 决策

隔离实现只属于 `macos/Tests/LitheTestDesktopIsolation/`，由测试目标依赖加载，
不能加入产品依赖。它在测试进程启动时替换几个公开的 AppKit（macOS 原生界面框架）
方法，将窗口透明度设置和排序之前的桌面透明度固定为零，保留原生排序、位置、
响应链与关闭动作。窗口仍然具有真实的 `isVisible` 状态，原生视图截图仍由原有
绘制路径生成；`NSApplication` 的主动激活动作被拦截，避免切换使用者前台应用。

`LITHE_TEST_WINDOW_MODE` 只接受 `isolated` 和 `visible`。默认隔离；可见模式
不安装方法替换，保留 AppKit 原始行为。现有 `LITHE_RUN_GIT_COMPOSITOR_TESTS=1`
明确要求 WindowServer（负责把窗口合成为桌面图像的系统服务）采样，因此选择
可见模式；强制隔离与真实合成采样同时开启时立即报错，不生成误导性性能结果。

窗口的 `alphaValue` 返回实际透明度零；产品请求的透明度另行记录在窗口本身，
通过 `LitheTestRequestedWindowAlpha` 验证。例如拖拽预览必须请求 0.9，即使隔离层
最终将桌面透明度覆盖为零，也不能把这项产品断言改成零或删除。可见模式时该函数
直接返回窗口的真实透明度。记录跟随窗口释放，没有定时器或后台任务。

正确做法是继续使用现有原生测试，并仅在透明度断言处区分产品请求和测试显示。
不要把窗口移出屏幕、伪造 `isVisible`、替换弹窗模型、跳过界面测试，或把隔离分支
加入产品代码；这些做法会改变被测行为或让发行程序携带测试策略。

原生视图截图的颜色断言必须在同一色彩空间比较。测试内已有的 `nativeSRGBCapture`
和 `nativeSRGBPixel` 用于固定 sRGB（标准 RGB 色彩空间）的截图与取色；直接使用
显示器 ICC（描述显示器颜色转换的配置）位图时，把预期颜色转换到 `bitmap.colorSpace`
再比较原始分量。直接混用空间会在可见和隔离模式中产生相同的误报。保留源颜色、
误差阈值与像素数量要求，不用放宽断言掩盖差异。

## 考虑过的备选方案

- 隐藏应用或强制禁止窗口：会改变可见性、激活和原生弹窗行为。
- 把窗口移到屏幕外：会改变屏幕边缘约束与弹窗位置，无法保留几何测试。
- 设置窗口到桌面底层：会改变被测层级，并且桌面空闲时仍可能显示窗口。
- 独立 macOS 登录会话或虚拟机：可完全保留真实桌面行为，但需要独立系统环境。
  如果测试依赖真实物理输入、应用激活、屏幕截图或桌面帧率，应在这样的环境中
  运行可见模式，不能把默认隔离模式视作这些行为的验收。

## 后果

普通界面测试保留原来的用例与事件流程，桌面不再看到测试进程的窗口。代价是
默认模式验证原生视图绘制与交互，不证明实际桌面合成、跨应用焦点或硬件输入。
新增透明度断言需读取产品请求值；窗口透明度与启动拦截本身由独立回归测试检查。
测试启动的独立产品进程不加载此测试模块，真实产品端到端测试仍需隔离系统环境。
可见模式的窗口和测试子进程仍由原测试的清理路径关闭。

## 验证

- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`。
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'DesktopIsolationTests|AgentActivityPresentationTests|ContextMenuCoverageTests|SettingsSelectPopupGeometryTests|SettingsAppearanceContainerTests|EditorTabOrderFeatureModelTests|DiffScrollSynchronizationTests'`。
- `LITHE_TEST_WINDOW_MODE=visible ./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter DesktopIsolationTests`。
- `./scripts/verify-runtime-bundle-immutability.sh` 和 `./scripts/verify-agent-notes.sh`。

隔离回归测试检查真实 WindowServer 透明度、原生视图绘制、鼠标事件传递、关闭，
以及隔离进程不能替换前台应用。现有 Agent 卡片、弹窗、比较视图与拖拽测试用于
检查方法替换是否影响原有流程。测试报告的实际结果决定验收状态，不能仅凭存在
隔离代码宣称完整界面套件通过。

2026-10-13 以最新 `preview` 为基线验证：完整套件的 2,047 项中，2,032 项通过、
15 项按原配置跳过，没有新增跳过、断言失败或计时预算失败。新隔离回归测试中最慢的
真实窗口与原生截图测试为 102 毫秒。产品二进制中没有测试隔离模块的符号；非法模式
和强制隔离与真实合成采样的冲突均在构建前以退出码 2 拒绝。
可见模式下的 8 项窗口、比较视图和弹窗对照全部通过，未改变测试原有断言要求。

## 适用范围

`Package.swift`、`scripts/test-macos.sh`、`macos/Tests/LitheTestDesktopIsolation/`、
`macos/Tests/LitheTestDesktopIsolationTests/` 和 `macos/Tests/LitheTests/`。
