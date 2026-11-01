# Agent 笔记：Windows 原生面板函数借用工作区 Provider 会话

状态：已实现

## 先说结论

原生插件面板的函数调用现在借用工作区已经持有的 Provider 会话，即负责提供构建模型的后端进程。
一次函数结束或取消只释放自己的请求，后端状态持续到工作区关闭、插件失效或既有 Provider 清理路径完成。
这修复了“修改树节点后刷新又恢复原值”的生命周期错误。实现改动不代表生产准入：
`buildSystems`、`buildProviders` 和 `ui:3` 仍须按完整版本验收，不能用单个控件或受控对端测试开放。

## 问题

Windows 原生面板之前沿用一次性设置动作的调用路径，每次函数都新建并销毁进程。
参考 Mac UI Lab 的重命名、添加、反转等动作把当前节点保存在后端会话中；动作后紧接的数据刷新
如果启动另一个进程，就只能读到初始值。另建一份宿主节点模型会产生第二个数据真源，也无法推广到其他插件。

## 决策

原生面板登记仍绑定实际窗口、工作区代次、插件包完整身份及声明的构建实例。准备调用时复用 Provider
现有的只读程序审查，核对它与函数确认框展示的启动计划和已解析程序完全一致，取消确认会丢弃该审查。
同意后才确认或启动 Provider；函数结果、进度和注册表继续由 Rust Core 解释，宿主不增加私有协议解析器。

后端进程由 Provider 注册表持有。调用方只持有本次请求的等待器，取消通过已有请求 guard 撤回
精确的 operation ID，不停止其他面板、模型或构建请求。唯一事件读取者继续是 Provider 的事件泵；
它按会话和 operation ID 转发进度，插件停用、替换及工作区关闭仍经过原有租约和进程清理屏障。
共享语言服务器仍须由 Core 显式协商并登记函数，不能仅凭共享进程推断函数存在；
网页与设置动作的既有路径也未被本次扩大准入。

正确做法：`tree.rename` 和后续 `tree.nodes` 使用同一工作区 Provider，取消 rename 不取消另一条构建请求。
不要这样做：为了刷新节点重新启动后端，或者把后端私有节点状态复制到宿主的另一份长期模型。

受控完整包由 `native_workflow_fixture.py` 生成，复用固定 Mac UI Lab 的全部原生声明，提供独立协议对端、
构建/测试输入及设置动作。完整 requirements 和正常社区确认保留；它明确是 unsigned 验收输入，
不能冒充外部正式签名包或 SDK 验收。驱动复用既有 Windows Job 与 AppSession，源码/EXE 身份、
发行镜像、安装包和 ZIP 各自验证。真实 IME、原生焦点与尚未执行的完整版本行为保留独立 pending。

## 考虑过的备选方案

- 每次函数重新启动进程：会丢失插件会话状态，拒绝。
- 为原生面板再建一套长期后端表和事件读取器：会与构建 Provider 争抢事件并复制退出屏障，拒绝。
- 让宿主维护一份插件节点状态：违背数据由 Provider 提供的边界，不能保证其他函数语义，拒绝。

## 后果

同一工作区的原生动作与刷新保留后端状态，取消边界变小，继续复用成熟 Core 路由和原有进程所有者。
代价是函数结束后后端不立即退出，资源由工作区与插件生命周期收回；调用方必须保留失效检查，
不能把调用结束误当成后端停止证明。新增的 fixture、工作区、审查记录和报告都是单次验收状态，
没有可复用构建印记，不允许跨 worktree 共享；可写状态经平台存储 adapter 或受控工作区，
发行安装目录保持只读，不改变代码签名或更新源基线。

目录与函数登记必须比较同一种声明表示。实际产品曾把目录中的原始图标
`{"host":"refresh"}` 与设置快照中 Core 补全的 `mode: template` 比较，导致合法面板总被判为
上下文过期。目录现在从已复验的包字节取得 Core 归一化声明；包摘要、租约与登记前后身份检查
继续独立执行。不要通过忽略声明差异或跳过包完整性来消除这个错误。

按钮专用表单也没有可编辑控件。Core 会省略空的 `controls`，宿主须把缺省数组作为空集合来
核对空 `values`，不能因此拒绝合法面板；任何未声明字段仍拒绝。这个边界只用于已验证的原生声明，
不允许渲染器补写控件或选择调用目标。

一次性设置动作仍拥有独立进程，但必须等待 Core 确认关闭。`stopServer` 发起异步关闭后，
直接调用 `destroyServer` 会因会话仍在运行而失败，即使后端随后正常退出。现在由原有清理 worker
在八秒期限内读取该会话的终止事件，再请求销毁；如果另一条调用已取走终止事件，仍以 Core
成功销毁作为唯一清理凭据。超时、销毁失败和未知 worker 结果继续保留租约及原始 join handle，
不把“已发送退出”当成“已清理”，也不重复派发结果未知的销毁。

## 验证

- `node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs --manifest windows/tauri/src-tauri/Cargo.toml --report .artifacts/test-stability/native-provider.json`：检查会话注册/进度隔离、动作后刷新、函数取消与其他构建等待器共存。
- 同一 Rust 入口还覆盖设置动作的延迟关闭、其他会话终止事件隔离、关闭期限、事件已取走但销毁失败后的租约保留与重试。
- `python -B scripts/plugins/host-acceptance/native_workflow_acceptance_test.py --report .artifacts/test-stability/native-workflow-helpers.json`：离线检查固定输入、篡改拒绝、门控报告及真实受控对端状态；不是产品验收。
- `python -B scripts/plugins/host-acceptance/native_workflow_fixture.py --output .artifacts/plugin-host-acceptance/native-workflow-fixture-current` 生成本树输入；`native_workflow_acceptance.py --fixture-root .artifacts/plugin-host-acceptance/native-workflow-fixture-current --report .artifacts/test-stability/native-workflow-preflight.json --preflight` 只做预检。
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh` 与 `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh` 验证边界；完整原生运行还须提供源码绑定的隔离构建与独立 profile，由同一个驱动持有至清理完成。

## 适用范围

`windows/tauri/src-tauri/src/plugin_host/functions/native.rs`、
`windows/tauri/src-tauri/src/plugin_host/functions/runtime.rs`、
`windows/tauri/src-tauri/src/plugin_host/provider/`、
`scripts/plugins/host-acceptance/native_workflow_acceptance.py`。
不改变 Core 函数协议、Mac 参考产品、Java 专属接线、签名与正式分发要求。
