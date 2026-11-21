# 设置分组调整：控制台和可信位置移到工具，版本控制拆出 Git 子页

来自生产 Viva Page 的无头渲染（`TestVisualSettingsGroups`）。可信文件夹由测试的假加载器提供，路径是虚构的；不读写真实的偏好目录。深色截图是中文界面，浅色截图是英文界面；侧栏展开“版本控制”“构建、执行、部署”和“工具”。

- `before/`：改动前（main 1661e18e8）。“控制台”“可信位置”在“构建、执行、部署”下，“版本控制”是一个直接放开关的页面。
- `after/`：改动后。“工具”下依次是终端、搜索、控制台、可信位置；“版本控制”是目录页，列出“Git”一行，原来的开关都在“Git”子页；“构建、执行、部署”目录页只列自己的子页。

截图不代表 macOS/Windows 原生窗口验收。

| 场景 | 改动前（深色中文） | 改动后（深色中文） | 改动前（浅色英文） | 改动后（浅色英文） |
| --- | --- | --- | --- | --- |
| 版本控制 | [前](before/version-control-dark.png) | [后](after/version-control-dark.png) | [前](before/version-control-light.png) | [后](after/version-control-light.png) |
| Git 子页 | — | [后](after/git-dark.png) | — | [后](after/git-light.png) |
| 构建、执行、部署 | [前](before/build-dark.png) | [后](after/build-dark.png) | [前](before/build-light.png) | [后](after/build-light.png) |
| 控制台 | [前](before/console-dark.png) | [后](after/console-dark.png) | [前](before/console-light.png) | [后](after/console-light.png) |
| 可信位置 | — | [后](after/trusted-locations-dark.png) | — | [后](after/trusted-locations-light.png) |

重新生成改动后的截图：

```bash
cd desktop
LITHE_VISUAL_OUTPUT_DIR=../docs/assets/settings-tools-and-git/after \
  ../scripts/desktop/desktop-go.sh test -tags vivahead,lithevisual ./internal/settingswindow \
  -run '^TestVisualSettingsGroups$' -count=1 -timeout 300s
```
