import { useDeferredValue, useEffect, useState } from "react";
import { frontendTrace } from "@/utils/frontend-trace";
import type { WorkspaceLaunchScope } from "@/features/workspace/types/workspace-launch-scope";
import { discoverJavaTestMethods } from "../services/java-test-discovery";
import type { JavaTestMethod } from "../types/maven.types";

export function useJavaTestMethods(
  scope: WorkspaceLaunchScope | null,
  filePath: string,
  source: string,
  enabled: boolean,
) {
  // JDT discovery is process-backed. Let rapid editor updates coalesce before
  // starting another semantic request; React owns the scheduling, so no
  // unbounded timer or polling loop is introduced here.
  const deferredSource = useDeferredValue(source);
  const [result, setResult] = useState<{
    filePath: string;
    source: string;
    methods: JavaTestMethod[];
  } | null>(null);

  useEffect(() => {
    if (!enabled || !scope || !/\.java$/i.test(filePath)) {
      setResult(null);
      return;
    }

    let cancelled = false;
    void discoverJavaTestMethods(scope, filePath, deferredSource)
      .then((methods) => {
        if (!cancelled) setResult({ filePath, source: deferredSource, methods });
      })
      .catch((error) => {
        if (cancelled) return;
        setResult({ filePath, source: deferredSource, methods: [] });
        frontendTrace("warn", "maven.testMethods", filePath, {
          error: error instanceof Error ? error.message : String(error),
        });
      });

    return () => {
      cancelled = true;
    };
  }, [deferredSource, enabled, filePath, scope]);

  return enabled && result?.filePath === filePath && result.source === source
    ? result.methods
    : [];
}
