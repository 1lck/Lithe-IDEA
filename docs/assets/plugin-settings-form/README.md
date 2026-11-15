# 插件设置页测试截图

来自生产 Viva Page 的无头渲染。已安装插件的设置标签页由真实的 Rust Core 校验清单、给出各行，
设置文件放在测试的临时目录里，所以页面上的来源路径是临时目录。清单里的五个设置仿照一个语言插件
（一个工具链文件、三个开关、一个选项），只是测试数据，不代表任何已发布插件的输出。
深色使用中文、浅色使用英文；设置的标题和说明是插件自己的文字，界面语言不会翻译它们。
截图不代表 macOS/Windows 原生窗口验收。

| 场景 | 深色中文 | 浅色英文 |
| --- | --- | --- |
| 每个设置两行：标题行是标题、ⓘ（说明）和“重置”，下一行是控件；开关旁不重复标题，行下没有常驻说明；作用范围的说明收进范围选择旁的 ⓘ | [截图](plugin-settings-form-dark.png) | [截图](plugin-settings-form-light.png) |

复验：设置 `LITHE_VISUAL_OUTPUT_DIR`，在 `desktop/` 下通过 `../scripts/desktop/desktop-go.sh test
-tags vivahead,lithevisual ./internal/settingswindow -run '^TestVisualPluginSettingsForm$'
-count=1` 生成。把 `TMPDIR` 指向一个中性的目录（例如 `/tmp/lithe-visual/`），截图里的来源路径就不会带上个人目录。
