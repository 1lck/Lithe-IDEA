# Agent 笔记：按内置文本高亮目录注册系统文件关联

状态：已实现

## 先说结论

“通用”设置中的文件关联表格直接显示系统当前的默认应用，并区分“已注册候选”和“已是默认”；用户勾选后点击一次应用，提交整批格式。可选格式来自编辑器实际打包的文本高亮扩展名及纯文本，不接受正则或“所有文件”。macOS 等待系统完成所选内容类型的默认应用请求，Windows 注册全部所选候选后进入系统设置确认；两端返回设置窗口都会自动回读，但不承诺系统只显示一次授权弹窗。

## 问题

操作系统按扩展名或内容类型注册文件处理程序，不能表达编辑器中的任意正则。单独维护一张扩展名表会与高亮支持和打包声明发生漂移；只保存一个“使用 Lithe 打开”的应用偏好，也无法说明系统真正使用哪个程序。系统打开文件时还必须保留用户已打开的项目，避免为了临时编辑一个文件而索引整个父目录。

最初实现（`c086a0b1b`，#2361）在 macOS 的同步设置接口返回成功后立即读取默认应用；尚未观察到新值时，宿主自行返回 `kLSApplicationNotFoundErr`（-10814），随后停止整批。用户日志中约 100 毫秒即结束的 -10814 与下一次提交的关联冲突交替出现，不能据此认定系统找不到 Lithe。关联修订还包含按应用标识启发式查出的路径，多份同标识应用可能造成无意义的基线变化。Windows 同样遇首个注册失败就停止，返回系统设置后也没有自动读取最终默认应用。

## 决策

- 编辑器只导出内置元数据，不加载语法，也不混入插件贡献。Core（共享 Rust 规则层）筛出实际有语法的语言和纯文本，排除编译/压缩容器、文件名匹配和复合后缀，排序去重。简单后缀与 Viva 原生打包清单的字符和长度限制一致，保留 `.c++`、`.h++`。设置和打包生成器使用同一个结果；增加高亮后须重新生成 `desktop/viva.toml`，打包前检查是否一致。
- 设置只在内存保存勾选草稿。读取来自系统真实默认处理程序，应用前重读默认标识与自有注册信息，再由 Core 拒绝过期基线。成功或部分失败后均重新读取，不把草稿当成生效值。取消勾选只清除本次选择，不还原历史默认应用；复杂后果通过标题的 ⓘ 说明。
- 同一格式可以同时注册多个候选应用，已有其他应用不构成注册冲突；访达或文件资源管理器双击使用的是当前默认应用。帮助文案明确说明用户选择会替换所选格式的原默认应用，以及生效后直接进入单文件模式；仅注册候选不能视为已满足双击编辑的目标。
- macOS 在构建期声明备用文本编辑器，运行期只向 Launch Services（系统维护的文件类型与应用关联服务）注册当前 bundle。所选后缀先解析为统一内容类型（UTType），相同类型只提交一次，已经是默认时跳过；普通类型失败后继续其他类型，并保留所有失败后缀。使用 `NSWorkspace.setDefaultApplication` 的异步完成回调等待系统确认，之后再核对实际默认应用；不在提交后立即合成“找不到应用”错误。查询也使用 `NSWorkspace` 的内容类型接口，注册修订只观察是否为候选，不把按应用标识猜出的安装路径当成版本。开发二进制只读默认应用，不注册临时测试程序。
- macOS 的主线程只提交原生异步请求，默认查询与包信息读取在后台进行。一次批量应用允许等待五分钟，读取允许三十秒；结束后的独立回读最多五秒，即使提交已超时，也尽量显示真实的部分结果。系统没有撤销已显示授权的接口，因此取消只阻止后续类型，迟到回调只访问自己持有的原生内存；同一进程最多保留一个未完成的系统确认，确认未结束时拒绝新请求，避免反复点击堆积弹窗。
- Windows 只写当前用户的 Classes、Capabilities 和 RegisteredApplications。每个格式使用与 Viva 安装器相同的 ProgID（系统中的文件处理程序标识），显式注册时同时写入自己的“用 Lithe 打开”动作；一个格式写入失败仍继续其余格式，并回报具体失败后缀。至少一个格式完整注册成功后，只打开一次系统默认应用页。只有已关联到该 ProgID 的文件有独立右键动作，其他文件可从“打开方式”进入；Windows 11 的传统动作可能在“显示更多选项”下。受保护的 UserChoice（用户默认应用选择）只读，最后由 Windows 设置确认。
- Windows 的右键动作放在 Lithe 自己的 ProgID 下，随 Viva 安装器卸载该格式一起移除，不在全局 `SystemFileAssociations` 或所有文件类写额外项。运行期仅允许名为 `lithe.exe` 的产品程序注册，避免测试二进制写入无法由卸载器移除的 Applications 项。
- Finder 事件只接受真实普通文件，复用独立编辑会话；已有项目保留，通过原有项目标签返回。Windows 从启动参数进入既有单文件模式。文档服务的隔离沿用[可选 CLI 注册与单文件编辑](2026-11-20-cli-and-standalone-editor.md)，不创建插件、目录索引或项目服务。
- 表格复用 Viva 的虚拟列表和共享滚动条，只创建可见行；勾选以扩展名保存，不依赖离屏控件是否存在。状态来自系统回读，不能把候选注册成功说成默认应用已生效；无打包身份时显示“需安装包”。窗口重新激活只读取系统，不写入、不清空草稿，也不覆盖上一次提交的失败反馈；激活发生在操作期间时，完成后补读一次。

