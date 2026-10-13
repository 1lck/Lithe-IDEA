# Agent 笔记：Windows Spring 接口列表的索引与刷新边界

状态：已实现

## 先说结论

Windows 的 Spring Endpoints 列表展示已有 `spring.index` 返回的 HTTP 接口，
支持筛选并跳转到控制器源码。索引结果属于发起请求的项目；切换项目或关闭窗口后，
旧任务不能读取新项目的编辑器内容或覆盖新列表。刷新失败时保留同一项目上一次的
成功结果，并明确提示它可能已经过期。

## 问题

原有 Windows Spring 适配层只保留配置和 Bean 信息，没有把 Core 已返回的接口
集合交给工作台。增加列表后，用户还需要区分“未找到接口”“正在扫描”和“扫描失败”，
并能在控制器文件或整个源码目录被重命名后打开正确位置。

项目列表、编辑器内容和索引都按工作区存储。异步任务恢复执行时再读取全局活动
项目，会读到切换后的状态。文件监听又可能只报告目录的旧路径和新路径，按 `.java`
后缀决定刷新会漏掉整个包的移动或删除。

## 决策

- 复用 Core 的 `spring.index` 和已有跨平台返回值，Windows 只负责状态、筛选、
  列表展示与源码跳转。保留 Core 给出的稳定顺序和一基行列号，沿现有导航边界转换。
  不在 React 中重新解析 Spring 注解，也不把此次接入扩展为另一套语言服务。
- 索引请求开始时固定工作区 ID 和对应的文件、编辑器、Spring 存储。文件扫描和
  元数据查找完成后分别检查任务是否仍有效；旧结果不能更新其他项目，也不能重新
  创建已经关闭的工作区。工作区 ID 本身也是重新绑定的依据，不能只比较根目录字符串。
- 状态使用 `idle/loading/ready/failed`。同根目录刷新保留成功结果，失败标记过期；
  切换根目录立即清空旧结果。存储的请求序号拒绝同项目中较早完成的过期请求。
- 当前根目录下的创建、删除与全量重扫都触发去抖刷新；重命名由创建、删除两个事件
  覆盖。现有事件不区分文件与目录，所以结构变更保守刷新；普通内容更新只响应 Spring
  相关文件，其他项目的事件不进入本项目索引。计时器与监听器由挂载的控制器统一清理。
- 大列表复用 TanStack Virtual 和现有 ScrollArea。普通列表与虚拟列表使用相同行高；
  HTTP 方法集合、路由、控制器和路径在窄面板中截断，完整值由行提示保留。
- 索引失败提示使用固定分类和翻译，日志只记录分类；源码跳转失败仅记录操作名，
  不把宿主异常里的完整路径直接输出。

正确做法是“项目 A 开始扫描 → 用户切到 B → A 的后续请求被丢弃，B 独立更新”。
不要在 A 的异步回调中调用全局活动存储的 `getState()`，也不要把文件夹重命名当作
无关的非 Java 文件变化。

## 考虑过的备选方案

- **在前端另写注解解析器。** 已有 Core 操作提供两端一致的接口集合，重复解析会
  产生不同的路由和位置，因此继续复用现有能力。
- **每次刷新先清空列表。** 会在编辑源码时不断闪空，也无法区分刷新失败和零结果，
  因此只在根目录改变时清空。
- **结构事件只检查文件后缀。** 无法识别目录中包含的控制器，已删除目录也不能再靠
  文件查询补回类型，因此采用带去抖的保守刷新。

## 后果

接口搜索、源码定位和失败状态都有自动化测试，且不会因为项目切换混用存储。
代价是无关文件的结构变更也可能触发一次刷新；去抖合并连续事件，普通文件内容更新
仍按类型过滤。

本次范围为 Windows 本地盘符和 UNC 主工作区。WSL、远程和附加工作区根目录的接口
浏览不在此次能力内。Core 现有 Java 源码索引的语义限制仍然存在；自定义组合注解、
继承映射、计算得到的路径常量、Kotlin 和生成源码需要另行完善其所属的索引能力。

## 验证

- `cd windows/tauri && bun test src/features/spring src/features/keymaps/commands/view-command-actions.test.ts src/features/file-system/services/file-watcher-listener.test.ts`
- `cd windows/tauri && bun run typecheck`
- `node .agents/skills/write-stable-tests/scripts/verify-test-stability.mjs --platform windows`
- `./scripts/verify-windows-boundaries.sh`
- `./scripts/verify-shared-contracts.sh`
- `./scripts/verify-platform-feature-matrix.sh`
- `./scripts/verify-agent-notes.sh`
- Windows 实机验证：打开 Spring 项目，用命令面板进入接口列表，筛选并点击接口；
  重命名源码目录后再次跳转；扫描中切换项目；检查失败提示和超过 200 个接口时的滚动。

## 适用范围

- `windows/tauri/src/features/spring/`
- `windows/tauri/src/features/file-system/services/file-watcher-listener.ts`
- `windows/tauri/src/features/layout/components/bottom-pane/bottom-pane.tsx`
- `shared/contracts/rust-core-api.md`
