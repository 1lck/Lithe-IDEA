# 本地历史默认规则说明测试截图

来自生产 Viva Page 的无头渲染。设置窗口滚到“外观与行为 > 通用”的本地历史，点击通配符列表那一行的 ⓘ，
固定显示说明：默认规则是项目树中隐藏的目录，包括 Lithe 自己的目录和已启用插件声明的目录；隐藏目录里的文件始终
不记入本地历史，删掉对应的行也一样。深色使用中文、浅色使用英文。截图不代表 macOS/Windows 原生窗口验收。

| 场景 | 深色中文 | 浅色英文 |
| --- | --- | --- |
| 本地历史通配符列表的 ⓘ 说明：先说明通配符的写法，再说明列出的默认规则来自隐藏目录（例如 `**/.git/` 和构建输出目录），以及删掉这些行不会开始记录、删掉的行显示为以“!”开头的行 | [截图](local-history-rules-help-dark.png) | [截图](local-history-rules-help-light.png) |

复验：分别设置 `LITHE_VISUAL_OUTPUT_DIR`，以及 `LITHE_VISUAL_LANGUAGE=en`（英文）或不设置（中文），
通过 `scripts/desktop/desktop-go.sh test -tags vivahead,lithevisual ./internal/settingswindow
-run 'TestVisualSettings/m46-history-default-rules-help' -count=1 -timeout 300s` 生成。
