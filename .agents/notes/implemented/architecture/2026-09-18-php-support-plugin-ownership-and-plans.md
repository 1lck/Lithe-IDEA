# Agent 笔记：PHP 可选插件与进程资源归属

状态：已实现

## 先说结论

PHP 支持由用户选择安装和启用，主程序不携带 PHP 插件包、Node/Bun 或 Intelephense。Intelephense 是通过语言服务器协议（LSP）与编辑器通信的第三方 PHP 分析服务；PHP 解释器只负责运行程序和 PHPUnit 测试。插件禁用后必须停止自己启动的任务和进程，不能影响其他语言或删除用户自行安装的工具。

## 问题

只把 PHP 标记为默认禁用并不能实现按需分发：原有打包脚本会自动把所有官方原生插件放进应用。Windows 原来的 Composer 和 PHPUnit 动作还直接交给普通终端执行，禁用 PHP 扩展无法阻止入口发现或停止相关任务。工具安装只结束 Bun 的直接子进程，再无限等待输出线程，也无法保证取消完成。

## 决策

### 分发与安装

- `scripts/official-plugin-distribution.mjs` 显式列出随主程序分发的官方插件。PHP 不在其中；`build-official-plugins.sh --plugin-id dev.lithe.plugin.php-support` 仍能独立构建插件包，用户通过已有插件管理的 Install 入口安装签名与宿主一致的包。
- macOS 的 PHP 语言服务和执行模块均默认禁用、按需激活。安装后的包提供 `.php`、`.phtml` 和 `composer.json` 声明；没有包时不注册它的进程能力。共享的轻量语法识别不需要下载或启动外部进程。
- macOS 使用用户指定或 PATH 中的 Intelephense 和 PHP，设置页提供工具配置和官方下载入口。Lithe 不安装或删除这部分用户工具。
- Windows 的配置、Composer/PHPUnit 解析和入口位于 `Plugins/win/Official/PhpSupport`，通过独立 `.lithe-extension` 包分发。宿主不能静态或动态 import 这份实现；只有轻量的语言到包 ID 对应表保留在宿主。插件管理的“导入插件包”入口安装后默认禁用，用户再选择启用。
- Windows 显式安装 PHP 扩展时才下载解析器，并使用用户的 Bun 安装 Intelephense；同时检查 Node.js，因为安装包管理器与语言服务器运行时不是同一概念。缺失时给出安装引导，不后台下载运行时。
- Windows 启动时发现 PHP 工具缺失只报告状态，不自动重装。卸载删除插件自己的解析器和 `<app-cache>/language-tools/php`，不会删除 PATH、全局 npm/Bun 或项目 `vendor`。

### 能力与生命周期

- PHP 的 LSP 使用现有 Rust Core 会话，以 `intelephense --stdio` 启动。符号、类型和诊断仍由上游服务拥有；主机不实现第二套 PHP 语义分析。
- macOS 运行和测试使用插件模块持有的执行 session。相对文件名不做 trim，以 `-` 开头时加 `./`，避免把文件名当作命令选项。
- Windows 只有已安装且启用 PHP 扩展时才读取 Composer/PHPUnit 清单、展示运行入口；执行前再次检查开关。Composer 的字符串和字符串数组均交给 `composer run -- <name>` 执行，不在主机模拟脚本语义。
- Windows PHP 运行复用 Run 的输出面板和 native 进程启动能力，通用宿主服务在首个 await 之前按插件 ID 和工作区登记会话。禁用或关闭工作区时等待在途启动，再停止其拥有的 execution ID；自然结束释放所有权。不得通过普通终端事件绕过这个流程。
- 工具安装复用 `lithe-git-host::run` 已有的通用原生进程适配器：它不生成 Git 参数，已提供 Windows Job Object（将后代进程纳入同一个清理范围）、增量管道读取和有界回收。这里仅提供 Bun 命令、取消标记和安装期限，不复制一套 OS 清理实现。
- 禁用安装中的扩展先阻止新能力，再取消解析器下载及原生安装，等待安装流程结束后再次关闭注册入口，防止迟到的安装结果重新启用插件。

### Windows 独立包与宿主接口

复用已有 Worker 扩展宿主（在独立线程加载用户插件的执行环境），增加纯数据的运行计划接口。PHP Worker 接收声明的项目清单内容，只返回工具名与参数；宿主验证声明、等待保存并执行用户点击的动作。它不向 Worker 暴露原生进程句柄，也不把 PHP 实现编进前端。安装与恢复复用现有语言工具流程；原有扩展安装后端尚不可用，因此这个版本提供实际可用的本地包导入，不依赖未实现命令或虚构下载地址。

