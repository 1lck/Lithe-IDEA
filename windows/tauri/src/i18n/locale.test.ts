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
});
