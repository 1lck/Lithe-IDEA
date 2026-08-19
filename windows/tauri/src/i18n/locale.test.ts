import { describe, expect, test } from "bun:test";
import { defaultSettings } from "@/features/settings/config/default-settings";
import { createTranslator, getLocaleCatalog } from "./locale";

describe("Windows display language", () => {
  test("uses Simplified Chinese strings and falls back to English", () => {
    const translate = createTranslator("zh-CN");

    expect(translate("workbench.terminal")).toBe("终端");
    expect(translate("footer.spaces", { count: 4 })).toBe("4 个空格");
    expect(translate("footer.memoryUsage", { total: "213.7 MB", used: "213.7 MB" })).toBe(
      "总计 213.7 MB · Lithe 213.7 MB",
    );
    expect(createTranslator("en-US")("footer.memoryUsage", { total: "213.7 MB", used: "131.2 MB" })).toBe(
      "Total 213.7 MB · Lithe 131.2 MB",
    );
    expect(translate("notifications.search")).toBe("搜索通知");
    expect(translate("notifications.empty")).toBe("暂无通知。");
    expect(createTranslator("en-US")("notifications.search")).toBe("Search notifications");
    expect(translate("workbench.changes")).toBe("更改");
    expect(translate("footer.changes", { count: 5 })).toBe("5 个更改");
    expect(translate("git.commit")).toBe("提交");
    expect(translate("git.commitMessagePlaceholder")).toBe("提交说明...");
    expect(translate("git.filesStaged", { count: 42 })).toBe("已暂存 42 个文件");
    expect(createTranslator("en-US")("workbench.search")).toBe("Search");
    expect(translate("search.emptyTitle")).toBe("在项目中搜索");
    expect(createTranslator("en-US")("search.emptyTitle")).toBe("Search across your project");
    expect(translate("search.emptyDescription")).toBe(
      "输入关键词，即可在整个项目中查找匹配的文件和代码行。",
    );
    expect(createTranslator("en-US")("workbench.sourceControl")).toBe("Source Control");
    expect(translate("workbench.gitLog")).toBe("提交记录");
    expect(translate("git.branches")).toBe("分支");
    expect(translate("git.searchBranches")).toBe("搜索分支...");
    expect(translate("git.newBranch")).toBe("新建分支");
    expect(translate("git.log.openDiff")).toBe("打开差异");
    expect(translate("git.log.headCurrentBranch")).toBe("HEAD（当前分支）");
    expect(translate("run.identifyAndGenerate")).toBe("识别并生成");
    expect(createTranslator("en-US")("workbench.run")).toBe("Run");
    expect(createTranslator("en-US")("titleProject.closeProject", { name: "Lithe" })).toBe(
      "Close project Lithe",
    );
    expect(translate("titleProject.closeProject", { name: "Lithe" })).toBe("关闭项目 Lithe");
    expect(translate("welcome.openProject")).toBe("打开项目");
    expect(translate("workbench.diagnostics")).toBe("诊断");
    expect(translate("diagnostics.empty")).toBe("未检测到问题");
    expect(translate("diagnostics.search")).toBe("搜索问题");
    expect(translate("diagnostics.groupByFile")).toBe("分组：文件");
    expect(translate("diagnostics.problemCount", { count: 0 })).toBe("0 个问题");
    expect(translate("files.open")).toBe("打开");
    expect(translate("files.copyContent")).toBe("复制内容");
    expect(translate("files.reveal")).toBe("在资源管理器中显示");
    expect(createTranslator("en-US")("files.reveal")).toBe("Reveal in File Explorer");
    expect(translate("quickOpen.searchFiles")).toBe("输入以搜索文件...");
    expect(translate("quickOpen.filesCount", { count: 66 })).toBe("66 个文件");
    expect(translate("tabs.pin")).toBe("固定标签页");
    expect(translate("tabs.closeOthers")).toBe("关闭其他");
    expect(translate("editor.aiInlineEdit")).toBe("AI 行内编辑");
    expect(translate("editor.findInFile")).toBe("在文件中查找");
    expect(translate("lsp.noActive")).toBe("没有活动的语言服务器");
    expect(translate("editor.goToDefinition")).toBe("转到定义");
    expect(translate("git.historySearch")).toBe("搜索历史");
    expect(translate("git.historyFilterAll")).toBe("全部字段");
    expect(translate("git.push")).toBe("推送");
    expect(translate("git.selectRepository")).toBe("选择仓库");
    expect(translate("git.stashAllUnstaged")).toBe("贮藏全部未暂存");
    expect(translate("git.unstaged")).toBe("未暂存");
    expect(translate("git.diff.search")).toBe("搜索差异");
    expect(translate("git.searchStashes")).toBe("搜索贮藏...");
    expect(translate("git.stashesCount", { count: 0 })).toBe("0 个贮藏");
    expect(translate("git.noStashes")).toBe("暂无贮藏");
    expect(translate("git.compareBranchPlaceholder")).toBe("将当前分支与...比较");
    expect(translate("git.noOtherBranches")).toBe("没有其他分支");
    expect(translate("git.searchCommits")).toBe("搜索提交...");
    expect(translate("git.commitCount", { count: 1 })).toBe("1 个提交");
    expect(translate("git.generateCommitMessageWithAI")).toBe("使用 AI 生成提交说明");
    expect(translate("git.commitMessageTitleOnly")).toBe("仅标题");
    expect(translate("git.commitMessageTitleAndBody")).toBe("标题 + 正文");
    expect(translate("welcome.chooseHowToStart")).toBe("选择如何开始...");
    expect(translate("welcome.openFolder")).toBe("打开文件夹");
    expect(translate("missing.key")).toBe("missing.key");
    expect(getLocaleCatalog("en-US")).toHaveProperty(["settings.displayLanguage"]);
    expect(defaultSettings.displayLanguage).toBe("en-US");
  });

  test("keeps English and Simplified Chinese catalogs aligned", () => {
    const englishKeys = Object.keys(getLocaleCatalog("en-US")).sort();
    const chineseKeys = Object.keys(getLocaleCatalog("zh-CN")).sort();

    expect(chineseKeys).toEqual(englishKeys);
  });

  test("translates the project open destination prompt", () => {
    const english = createTranslator("en-US");
    const chinese = createTranslator("zh-CN");

    expect(english("projectOpen.title")).toBe("Open Project");
    expect(english("projectOpen.where", { project: "Lithe" })).toBe(
      'Where do you want to open project "Lithe"?',
    );
    expect(english("projectOpen.doNotAskAgain")).toBe("Do not ask again");
    expect(english("projectOpen.cancel")).toBe("Cancel");
    expect(english("projectOpen.newWindow")).toBe("New Window");
    expect(english("projectOpen.thisWindow")).toBe("This Window");
    expect(english("titleProject.newProject")).toBe("New Project…");
    expect(english("titleProject.open")).toBe("Open…");
    expect(english("titleProject.cloneRepository")).toBe("Clone Repository…");
    expect(english("titleProject.openProjects")).toBe("Open Projects");
    expect(english("titleProject.recentProjects")).toBe("Recent Projects");
    expect(english("titleProject.noRecentProjects")).toBe("No recent projects");
    expect(english("titleProject.trigger", { project: "Lithe" })).toBe("Project: Lithe");

    expect(chinese("projectOpen.title")).toBe("打开项目");
    expect(chinese("projectOpen.where", { project: "Lithe" })).toBe(
      '你想在哪里打开项目“Lithe”？',
    );
    expect(chinese("projectOpen.doNotAskAgain")).toBe("不再询问");
    expect(chinese("projectOpen.cancel")).toBe("取消");
    expect(chinese("projectOpen.newWindow")).toBe("新窗口");
    expect(chinese("projectOpen.thisWindow")).toBe("此窗口");
    expect(chinese("titleProject.newProject")).toBe("新建项目…");
    expect(chinese("titleProject.open")).toBe("打开…");
    expect(chinese("titleProject.cloneRepository")).toBe("克隆仓库…");
    expect(chinese("titleProject.openProjects")).toBe("打开的项目");
    expect(chinese("titleProject.recentProjects")).toBe("最近项目");
    expect(chinese("titleProject.noRecentProjects")).toBe("没有最近项目");
    expect(chinese("titleProject.trigger", { project: "Lithe" })).toBe("项目：Lithe");
  });
});