包由 manifest 和单个 ESM 入口组成，上限 256 KiB，写入 WebView 用户配置的单个 localStorage 项。这样安装状态与源码可以原子写入，并沿用宿主已有的插件状态持久化方式；大文件解析器仍由现有 IndexedDB 缓存保存。包格式仅接受语言、LSP 和运行计划声明，不授予网络、密钥等其他宿主权限。Worker 是执行隔离机制，不承诺将用户主动导入的任意代码变成安全代码；本地文件也不等于经过官方签名认证的下载。

禁用先关闭注册入口并终止 Worker 激活，再取消语言安装、等待启用任务结束、清理所有拥有的进程。读取清单或 Worker 请求结束后必须重新检查本次实例仍有效，防止旧结果污染新安装。卸载删除插件源码和安装记录，重启不会因旧解析器缓存复活插件。

### 正确与错误示例

正确：未安装 PHP 支持时打开含 `composer.json` 的项目，不读 PHP 专属运行清单；用户安装、启用后才解析脚本，点击运行生成插件拥有的进程。

错误：启动主程序即安装 Intelephense；发现 PHP 清单就无条件创建运行菜单；禁用时只隐藏菜单却留下语言服务、安装任务或运行进程。

## 考虑过的备选方案

1. 随应用打包 PHP、Node 和语言服务：开箱即用，但所有用户承担体积和维护成本，与可选支持要求冲突。
2. 只保留插件默认禁用：可以减少运行资源，却仍增加主程序体积，且解决不了 Windows 终端进程缺少插件所有权的问题。
3. 新建 PHP 专用 LSP 引擎或进程管理器：已有 Core LSP 和 native 进程适配器具备所需能力，新增实现会重复协议和清理边界。
4. 把 PHP 改成 Vite 动态 import：只能延迟执行，插件代码仍在应用分发物中，不满足独立安装要求。
5. 新建通用原生插件商店后端或引入完整 VS Code 宿主：本次只需要独立语言包与运行计划接口，已有 Worker 能完成执行边界；扩展这条已有路径的改动更小。
6. 使用 phpactor 作为透明候选：它的启动参数和运行依赖不同，当前统一参数契约不能安全互换；未来需要明确提供者选择与对应验证后再接入。

## 后果

不使用 PHP 的用户不承担语言服务器下载、索引和进程成本。代价是首次使用需要显式安装插件及本机工具；macOS 插件分发需要与宿主一致的签名。Windows 目前提供 Composer 脚本及整套 PHPUnit，未声明支持 macOS 已有的单方法测试发现。Windows 本地包暂不提供在线分发、自动更新或签名身份验证，替换版本需先卸载再导入；包格式仅用于小型 Worker 语言插件。目标平台运行验证未完成前，功能矩阵保持 pending。

插件构建产物、PHPUnit 的 vendor 和应用语言工具缓存没有可靠的跨工作树身份标记，均在 `scripts/worktree-resources.json` 的 excludedResources 中排除。不得把它们共享为可变缓存。

## 验证

- `bun scripts/build-windows-php-plugin.ts` 与 `node scripts/verify-windows-plugin-isolation.mjs`：构建独立 Worker 包并确认宿主没有 PHP 实现导入。
- Worker 协议测试实际加载 PHP 入口，检查启用、运行计划与停用；本地包测试检查默认禁用、坏包拒绝和源码删除。

- `node scripts/test-official-plugin-distribution.mjs`：默认分发名单不含 PHP，未知插件不会意外打入主程序。
- `./scripts/verify-macos-package.sh`：实际组装产物不得含 PHP 插件。
- `./scripts/verify-official-plugins.sh`：独立包兼容性与签名验证。
- `./scripts/test-macos.sh --filter LithePhpSupportModuleTests`：模块、路径与禁用清理测试。
- `LITHE_RUN_PHP_INTEGRATION=1 ./scripts/test-macos.sh --filter RealPhpIntegrationTests`：真实工具测试；先在 `shared/fixtures/phpunit-project` 执行 `composer install`，并配置 Intelephense 路径。
- Windows 前端测试包含禁用时不扫描、Composer 数组、下载取消、在途启动后禁用及跨工作区进程隔离。Windows native 测试与实际应用启动必须在 Windows 环境执行；Linux 交叉编译不等于运行验收。

## 适用范围

- `Plugins/mac/Official/PhpSupport/`
- `Plugins/win/Official/PhpSupport/`
- `scripts/build-official-plugins.sh`
- `scripts/package-app.sh`
- `windows/tauri/src/extensions/`
- `windows/tauri/src/features/run-actions/`
- `windows/tauri/src-tauri/src/language_tools.rs`
- `shared/contracts/application-boundary.md`
- `shared/platform-feature-matrix.json`
