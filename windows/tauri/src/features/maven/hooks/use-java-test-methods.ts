import { useEffect, useState } from "react";
import { frontendTrace } from "@/utils/frontend-trace";
import { parseJavaTestMethods } from "../api/maven-core-api";
import type { JavaTestMethod } from "../types/maven.types";

export function useJavaTestMethods(filePath: string, source: string, enabled: boolean) {
  const [result, setResult] = useState<{
    filePath: string;
    source: string;
    methods: JavaTestMethod[];
  } | null>(null);

  useEffect(() => {
    if (!enabled || !/\.java$/i.test(filePath)) {
      setResult(null);
      return;
    }

    let cancelled = false;
    void parseJavaTestMethods(source)
      .then((methods) => {
        if (!cancelled) setResult({ filePath, source, methods });
      })
      .catch((error) => {
        if (cancelled) return;
        setResult({ filePath, source, methods: [] });
        frontendTrace("warn", "maven.testMethods", filePath, {
          error: error instanceof Error ? error.message : String(error),
        });
      });

    return () => {
      cancelled = true;
    };
  }, [enabled, filePath, source]);

  return enabled && result?.filePath === filePath && result.source === source
    ? result.methods
    : [];
}
