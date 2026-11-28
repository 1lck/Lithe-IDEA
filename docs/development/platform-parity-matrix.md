# macOS / Windows 功能矩阵

[在线查看 main 分支矩阵](https://1lck.github.io/Lithe-IDEA/platform-feature-matrix/)（每次桌面端发版成功后由 Pages 工作流更新，也可以手动运行该工作流）。页面提供 Markdown、CSV、JSON 下载，并显示对应提交。

PR 对应的矩阵请在 **Verify Platform Feature Matrix** 工作流摘要中下载 artifact；在线页面不代表尚未合并的 PR。

源数据位于 [能力目录](../../shared/platform-feature-matrix/features/)，维护方式见 [功能对齐说明](platform-parity.md)。

本地运行 `node scripts/platform-feature-matrix/generate-platform-feature-matrix.mjs`，打开 `.artifacts/platform-feature-matrix/index.html`。生成文件不提交到 Git。
