export const changelistsEnglish = {
  "git.changelists.default": "Default",
  "git.changelists.active": "Active changelist",
  "git.changelists.activeSuffix": " (active)",
  "git.changelists.new": "New changelist",
  "git.changelists.rename": "Rename changelist",
  "git.changelists.delete": "Delete changelist",
  "git.changelists.deleteDescription":
    "Files return to Default and may be included by its bulk staging. File contents and the Git index are unchanged.",
  "git.changelists.name": "Changelist name",
  "git.changelists.invalidName": "Use a unique, nonempty name of at most 100 characters.",
  "git.changelists.move": "Move to changelist",
  "git.changelists.stageActive": "Stage all changes in the active changelist",
  "git.changelists.unstageActive": "Unstage all changes in the active changelist",
  "git.changelists.scope": "Commit: {name}. Other lists must be unstaged.",
  "git.changelists.otherStaged":
    "Other changelists contain staged changes. Uncheck those files or switch the active list before committing.",
  "git.changelists.unavailable":
    "Saved changelists could not be read. Staging and committing are disabled to protect excluded files.",
} as const;
export const changelistsChinese: Record<keyof typeof changelistsEnglish, string> = {
  "git.changelists.default": "默认",
  "git.changelists.active": "活动变更列表",
  "git.changelists.activeSuffix": "（活动）",
  "git.changelists.new": "新建变更列表",
  "git.changelists.rename": "重命名变更列表",
  "git.changelists.delete": "删除变更列表",
  "git.changelists.deleteDescription":
    "文件将回到默认列表，可能被其批量暂存操作选中。文件内容和 Git 暂存区保持不变。",
  "git.changelists.name": "变更列表名称",
  "git.changelists.invalidName": "请输入不重名、非空且不超过 100 个字符的名称。",
  "git.changelists.move": "移动到变更列表",
  "git.changelists.stageActive": "暂存活动变更列表中的全部改动",
  "git.changelists.unstageActive": "取消暂存活动变更列表中的全部改动",
  "git.changelists.scope": "提交范围：{name}。其他列表需取消暂存。",
  "git.changelists.otherStaged":
    "其他变更列表中还有已暂存改动，请取消其勾选或切换活动列表后再提交。",
  "git.changelists.unavailable": "无法读取已保存的变更列表。为保护排除的文件，已停用暂存和提交。",
};
