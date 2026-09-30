import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { LocaleProvider } from "@/i18n/locale-provider";
import { EffectiveToolchain } from "./effective-toolchain";

test("shows an automatic JDK fallback warning without run configuration diagnostics", () => {
  const warning = "No installed JDK satisfies Java 21 or newer.";
  const markup = renderToStaticMarkup(
    <LocaleProvider language="en-US">
      <EffectiveToolchain
        kind="java"
        mode="automatic"
        state={{ status: "resolved", path: "C:/fixture/jdk8", version: "1.8.0_402", vendor: "fixture", source: "javaHome", warning }}
      />
    </LocaleProvider>,
  );
  expect(markup).toContain(warning);
  expect(markup).toContain('role="alert"');
  expect(markup).toContain("C:/fixture/jdk8");
});