正确做法：新增内置高亮后运行生成器，把格式同时带到设置、macOS 声明和 Windows 安装器；打开设置只查系统，勾选后点击应用才发布。不要在界面手写另一份格式名单，也不要通过改写安装包里的清单来补运行期关联。

## 考虑过的备选方案

- 正则输入和所有文本文件总开关：系统不理解正则，也无法仅凭文件内容在 Explorer/Finder 注册默认应用。最终采用真实内置高亮扩展名的全选操作，避免抢占二进制或压缩文件。
- macOS 添加固定 Finder 右键动作：需要额外的系统扩展和生命周期；系统已有“打开方式”可表达同一入口，本次使用它。
- Windows 直接写 UserChoice：绕过系统保护且不能可靠生效，保留系统确认流程。
- macOS 继续使用同步设置接口并立即检查：无法表达异步系统授权的完成时间，会把尚未观察到的结果误判为失败。等待原生异步回调再核对结果，代价是需要管理取消后仍可能完成的系统请求。
- 把所有类型一次提交给一个系统授权：公开接口每次接受一个内容类型，没有整组授权参数。宿主负责一次发起整批、按系统类型去重和继续处理普通失败，弹窗策略仍由系统决定，不使用私有接口强改。
- 全局右键项配扩展名过滤：Viva 当前卸载器不会清理额外全局项。把动作放进自有 ProgID 可以复用现有安装和卸载边界，代价是它只出现在已关联文件上。
- 所有平台各写一份筛选和冲突判断：行为会漂移，共享规则在 Core，平台只负责原生查询和写入。

## 后果

格式目录、高亮支持和安装声明可以相互核对，打开设置不改变系统，也没有虚假的“已注册”偏好。代价是仅文件名匹配的 Makefile 等不在系统关联列表中；设置默认应用需要安装后的程序，macOS 的类型别名和 Windows 的用户确认由系统决定。例如 `.java/.jav` 共用同一内容类型，一次设置会联动，不能承诺每个后缀独立生效。平台外部进程在重读与写入之间仍可竞争，原生接口不提供跨进程事务，批量部分失败会显示错误并回读；超时后用户仍可能完成已经打开的系统确认。

