# Agent 笔记：全局源码编辑器样式

状态：已实现

## 先说结论

所有项目的源码编辑器共享一组可持久化的样式偏好，包括字体、字号、行间距、配色方案、行号、空白符、光标和常用显示开关。修改时更新现有编辑器的选项，不重建文档，因此光标、内容和撤销历史能够保留。这组设置只覆盖源码编辑器，不影响终端、差异视图、输出窗口和 SQL 控制台等其他等宽文字。

## 问题

编辑器样式如果只能在个别位置修改，或者需要重新打开文档才生效，用户就无法稳定地调整阅读体验。以后要接收其他 IDE 的配置时，产品也需要先能保存和应用这些偏好，否则导入结果没有可见的落点。

## 决策

- 偏好保存在应用设置的统一存储里。每个字段独立校验和回退，一个未知枚举值不会清空其他有效设置。字号限制为 6–72，行间距用字号的倍数 1–3；0 表示沿用自动行高，不用新的默认值改变老用户的排版。
- 设置使用原生控件和共享 i18n 词条，说明放在信息提示中。所有值即时保存，不引入第二个“应用”阶段。
- 高亮方案与界面主题相互独立。提供 Lithe、GitHub、One、VS Code、IntelliJ IDEA 五套方案，按当前深浅外观选择对应的色表。色表 JSON 与来源许可证随仓库打包在 `desktop/internal/editor/syntax/schemes/`，运行时不下载。
- 改变样式时更新已打开编辑器的选项，不为了换主题重建文档。重建会丢失撤销历史，也可能破坏多个视图共享同一文档的关系。
- 注释斜体可单独设置，取消时显式清除样式。
- IDEA 方案的语言特有颜色（例如 Java 方法、YAML 键名、XML 标签、Markdown 标题）按固定的 IntelliJ Community revision `74dbd42b7a8787b0707437cb857c68e78199f611` 的父属性核对；来源保存在方案文件和 NOTICE 中。这些映射只细分已有词法和语义角色，不承诺复刻 IDEA 的完整语言分析。
- VS Code 方案使用固定的 `b6bfa95ebee8b183d65dee4997c0527eadfe5384` 的 Dark/Light 2026 主题及继承链。相同作用域取后定义，具体作用域优先。

## 考虑过的备选方案

- 为每个界面单独保存一套字体和颜色：用户要在多处重复设置，且不同编辑器可能显示不一致。
- 将整个界面主题与源码配色绑定：不能表达用户保留界面主题、只更换代码颜色的需求。
- 复制外部编辑器的完整主题格式：会引入外部格式解析和单位换算，本次只映射现有的词法和语义角色。

## 后果

新偏好在原有应用设置存储中保存，生命周期和所有权均不变。色表属于构建输入，随应用资源打包；运行时只读，不下载字体或主题，不产生新的缓存目录，不改变发行包的字节。

方案只覆盖当前列出的预设与选项，尚不等价于完整的 VS Code 或 IDEA 主题和配置格式。语言服务的语义高亮、IDEA 插件专有的 token、扩展主题包都不在范围内。将来增加导入时必须转换单位、颜色角色与配置作用域，不能直接透传外部编辑器的选项对象。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/settingswindow/ ./internal/editorview/ ./internal/editor/... -count=1`（在 `desktop/` 下运行）：设置读写、字段回退与编辑器选项应用的回归。
- `node scripts/i18n/generate-i18n.mjs --check`
- `node scripts/i18n/verify-app-language-localization.mjs`
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`
- `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`

自动化不替代完整产品的设置布局、键盘操作、多项目与重启验收；功能矩阵单独记录待验证状态。

## 适用范围

- `desktop/internal/settingswindow/editor_preferences_view.go`
- `desktop/internal/settingswindow/fonts_view.go`
- `desktop/internal/editor/syntax/schemes/`
- `desktop/internal/editorview/paint.go`
- `desktop/internal/core/editor_essentials.go`
