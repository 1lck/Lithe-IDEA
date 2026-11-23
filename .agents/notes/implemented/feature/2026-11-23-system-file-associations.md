# Agent 笔记：按内置文本高亮目录注册系统文件关联

状态：已实现

## 先说结论

“通用”设置中的文件关联表格直接显示系统当前的默认应用，用户勾选后明确应用才改变关联。可选格式来自编辑器实际打包的文本高亮扩展名及纯文本，不接受正则或“所有文件”。macOS 使用 Finder 的“打开方式”和默认应用；Windows 注册“打开方式”候选并交给系统设置确认默认应用。

## 问题

操作系统按扩展名或内容类型注册文件处理程序，不能表达编辑器中的任意正则。单独维护一张扩展名表会与高亮支持和打包声明发生漂移；只保存一个“使用 Lithe 打开”的应用偏好，也无法说明系统真正使用哪个程序。系统打开文件时还必须保留用户已打开的项目，避免为了临时编辑一个文件而索引整个父目录。

## 决策

- 编辑器只导出内置元数据，不加载语法，也不混入插件贡献。Core（共享 Rust 规则层）筛出实际有语法的语言和纯文本，排除编译/压缩容器、文件名匹配和复合后缀，排序去重。简单后缀与 Viva 原生打包清单的字符和长度限制一致，保留 `.c++`、`.h++`。设置和打包生成器使用同一个结果；增加高亮后须重新生成 `desktop/viva.toml`，打包前检查是否一致。
- 设置只在内存保存勾选草稿。读取来自系统真实默认处理程序，应用前重读默认标识与自有注册信息，再由 Core 拒绝过期基线。成功或部分失败后均重新读取，不把草稿当成生效值。取消勾选只清除本次选择，不还原历史默认应用；复杂后果通过标题的 ⓘ 说明。
- macOS 在构建期声明备用文本编辑器，运行期只向 Launch Services（系统维护的文件类型与应用关联服务）注册当前 bundle，并显式设置所选类型。macOS 按内容类型关联，共用一种内容类型的多个扩展名可能同时变化，不能承诺每个后缀独立生效。开发二进制只读默认应用，不注册临时测试程序。
- Windows 只写当前用户的 Classes、Capabilities 和 RegisteredApplications。每个格式使用与 Viva 安装器相同的 ProgID（系统中的文件处理程序标识），显式注册时同时写入自己的“用 Lithe 打开”动作；只有已关联到该 ProgID 的文件有该独立动作，其他文件可从“打开方式”进入。Windows 11 的传统动作可能在“显示更多选项”下。受保护的 UserChoice（用户默认应用选择）只读，最后由 Windows 设置确认；刷新后回显系统结果。
- Windows 的右键动作放在 Lithe 自己的 ProgID 下，随 Viva 安装器卸载该格式一起移除，不在全局 `SystemFileAssociations` 或所有文件类写额外项。运行期仅允许名为 `lithe.exe` 的产品程序注册，避免测试二进制写入无法由卸载器移除的 Applications 项。
- Finder 事件只接受真实普通文件，复用独立编辑会话；已有项目保留，通过原有项目标签返回。Windows 从启动参数进入既有单文件模式。文档服务的隔离沿用[可选 CLI 注册与单文件编辑](2026-11-20-cli-and-standalone-editor.md)，不创建插件、目录索引或项目服务。
- 表格复用 Viva 的虚拟列表和共享滚动条，只创建可见行；勾选以扩展名保存，不依赖离屏控件是否存在。系统查询和写入在可取消、有期限的后台任务中完成。

正确做法：新增内置高亮后运行生成器，把格式同时带到设置、macOS 声明和 Windows 安装器；打开设置只查系统，勾选后点击应用才发布。不要在界面手写另一份格式名单，也不要通过改写安装包里的清单来补运行期关联。

## 考虑过的备选方案

