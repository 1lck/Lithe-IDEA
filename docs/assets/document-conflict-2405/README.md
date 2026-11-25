# 删除文件冲突提示的视觉证据

这些图片来自 `TestVisualDeletedDocument` 的真实 Viva headless 渲染，窗口为 1000×640 logical points，覆盖 light/dark 主题与 en-US/zh-Hans 语言。`before-*` 使用修复前生产代码的 overlay，`after-*` 使用本次 PR 的最终实现；两者都通过真实文件删除流程触发提示。

修复前生产提示取自基线 `9d9ac81b2a16c947388240109274c2b1e43be13d`，截图为 2× 渲染的 2000×1280 PNG。测试生成并检查截图后，实际点击“丢弃并关闭”并确认标签关闭。无头渲染不代替 macOS 原生窗口或 Windows 整机验收。这些 PNG 仅用于代码评审，不由产品加载，也不进入发行包。

| 主题 | 语言 | 修复前 | 修复后 |
| --- | --- | --- | --- |
| Light | en-US | [before](before-light-en-US.png) | [after](after-light-en-US.png) |
| Light | zh-Hans | [before](before-light-zh-Hans.png) | [after](after-light-zh-Hans.png) |
| Dark | en-US | [before](before-dark-en-US.png) | [after](after-dark-en-US.png) |
| Dark | zh-Hans | [before](before-dark-zh-Hans.png) | [after](after-dark-zh-Hans.png) |

测试命令：

```sh
LITHE_VISUAL_OUTPUT_DIR="$PWD/.artifacts/2405-document-conflict" \
  node .agents/skills/write-stable-tests/scripts/run-go-tests-with-timing.mjs \
  --suite-timeout-ms 120000 \
  --report .artifacts/test-stability/macos-document-conflict-visual.json \
  -- ./scripts/desktop/desktop-go.sh test -json \
  -tags 'dev vivahead lithevisual' -count=1 -p=1 -parallel=1 \
  -timeout=90s -run '^TestVisualDeletedDocument$' ./internal/workbench
```
