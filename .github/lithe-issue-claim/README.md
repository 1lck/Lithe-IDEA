# Issue 认领机器人

`.github/workflows/lithe-issue-claim.yml` 只处理普通 Issue 的新评论，不处理
Pull Request 评论。评论内容必须精确匹配 `/assign` 或 `/unassign`。

- `/assign` 在 Issue 没有负责人时把评论者设为唯一 assignee，并添加 `claimed` 标签。
- 已有负责人时不会抢占；当前负责人重复认领也不会重复写入。
- `/unassign` 只能由当前负责人执行；仓库 owner、member 或 collaborator 可以代为释放。
- 每天定时检查认领状态。认领满 30 天且没有认领者本人发布有效进度评论时，添加 `stale-claim` 标签并提醒。
- 提醒后 7 天仍没有有效进度，自动释放 assignee 和状态标签。

“有效进度”目前定义为认领者在认领后发布的普通评论；`/assign` 和 `/unassign` 命令本身不算进展。