- 正则输入和所有文本文件总开关：系统不理解正则，也无法仅凭文件内容在 Explorer/Finder 注册默认应用。最终采用真实内置高亮扩展名的全选操作，避免抢占二进制或压缩文件。
- macOS 添加固定 Finder 右键动作：需要额外的系统扩展和生命周期；系统已有“打开方式”可表达同一入口，本次使用它。
- Windows 直接写 UserChoice：绕过系统保护且不能可靠生效，保留系统确认流程。
- 全局右键项配扩展名过滤：Viva 当前卸载器不会清理额外全局项。把动作放进自有 ProgID 可以复用现有安装和卸载边界，代价是它只出现在已关联文件上。
- 所有平台各写一份筛选和冲突判断：行为会漂移，共享规则在 Core，平台只负责原生查询和写入。

## 后果

格式目录、高亮支持和安装声明可以相互核对，打开设置不改变系统，也没有虚假的“已注册”偏好。代价是仅文件名匹配的 Makefile 等不在系统关联列表中；设置默认应用需要安装后的程序，macOS 的类型别名和 Windows 的用户确认由系统决定。平台外部进程在重读与写入之间仍可竞争，原生接口不提供跨进程事务，批量部分失败会显示错误并回读。

清单是构建输入，由仓库维护，不是缓存。运行期注册数据由系统管理，macOS bundle 和 Windows 安装目录始终只读，不产生新下载或资源路径，不改变代码签名和增量更新基线。截图和计时报告只属于当前检出的 `.artifacts/`，不跨工作树复制。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/core ./internal/fileassociations ./internal/workbench -run '^Test(FileAssociations|SystemDocuments)' -count=1 -timeout=60s`：链接修改后的 Core，核对共享 fixture、真实高亮解析、Viva 原生清单，以及真实文件的独立打开与项目保留。
- `scripts/desktop/desktop-go.sh test -tags 'vivahead lithevisual' ./internal/settingswindow -run '^TestVisualFileAssociations$' -count=1 -timeout=60s`：使用 `LITHE_VISUAL_OUTPUT_DIR` 输出中英、明暗截图；系统默认应用只读，验证全选、清空、刷新、鼠标滚轮到末尾、虚拟化和选择保留。
- `scripts/desktop/generate-file-associations.sh --check`、`node --test --test-timeout=60000 scripts/desktop/package-desktop.test.mjs`：核对打包目录和生成器在构建主机执行、最终辅助程序保持目标架构。
- `scripts/desktop/desktop-go.sh build -o ../.artifacts/desktop/bin/lithe-file-associations ./cmd/lithe`：macOS arm64 最终消费者构建通过。开发联调通过 `LITHE_CORE_RUST_DIR` 指向同功能 Core 分支；发布前必须先合入 Core，再更新宿主固定修订，不能把本地联调误算成固定版本已具备新命令。
- `scripts/desktop/perf/editor-bench.sh run --bench '^BenchmarkEditorSyntaxViewportWarm' --count 6`：同机改动前后各测六次，六个场景均在预算内，保持 0 B/op、0 allocs/op；对比没有回归。元数据导出不改变分词或视口读取路径。
- Core 的 `cargo clippy --manifest-path rust/Cargo.toml -p lithe-core --all-targets --target x86_64-pc-windows-msvc -- -D warnings`（设置 `LIBSQLITE3_SYS_USE_PKG_CONFIG=1`）通过。它不验证 Windows 的 Go 原生适配器，也不替代来宾运行。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：检查发行目录只读边界。
- 发布包的 macOS 注册和 Finder 打开、Windows 注册表与默认应用确认、卸载清理需要在目标系统单独验收，功能矩阵保持 pending。无头测试不修改开发机默认应用。

## 适用范围

- `desktop/internal/fileassociations/`
- `desktop/internal/core/file_associations.go`
- `desktop/internal/editor/syntax/catalog.go`
- `desktop/internal/settingswindow/file_associations_view.go`
- `desktop/internal/workbench/system_document.go`
- `desktop/cmd/file-associations-manifest/`
- `desktop/viva.toml`
- `shared/platform-feature-matrix/features/system-file-associations.json`
