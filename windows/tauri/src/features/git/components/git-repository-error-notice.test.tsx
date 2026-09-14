import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { LocaleProvider } from "@/i18n/locale-provider";
import type { DisplayLanguage } from "@/i18n/locale";
import { GitRepositoryErrorNotice } from "./git-repository-error-notice";

function renderError(error: string, language: DisplayLanguage = "zh-CN") {
  return renderToStaticMarkup(
    <LocaleProvider language={language}>
      <GitRepositoryErrorNotice error={error} root="//server/share/repo" />
    </LocaleProvider>,
  );
}

test("explains shared-folder ownership failures and retains the Git diagnostic in both languages", () => {
  const error = "Git setup operation failed: fatal: detected dubious ownership in repository at '//server/share/repo'";
  const chinese = renderError(error);
  expect(chinese).toContain('role="alert"');
  expect(chinese).toContain("Git 未信任此仓库的目录所有权");
  expect(chinese).toContain("共享文件夹");
  expect(chinese).toContain("查看 Git 错误详情");
  expect(chinese).toContain("detected dubious ownership");
  expect(chinese).toContain("//server/share/repo");
  expect(renderError(error, "en-US")).toContain("Shared folders can trigger this check");
});

test("distinguishes filesystem permission failures from Git ownership checks", () => {
  for (const reason of ["Permission denied", "Access is denied", "Access denied", "Operation not permitted"]) {
    const markup = renderError(`fatal: cannot read directory: ${reason}`);
    expect(markup).toContain("Git 没有访问此仓库文件夹的权限");
    expect(markup).toContain(reason);
    expect(markup).not.toContain("Git 未信任此仓库的目录所有权");
  }
});

test("keeps other failures accurate and redacts credentials in expandable details", () => {
  const markup = renderError("fatal: bad config https://fixture:password@example.invalid/repo?token=fixture-secret");
  expect(markup).toContain("Git 读取仓库时发生错误");
  expect(markup).toContain("fatal: bad config");
  expect(markup).not.toContain("没有访问此仓库文件夹的权限");
  expect(markup).not.toContain("password");
  expect(markup).not.toContain("fixture-secret");
  for (const reason of ["Permission denied (publickey)", "Authentication failed: Access denied"]) {
    const authentication = renderError(reason);
    expect(authentication).toContain("Git 读取仓库时发生错误");
    expect(authentication).not.toContain("没有访问此仓库文件夹的权限");
  }
});
