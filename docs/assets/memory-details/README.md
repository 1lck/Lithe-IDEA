# 状态栏内存详情测试截图

来自生产 Viva Page 的无头渲染，使用隔离的临时项目和配置。内存汇总由测试直接注入（虚构的
Quill Tools 语言服务器和系统辅助进程），不代表真实进程的读数。深色使用中文、浅色使用英文。
截图不代表 macOS/Windows 原生窗口验收。

| 场景 | 深色中文 | 浅色英文 |
| --- | --- | --- |
| 实例启动了语言服务器、系统辅助进程和其他子进程：顶部是总量和 ⓘ 说明，下面是按类别堆叠的条、各类别图例（多个进程时显示进程数），以及占用最多的进程和其余项的合计 | [截图](memory-details-dark.png) | [截图](memory-details-light.png) |
| 只有 Lithe 主进程：只显示主进程一类，进程列表给出说明，不列 0 MB 的类别 | [截图](memory-details-host-only-dark.png) | [截图](memory-details-host-only-light.png) |

复验：设置 `LITHE_VISUAL_OUTPUT_DIR`，通过 `scripts/desktop/desktop-go.sh test
-tags vivahead,lithevisual ./internal/workbench -run '^TestVisualMemoryDetails$'
-count=1 -timeout 180s` 生成。
