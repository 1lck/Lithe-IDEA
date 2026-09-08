import { useEffect, useState } from "react";
import { frontendTrace } from "@/utils/frontend-trace";
import { discoverJavaTestMethods } from "../api/maven-core-api";
import { projectJavaTestMethods, type JavaTestMethod } from "../utils/maven-test-selection";

export function useJavaTestMethods(
  filePath: string | undefined,
  content: string,
  enabled = true,
): JavaTestMethod[] {
  const [methods, setMethods] = useState<JavaTestMethod[]>([]);

  useEffect(() => {
    if (!enabled || !filePath || !/\.java$/i.test(filePath)) {
      setMethods([]);
      return;
    }

    setMethods([]);
    let cancelled = false;
    void discoverJavaTestMethods(content)
      .then((values) => {
        if (!cancelled) setMethods(projectJavaTestMethods(values));
      })
      .catch((error) => {
        if (cancelled) return;
        setMethods([]);
        frontendTrace("warn", "maven.test.discovery", "javaStructure:error", {
          filePath,
          error: error instanceof Error ? error.message : String(error),
        });
      });

    return () => {
      cancelled = true;
    };
  }, [content, enabled, filePath]);

  return methods;
}
