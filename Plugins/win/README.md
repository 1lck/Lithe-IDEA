# Windows plugins

This directory owns Windows plugin packages. Keep Windows manifests, native or
frontend implementation, platform resources, and focused tests here rather
than under the macOS plugin tree.

## PHP Support 独立包

在仓库根目录运行 `bun scripts/build-windows-php-plugin.ts`，得到
`.artifacts/windows-plugins/lithe.php-1.0.0.lithe-extension`。Windows CI 的
`windows-php-plugin` artifact 也提供同一格式的包。应用构建不包含这份实现。

在扩展管理中点击“导入插件包”，选择可信来源的文件。准备好本机 Bun 与 Node.js；
导入会安装解析器和 Intelephense，成功后保持禁用，点击启用后加载插件。
运行项目还需要本机 PHP、Composer，PHPUnit 使用项目自己的 `vendor/bin/phpunit`。
插件不下载 PHP、Bun 或 Node.js。

禁用会关闭 Worker、语言服务及该插件拥有的运行会话；卸载还删除插件源码、解析器
和托管工具缓存。用户全局工具及项目文件不受影响。替换包需先卸载再导入。
本地包没有签名身份验证，也没有自动更新；仅应导入可信来源的文件。

插件只能通过 `Plugins/win/SDK/run-actions.ts` 的数据契约贡献运行计划，不得导入
宿主 React store、Tauri API 或 Run 服务。宿主在用户点击后保存、验证并执行计划。
