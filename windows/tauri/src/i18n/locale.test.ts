import { describe, expect, test } from "bun:test";
import { defaultSettings } from "@/features/settings/config/default-settings";
import { createTranslator, getLocaleCatalog } from "./locale";

describe("Windows display language", () => {
  test("uses Simplified Chinese strings and falls back to English", () => {
    const translate = createTranslator("zh-CN");

    expect(translate("workbench.project")).toBe("项目");
    expect(translate("workbench.run")).toBe("运行");
    expect(translate("run.identifyAndGenerate")).toBe("识别并生成");
    expect(createTranslator("en-US")("workbench.run")).toBe("Run");
    expect(translate("welcome.openProject")).toBe("打开项目");
    expect(translate("missing.key")).toBe("missing.key");
    expect(getLocaleCatalog("en-US")).toHaveProperty(["settings.displayLanguage"]);
    expect(defaultSettings.displayLanguage).toBe("en-US");
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
