# 多仓库项目文件夹测试截图

来自生产 Viva Page 的无头渲染。项目文件夹本身不是 Git 仓库，里面有三个独立仓库 backend、frontend、shared，
由测试在临时目录中创建；颜色由 Core 按仓库分配。提交日期固定，混排顺序每次相同。深色使用中文、浅色使用英文。
截图不代表 macOS/Windows 原生窗口验收。

| 场景 | 深色中文 | 浅色英文 |
| --- | --- | --- |
| 标题栏分支入口：先列出“提交…”，再按 IDEA 的样式逐行列出仓库，每行有颜色方块、仓库名、右侧的当前分支和 ›；点击 frontend 后，面板在这一行旁边展开，列出该仓库的分支操作和“frontend 中的最近分支 / 本地分支 / 远程分支 / 标签”，在面板里新建、检出等操作只作用于 frontend；仓库列表下方是三个仓库共有的分支（下一行） | [截图](workspace-branch-popup-dark.png) | [截图](workspace-branch-popup-light.png) |
| 标题栏分支入口的共同分支：三个仓库都有 develop、main 和 feature/login，仓库列表下方按 IDEA 的 Common Local Branches 列出“共同本地分支”（feature/login 收在 feature 分组里）；三个仓库不在同一分支上，所以没有当前分支标记；仓库没有远程，不显示“共同远程分支”。在这里检出或新建分支会依次作用于每个仓库 | [截图](workspace-branch-common-dark.png) | [截图](workspace-branch-common-light.png) |
| 共同分支只在部分仓库完成：在共同本地分支 develop 上检出，frontend 已在 develop 被跳过，backend 已切换，shared 失败（测试让 shared 拒绝检出）；对话框说明在哪个仓库因何失败、已在哪些仓库完成，“不回滚”保持现状，“回滚”让 backend 回到 main。下方 Git 控制台开头的红色 for-each-ref 报错是打开非仓库文件夹时既有的问题，与本场景无关 | [截图](workspace-branch-rollback-dark.png) | [截图](workspace-branch-rollback-light.png) |
| Git 日志：文件夹本身不是仓库，Core 选第一个嵌套仓库 backend；提交行最左侧是 backend 的颜色条；筛选栏“路径”之后是仓库名，用仓库颜色显示，带下拉箭头，点击可选择仓库；左侧引用面板每个仓库一个节点，节点下各有自己的“本地 / 远程 / 标签” | [截图](workspace-git-log-dark.png) | [截图](workspace-git-log-light.png) |
| 路径筛选器下方的“仓库根目录”：按颜色列出三个仓库并勾选正在查看的一个；勾选或取消勾选即改变日志查看的仓库 | [截图](workspace-log-roots-dark.png) | [截图](workspace-log-roots-light.png) |
| 点击筛选栏里的仓库名：弹出同一份仓库列表，可多选 | [截图](workspace-log-choose-dark.png) | [截图](workspace-log-choose-light.png) |
| 勾选 backend 和 frontend：Core 把两个仓库的历史按提交时间混排成一个列表，各仓库内部保持 Git 顺序；每行左侧是所属仓库的颜色条，两个仓库的图互不相连；筛选栏的仓库名变成两个颜色方块和“2 个仓库”；backend 的 main 和 frontend 的 develop 各自检出，两个仓库当前分支上的提交都有当前分支底色 | [截图](workspace-log-merged-dark.png) | [截图](workspace-log-merged-light.png) |
| Git 日志筛选栏放不下全部视图按钮时：筛选项和仓库名完整保留，放不下的按钮收进末尾的“更多操作”（…）菜单，每项带图标，“显示提交详情”等开关项开启时打勾；全部收进菜单后文本筛选框再缩窄，最后才裁掉筛选项 | [截图](workspace-log-more-dark.png) | [截图](workspace-log-more-light.png) |
| 提交窗口：按仓库分组，每组有暂存复选框、颜色、文件数和该仓库当前分支的标签，组内没有单独的提交按钮；顶部复选框按 Core 的计划暂存全部仓库；状态栏统计所有仓库的更改数 | [截图](workspace-commit-groups-dark.png) | [截图](workspace-commit-groups-light.png) |
| “提交并推送”提交完成后打开的“推送提交”对话框：左侧每个仓库一行，有勾选框、仓库名和“分支 → origin : 分支”，下面列出待推送的提交；backend 的远程缺最后几次提交，frontend 推送时新建远程分支，shared 没有远程，显示“定义远程”且不能勾选；右侧是选中提交的变更文件；底部是“推送标记(T)”和“当前分支 / 所有”；推送按 Core 的顺序进行，子模块先于记录它的父仓库 | [截图](workspace-push-commits-dark.png) | [截图](workspace-push-commits-light.png) |

复验：设置 `LITHE_VISUAL_OUTPUT_DIR`，通过 `scripts/desktop/desktop-go.sh test
-tags vivahead,lithevisual ./internal/workbench -run '^TestVisualWorkspaceRepositories$'
-count=1 -timeout 300s` 生成。
