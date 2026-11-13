# Agent 笔记：Java 项目导入超时设置

状态：已实现

## 先说结论

稳定版的大型 Java 工程可能在仍有导入进度时触及 10 分钟总时限。Windows 提供应用级的 1–120 分钟设置；默认保持 10 分钟，用户可以保存 60 分钟后重启 Java 服务。Core 同时为设置页和启动流程解析同一份偏好，避免显示值和实际时限不同。

## 问题

大型多模块工程在依赖解析仍有进度时可能触及固定截止时间；用户无法通过设置继续等待。

## 决策

分钟数保存在现有 Windows 应用设置中，不写 Maven 或 JDT LS 配置，也不写发行目录。页面打开只读取，编辑先保留草稿，点击保存才更新偏好；离开未保存页面不写入。恢复默认移除覆盖，下次启动重新使用 Core 默认值。运行中的导入不改变截止时间，以免保存偏好意外中断任务。

Core 负责默认值、范围校验和毫秒转换。比如保存 60 后，启动参数是 3600000 毫秒。错误做法是只延长前端等待，仍让 Core 在 10 分钟终止进程。初始化、普通请求和构建超时保持各自原来的语义。

## 考虑过的备选方案

未采用全局硬编码 60 分钟，因为它会延长所有用户对异常导入的等待。未采用无限等待，因为稳定版仍需有明确的失败边界。此补丁针对 0.6.7 稳定版；preview 已迁移插件架构，不能直接套用。macOS 本次没有新增设置入口，其行为不变。

## 后果

大项目可以延长导入等待，所有用户仍保留有限时限。新增一次启动前的轻量策略查询；空闲时不增加轮询，也不增加常驻进程。

## 验证

Core 单元测试和共享 fixture 覆盖缺省、60 分钟、边界、非整数和越界；Windows 适配器测试断言真实启动消息包含 3600000，且初始化和构建时限不变。完整手动流程按 `shared/platform-feature-matrix/features/java-import-timeout.json` 验证，未完成运行时验收前保持 pending。

## 适用范围

涉及 `rust/lithe-core/src/lsp/interface/readiness_timeout.rs`、`windows/tauri/src/platform/lsp-core-adapter.ts` 和 `windows/tauri/src/features/settings/components/java-import-timeout-settings.tsx`。
