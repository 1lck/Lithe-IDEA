# Agent 笔记：共享翻译来源与构建时生成

状态：已实现

## 先说结论

桌面端的全部自有翻译资源在 `shared/i18n/` 维护，由 `scripts/i18n/generate-i18n.mjs` 生成 Viva 的 Go 字典 `desktop/internal/i18n/shared.generated.go`，页面通过 `i18n.Shared` / `i18n.SharedFormat` 读取。开发者修改一次翻译即可更新生成结果。页面内的中英文文案已完整迁入共享来源；上游消息、用户数据和搜索同义词仍由各自所有者维护，不增加在线语言包。

## 问题

各平台原来各自维护中英文，参数写法也不同（`%@`、`%lld`、`{name}`）。直接合并会丢失语境与参数类型，也会把合理的平台差异（例如文件管理器的名称）抹掉。语言选项与语言清单原本也是写死的两项。

## 决策

共享语言清单声明语言标识、自称名称和回退语言。生成器原先还为旧 macOS（Swift）和 Windows（Tauri）客户端输出语言枚举、类型和原生字符串表；两个客户端在 #1799 删除后，这些生成路径和它们的格式样例一并删掉，生成器只输出 Go 字典，并在构建时展开回退。桌面端的语言枚举、保存值（`en` / `zh-Hans`）和系统语言检测写在 `desktop/internal/i18n/i18n.go`，不由清单驱动，所以新增语言要同时修改这里。清单和词条中只服务旧客户端的字段（`macos`、`swiftCase`、`platformDefaults`、`macos.key`、`windows.key` 等）仍被校验但不再生成任何文件；其中 `macos` 的值正是桌面端的保存值，清理前要先迁走这层对应关系，见 [#1807](https://github.com/1lck/Lithe-IDEA/issues/1807)。

词条使用描述用途的语义 key。相同英文并不自动表示相同语义，平台适用范围也不代表功能已经实现；能力对齐继续由功能矩阵记录。平台覆盖（override，即单个平台需要不同措辞）必须说明原因。

正确做法：修改 `locales/zh-CN.json` 的 `ui.save`，重新生成，提交源文件和生成结果。当两个用途需要不同翻译时建立两个语义 key，不能让同一旧别名归属于两个 key。不要这样做：在生成区域或旧字典里再写一个 Save；校验会拒绝双重维护。

参数必须声明为字符串或整数。Viva 按 `{name}` 一次替换，传入值中的占位符不会被再次解释。原生字符串表要求的类型宽度、位置格式和百分号转义随旧客户端一起不再生成，对应的 `macos.arguments`、`macos.formats` 和 `nativeFormat` 仍被校验，清理同见 #1807。当前不支持复杂复数、任意 printf 指令或 ICU 模板；不在缺少实际需求时自建这些能力。

语言文件的覆盖率统计全部共享词条。完整语言缺词会失败；明确允许回退的语言可缺词，但回退链必须到达完整默认语言。生成器还拒绝重复 key、未知字段、非法平台、参数不匹配、双重定义和过期产物。检查模式只读；所有输入及生成计划验证完成后才写文件。生成文件通过 `.gitattributes` 固定为 LF 换行，避免 Windows 上换行转换导致产物误报过期。

资源生命周期由 Git 和本次构建管理，不创建下载、运行时缓存或可跨工作树复用的生成物。运行时不写安装目录或发行资源，所以不改变代码签名及 Sparkle 增量更新基线。

### Viva 的源码检查必须定位到真实目录

Viva 使用同一共享词条生成 Go 字典。`verify-app-language-localization.mjs` 对真实桌面源码检查未注册 key、错误参数、手写界面文案和包装函数，不能只验证生成文件是否最新。

检查器从模块 URL 定位仓库时必须调用 Node 的 `fileURLToPath`，不能直接用 URL 的 `pathname`。后者在 Windows 上带额外的盘符前导斜杠，在空格或中文目录下也会保留 URL 转义；结果可能是找不到源码目录，却返回“检查通过”。回归把夹具移入带空格和中文的目录，写入未注册 key，要求确实扫描并拒绝。

## 考虑过的备选方案

- 运行时读取共享 JSON：需要新增加载与回退路径，增加启动和语言切换状态，当前没有收益足以承担这个代价。
- 一次替换全部词条：会混淆同名不同义文案，改动面大，回归难定位。先迁移通用操作和少量设置标签验证架构，再完整迁入原有字典并比对每个原 key 的值，保证迁移不改变现有文案。
- 使用新的多语言运行时库：当前已有的简单命名插值即可满足需要。复杂复数或第三方包出现实际需求后再评估成熟工具，不提前设计下载与热加载协议。

## 后果

已迁移词条有一个编辑来源，新增语言的词条能贯通生成，桌面端语言列表仍需在 `i18n.go` 补齐；旧设置值保留。代价是提交中包含可复验的生成产物，需要同时提交共享源与生成结果。原资源缺少的译文以英文回退，不声称这些句子都已人工翻译。生成检查通过不等于整机语言切换验收完成。

## 验证

- `node scripts/i18n/generate-i18n.mjs --check`：清单、参数、覆盖和产物一致性（只读）。
- `node --test --test-timeout=60000 scripts/i18n/test-i18n.mjs`：非法输入、生成物所有权、新增语言和回退链。
- `node scripts/i18n/verify-app-language-localization.mjs`：源码中未注册 key、错误参数和手写界面文案。
- `./scripts/desktop/desktop-go.sh test ./internal/i18n`：Go 字典读取与格式化。
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：生成资源不写发行目录。
- `./scripts/agent-notes/verify-agent-notes.sh`。

生成器测试用临时夹具覆盖新增语言、回退链、参数与别名校验和生成物过期检测；Go 字典的读取与 `{name}` 替换由 `desktop/internal/i18n` 的测试覆盖。原先只给原生字符串表用的 `shared/i18n/fixtures/format-v1.json`、`native-abi-v1.json` 已随生成路径删除，桌面测试从未读取它们。

## 适用范围

- `shared/i18n/`
- `scripts/i18n/generate-i18n.mjs`
- `scripts/i18n/verify-app-language-localization.mjs`
- `scripts/i18n/test-i18n.mjs`
- `desktop/internal/i18n/`
