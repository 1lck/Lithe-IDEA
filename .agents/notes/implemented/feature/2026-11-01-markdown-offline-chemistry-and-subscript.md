# Agent 笔记：Markdown 离线化学公式与下标

状态：已实现

## 先说结论

macOS 已有数学公式和 Mermaid 图表的离线引擎，不需要再造解析器或接在线服务。
本次补上 KaTeX 的化学扩展 mhchem，使 `\ce{...}` 反应式和 `\pu{...}` 物理单位可用，
并启用 Comrak 现成的下标扩展。Issue #706 还包含 Windows 对齐及 PlantUML，
这些未完成项不能因本批增强而被当作整体完成。

## 问题

KaTeX 是把 LaTeX 数学语法转换为网页公式的成熟库，但基础库不包含 mhchem，
后者是负责解析化学反应和单位的可选扩展。只打包基础库时，数学公式能显示，
`\ce{H2O}` 却报未定义命令。共享 Markdown 解析器 Comrak 已支持上下标，
此前只启用了上标，`H~2~O` 不能正确输出下标。

## 决策

- 从同版本 KaTeX 0.16.0 npm 分发包提取 mhchem，先验证整个归档的 SHA-512 完整性，
  再固定脚本 SHA-256，保留源文件中被压缩分发去掉的版权和适配声明。
- 模板按 KaTeX、mhchem、预览脚本顺序加载。现有公式渲染器继续使用 `trust: false`，
  不接受公式引入脚本、网页或网络资源；运行时不下载任何依赖。
- 开启 Comrak 的 `subscript`。单波浪线表示下标，双波浪线仍表示删除线，
  代码中的字面语法保持原文。正确例子是 `H~2~O`，不要用正则替换全文中的 `~`，
  否则代码、删除线和公式会被误改。
- 共享输入加真实 WebKit 浏览器引擎回归，同时检查数学、化学、Mermaid 生成的 SVG、
  脚注及回链，不能仅断言代码块带有语言类名就声称图表可用。

## 考虑过的备选方案

- 重新实现化学语法：已有与当前 KaTeX 完全匹配的成熟上游，不采用。
- 运行时从 CDN 加载：离线失败且扩大网络和供应链边界，不采用。
- 顺手升级 KaTeX、Mermaid 或把 Windows 解析器整体迁移：增加无关兼容性风险，
  本批只填已证实缺口，不把两个平台现状混为一致。
- 直接接入在线 PlantUML 服务器：会把用户文档发送到第三方，也不能离线，不采用。
  PlantUML 的独立上游、分发和执行隔离需另外验证，不在本批暗中加入。

## 后果

数学公式、化学反应、单位和上下标可以在无网络预览中共存，新增脚本与已有 KaTeX 版本绑定。
代价是需要随 KaTeX 更新一起核对扩展、许可、来源哈希及真实引擎回归。
GitHub 特有媒体、PlantUML 及 Windows 方言对齐不是本批已交付能力。

这些模板和第三方脚本是 Git 输入，构建复制后再签名，运行时只读加载。
渲染状态仅在内存和非持久 WebKit 中存活，不新增缓存、下载或安装目录写入；
资源复用清单显式排除整个 Markdown 预览资源，不跨工作树复制生成 bundle。
这不改变代码签名或 Sparkle 增量更新所依赖的发布字节。

## 验证

- `cargo test --manifest-path rust/Cargo.toml -p lithe-core project::markdown::tests`。
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter MarkdownPreviewRichContentTests`：
  深浅主题使用生产 Rust bridge 和打包模板，检查公式与可访问数学标记 MathML、图表、脚注和代码，
  并比较运行前后全部预览文件 SHA-256，检查没有远程资源请求。
- `node --test scripts/resources/test-reuse-worktree-resources.mjs`：拒绝跨工作树复制预览资源。
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`。

原生组件测试不代替完整应用操作验收，Windows 运行时未在本批验证。

## 适用范围

- `rust/lithe-core/src/project/markdown.rs`
- `macos/Sources/Lithe/Resources/MarkdownPreview/`
- `macos/Tests/LitheTests/MarkdownPreviewRichContentTests.swift`
- `shared/fixtures/editor/markdown-rich-content-v1.json`
- `scripts/resources/worktree-resources.json`
