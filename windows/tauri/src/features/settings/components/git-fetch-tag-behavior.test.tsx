import { expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { createTranslator } from "@/i18n/locale";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import fixture from "../../../../../../shared/fixtures/git/fetch-behavior-v1.json";
import { GitFetchTagBehavior, type GitResolvedTagBehavior } from "./git-fetch-tag-behavior";

const cases = [
  ["no-tags does not override prune-tags", "git.fetch.tags.all"],
  ["explicit refspec overrides no-tags", "git.fetch.tags.all"],
  ["partial refspec is custom", "git.fetch.behavior.custom"],
  ["mixed remotes", "git.fetch.behavior.remoteDependent"],
  ["same behavior from different sources", "git.fetch.tags.none"],
  ["no remotes", "git.fetch.behavior.noRemotes"],
  ["invalid boolean prevents fetch", "git.fetch.behavior.unavailable"],
] as const;

test.each(["en-US", "zh-CN"] as const)("renders Core's effective Fetch behavior in %s", async (language) => {
  const restoreDom = installHappyDom();
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const host = document.createElement("div");
  const root = createRoot(host);
  const translate = createTranslator(language);
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    document.body.append(host);
    for (const [name, key] of cases) {
      const entry = fixture.cases.find((item) => item.name === name);
      expect(entry).toBeDefined();
      const behavior = entry!.expected.tags as GitResolvedTagBehavior;
      await act(async () => root.render(
        <LocaleProvider language={language}><GitFetchTagBehavior behavior={behavior} /></LocaleProvider>,
      ));
      expect(host.textContent).toContain(translate(key));
      if (behavior.basis === "multiple") {
        expect(host.textContent).toContain(translate("git.fetch.behavior.source.multiple"));
      }
      expect(host.textContent).not.toContain("inherit");
    }
  } finally {
    await act(async () => root.unmount());
    host.remove();
    environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});
