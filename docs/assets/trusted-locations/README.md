# 可信位置设置页（#2207）无头测试截图

来自生产 Viva Page 的无头渲染。可信文件夹列表由测试的假加载器提供，路径都是虚构的；不读写真实的偏好目录，也不调用真实 Core。截图覆盖深色与浅色主题、中文与英文界面，用于确认：

- “构建、执行、部署”目录页多出“可信位置”一行，显示可信文件夹数量；
- 可信位置页按保存顺序列出文件夹，长路径用等宽字体并在悬停时显示完整路径；
- 待添加和待删除的文件夹分别带标签和“撤销修改”，底栏显示未应用的项数和写入目标；
- Core 拒绝把文件系统根目录设为可信位置时，提示显示在列表下方，其他草稿保留。

截图不代表 macOS/Windows 原生窗口验收。

| 场景 | 深色主题 | 浅色主题 |
| --- | --- | --- |
| 目录页（中文） | [深色中文](trusted-locations-directory-dark-zh-Hans.png) | [浅色中文](trusted-locations-directory-light-zh-Hans.png) |
| 目录页（英文） | [深色英文](trusted-locations-directory-dark-en.png) | [浅色英文](trusted-locations-directory-light-en.png) |
| 已保存的列表（中文） | [深色中文](trusted-locations-list-dark-zh-Hans.png) | [浅色中文](trusted-locations-list-light-zh-Hans.png) |
| 已保存的列表（英文） | [深色英文](trusted-locations-list-dark-en.png) | [浅色英文](trusted-locations-list-light-en.png) |
| 草稿与拒绝提示（中文） | [深色中文](trusted-locations-drafts-dark-zh-Hans.png) | [浅色中文](trusted-locations-drafts-light-zh-Hans.png) |
| 草稿与拒绝提示（英文） | [深色英文](trusted-locations-drafts-dark-en.png) | [浅色英文](trusted-locations-drafts-light-en.png) |

复验：从仓库根目录设置绝对路径 `LITHE_VISUAL_OUTPUT_DIR="$(pwd)/docs/assets/trusted-locations"`，在 `desktop/` 下通过
`../scripts/desktop/desktop-go.sh test -tags vivahead,lithevisual ./internal/settingswindow -run '^TestVisualTrustedLocations$' -count=1 -timeout 180s` 生成。