清单是构建输入，由仓库维护，不是缓存。运行期注册数据由系统管理，macOS bundle 和 Windows 安装目录始终只读，不产生新下载或资源路径，不改变代码签名和增量更新基线。截图和计时报告只属于当前检出的 `.artifacts/`，不跨工作树复制。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/core ./internal/fileassociations ./internal/workbench -run '^Test(FileAssociations|SystemDocuments)' -count=1 -timeout=60s`：链接固定的 Core，核对共享 fixture、真实高亮解析、Viva 原生清单，以及真实文件的独立打开与项目保留。
- `scripts/desktop/desktop-go.sh test -tags vivahead ./internal/workbench -run '^Test(SystemDocumentsPreserveProjectAndReuseIsolatedSession|StandaloneEditsWithBundledSyntaxWithoutProjectServices)$' -count=1 -timeout=60s`：定向通过系统文件入口复用独立会话、保留原项目、不启动项目服务，以及真实临时文件的编辑和保存；不替代 Finder 的原生事件投递验收。
- `scripts/desktop/desktop-go.sh test -race -tags 'vivahead lithevisual' ./internal/fileassociations ./internal/core ./internal/settingswindow -run '^Test(FileAssociations|VisualFileAssociations$)' -count=1 -timeout=60s`：使用 `LITHE_VISUAL_OUTPUT_DIR` 输出中英、明暗的表格和默认应用替换说明截图；验证真实系统类型别名、只读观察、预取消不注册、取消不吞掉真实失败，以及全选、清空、刷新、滚动到末尾、虚拟化、返回窗口自动回读和勾选保留。逐项计时由 `run-go-tests-with-timing.mjs` 生成 HTML 与 JUnit 报告。
- `scripts/desktop/generate-file-associations.sh --check`、`node --test --test-timeout=60000 scripts/desktop/package-desktop.test.mjs`：核对打包目录和生成器在构建主机执行、最终辅助程序保持目标架构。
- `scripts/desktop/desktop-go.sh build -o ../.artifacts/desktop/bin/lithe-file-associations ./cmd/lithe`：检查 macOS arm64 最终消费者；Core 使用桌面构建脚本固定的修订，本次批量提交修复不改变共享契约。
- `scripts/desktop/perf/editor-bench.sh run --bench '^BenchmarkEditorSyntaxViewportWarm' --count 6`：同机改动前后各测六次，六个场景均在预算内，保持 0 B/op、0 allocs/op；对比没有回归。元数据导出不改变分词或视口读取路径。
- Core 的 `cargo clippy --manifest-path rust/Cargo.toml -p lithe-core --all-targets --target x86_64-pc-windows-msvc -- -D warnings`（设置 `LIBSQLITE3_SYS_USE_PKG_CONFIG=1`）通过。它不验证 Windows 的 Go 原生适配器，也不替代来宾运行。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：检查发行目录只读边界。
- 自动回读回归已通过临时移除 `OnActivate` 验证修复前失败、恢复后通过。macOS 即时校验与首错停止的修复依据是用户日志和原生代码，尚未通过签名发布包重放写入与授权，不能把只读测试当成完整回归证据。
- 使用生产原生桥接的临时探针，对 `.java` 已生效的同一默认应用重复提交一次：新旧查询先确认当前为 Lithe，异步完成回调无错误，未完成标记归零，默认应用 URL 与旧接口结果前后相同。该探针不注册新应用，只证明一次幂等请求的回调和内存生命周期可完成，不覆盖批量改变默认值或授权弹窗。
- 发布包验收：macOS 选择多个不同类型及一组别名，核对实际写入、系统确认次数、拒绝某项后继续其余项，以及超时后结束弹窗再返回回读；从 Finder 打开文件验证独立会话。Windows 核对整批注册、系统确认后返回自动回读、部分失败提示及卸载清理。本机没有 Windows 来宾，Windows Go 原生编译和上述流程未验证；两端功能矩阵保持 pending。无头测试不修改开发机默认应用。

## 适用范围

- `desktop/internal/fileassociations/`
- `desktop/internal/core/file_associations.go`
- `desktop/internal/editor/syntax/catalog.go`
- `desktop/internal/settingswindow/file_associations_view.go`
- `desktop/internal/workbench/system_document.go`
- `desktop/cmd/file-associations-manifest/`
- `desktop/viva.toml`
- `shared/platform-feature-matrix/features/system-file-associations.json`
