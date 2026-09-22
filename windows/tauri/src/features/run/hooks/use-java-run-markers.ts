import { useDeferredValue, useEffect, useMemo, useState } from "react";
import { javaTestMethodsFromItems } from "@/features/maven/services/java-test-discovery";
import { useMavenStore } from "@/features/maven/stores/maven.store";
import type { JavaTestMethod } from "@/features/maven/types/maven.types";
import type { WorkspaceLaunchScope } from "@/features/workspace/types/workspace-launch-scope";
import { frontendTrace } from "@/utils/frontend-trace";
import {
  discoverJavaRunSources,
  projectJavaRunMarkers,
  type JavaRunMarker,
  type JavaRunSources,
} from "../services/java-run-markers";
import { whenJavaProjectPrepared } from "../services/java-entrypoint-discovery";

interface OwnedSources {
  filePath: string;
  sources: JavaRunSources;
}

interface OwnedMarkers {
  filePath: string;
  markers: JavaRunMarker[];
}

export interface JavaRunMarkerState {
  /** IDEA-style gutter markers for the file, empty until JDT answered. */
  markers: JavaRunMarker[];
  /** Test methods from the same Java Test answer, for Maven test actions. */
  testMethods: JavaTestMethod[];
}

const EMPTY_STATE: JavaRunMarkerState = { markers: [], testMethods: [] };

/**
 * Keeps one Java file's Run markers current.
 *
 * JDT is asked again when the text settles, when the language service
 * reports a new revision (`refreshRevision`), and once the project finishes
 * preparing, because answers given mid-import are partial. A failed request
 * keeps the previous answer for the same file instead of clearing markers, and
 * editor decorations follow text edits in the meantime. Recorded test outcomes
 * only re-run Core's projection; they never trigger a new JDT request.
 */
export function useJavaRunMarkers(
  scope: WorkspaceLaunchScope | null,
  filePath: string,
  source: string,
  enabled: boolean,
  includeTests: boolean,
  refreshRevision: string,
): JavaRunMarkerState {
  // JDT discovery is process-backed; React coalesces rapid edits before a
  // new request, so no timer or polling loop is introduced here.
  const deferredSource = useDeferredValue(source);
  const [owned, setOwned] = useState<OwnedSources | null>(null);
  const [projected, setProjected] = useState<OwnedMarkers | null>(null);
  const [preparedRevision, setPreparedRevision] = useState(0);
  const testOutcomes = useMavenStore((state) => state.testOutcomes);
  const active = enabled && Boolean(scope) && /\.java$/i.test(filePath);

  useEffect(() => {
    if (!active || !scope) return;
    return whenJavaProjectPrepared(scope.root, () => setPreparedRevision((value) => value + 1));
  }, [active, scope]);

  useEffect(() => {
    if (!active || !scope) {
      setOwned(null);
      return;
    }
    let cancelled = false;
    void discoverJavaRunSources(scope, filePath, deferredSource, includeTests)
      .then((sources) => {
        if (!cancelled) setOwned({ filePath, sources });
      })
      .catch((error) => {
        if (cancelled) return;
        setOwned((current) => (current?.filePath === filePath ? current : null));
        frontendTrace("warn", "run.javaRunMarkers", filePath, {
          error: error instanceof Error ? error.message : String(error),
        });
      });
    return () => {
      cancelled = true;
    };
  }, [active, deferredSource, filePath, includeTests, preparedRevision, refreshRevision, scope]);

  useEffect(() => {
    if (!owned) {
      setProjected(null);
      return;
    }
    let cancelled = false;
    void projectJavaRunMarkers(owned.sources, testOutcomes)
      .then((markers) => {
        if (!cancelled) setProjected({ filePath: owned.filePath, markers });
      })
      .catch((error) => {
        if (cancelled) return;
        frontendTrace("warn", "run.javaRunMarkers.project", owned.filePath, {
          error: error instanceof Error ? error.message : String(error),
        });
      });
    return () => {
      cancelled = true;
    };
  }, [owned, testOutcomes]);

  const testMethods = useMemo(
    () => (owned ? javaTestMethodsFromItems(owned.sources.testItems) : []),
    [owned],
  );

  if (!active || owned?.filePath !== filePath) return EMPTY_STATE;
  return {
    markers: projected?.filePath === filePath ? projected.markers : [],
    testMethods,
  };
}
