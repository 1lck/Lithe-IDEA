import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { LocaleProvider } from "@/i18n/locale-provider";
import { JavaLaunchDecisionBanner } from "./java-launch-decision";

const noop = () => undefined;

test("shows the standard continue and recovery choices with build evidence", () => {
  const markup = renderToStaticMarkup(
    <LocaleProvider language="en-US">
      <JavaLaunchDecisionBanner
        decision={{
          decisionId: "decision",
          sessionId: "service",
          configurationId: "service",
          configurationName: "Service",
          failure: {
            code: "javaBuildCompilationErrors",
            message: "The Java project has compilation errors.",
            report: {
              markerScope: "workspace",
              builderFailedEarlier: true,
              elapsedMilliseconds: 7,
              recovery: "rebuildJavaIndex",
            },
          },
        }}
        onContinue={noop}
        onAlwaysContinue={noop}
        onRebuildIndex={noop}
        onCancel={noop}
        onOpenLogs={noop}
      />
    </LocaleProvider>,
  );

  expect(markup).toContain("Run Anyway");
  expect(markup).toContain("Always Continue in This Workspace");
  expect(markup).toContain("Rebuild Java Index");
  expect(markup).toContain("Open Logs");
  expect(markup).toContain("reported errors may be left over");
  expect(markup).toContain("other workspace modules");
  expect(markup).toContain("7 ms");
});

test("does not offer an index rebuild when Core did not indicate it", () => {
  const markup = renderToStaticMarkup(
    <LocaleProvider language="en-US">
      <JavaLaunchDecisionBanner
        decision={{
          decisionId: "decision",
          sessionId: "service",
          configurationId: "service",
          configurationName: "Service",
          failure: {
            code: "javaBuildCompilationErrors",
            message: "The Java project has compilation errors.",
          },
        }}
        onContinue={noop}
        onAlwaysContinue={noop}
        onRebuildIndex={noop}
        onCancel={noop}
        onOpenLogs={noop}
      />
    </LocaleProvider>,
  );

  expect(markup).toContain("Run Anyway");
  expect(markup).not.toContain("Rebuild Java Index");
});
