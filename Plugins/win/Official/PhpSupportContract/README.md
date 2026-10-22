# PhpSupportContract

契约 v1 形态的 PHP 支持包（bundled 技术验收样本）。它验证 Windows 声明式插件宿主的
validate → launch plan → run plan 全链路在真实包上可用。

与 Worker 版 PhpSupport（`Plugins/win/Official/PhpSupport`）的关系：两包并存，
Worker 版优先（语言注册与 composer scripts 动态运行动作仍由它提供）。契约 v1 尚无
动态运行动作的等价能力，删除 Worker 版会造成功能退化，完整迁移推迟到契约补齐该能力，
原因记录在 Windows 声明式插件宿主 Note。

`language-server/bin/intelephense.js` 是占位入口；真实分发打包 Intelephense 时替换。
