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
  owner: object;
  sources: JavaRunSources;
}

interface OwnedMarkers {
  owner: object;
  markers: JavaRunMarker[];
}

export interface JavaRunMarkerState {
  /** IDEA-style gutter markers for the file, empty until JDT answered. */
  markers: JavaRunMarker[];
  /** Test methods from the same Java Test answer, for Maven test actions. */
  testMethods: JavaTestMethod[];
}

interface JavaRunMarkerDependencies {
  discover: typeof discoverJavaRunSources;
  project: typeof projectJavaRunMarkers;
  whenPrepared: typeof whenJavaProjectPrepared;
  trace: typeof frontendTrace;
}

const defaultDependencies: JavaRunMarkerDependencies = {
  discover: discoverJavaRunSources,
  project: projectJavaRunMarkers,
  whenPrepared: whenJavaProjectPrepared,
  trace: frontendTrace,
};

const EMPTY_STATE: JavaRunMarkerState = { markers: [], testMethods: [] };

/**
 * Keeps one Java file's Run markers current.
 *
 * JDT is asked again when the text settles, when the language service
 * reports a new revision (`refreshRevision`), and once the project finishes
 * preparing, because answers given mid-import are partial. Discovery and
 * projection belong to one document generation: editing invalidates both
 * immediately, even while React defers discovery or a request fails. Test outcomes
 * only re-run Core's projection; they never trigger a new JDT request.
 */
export function useJavaRunMarkers(
  scope: WorkspaceLaunchScope | null,
  filePath: string,
  source: string,
  enabled: boolean,
  includeTests: boolean,
  refreshRevision: string,
  dependencies: JavaRunMarkerDependencies = defaultDependencies,
): JavaRunMarkerState {
  // JDT discovery is process-backed; React coalesces rapid edits before a
  // new request, so no timer or polling loop is introduced here.
  const [owned, setOwned] = useState<OwnedSources | null>(null);
  const [projected, setProjected] = useState<OwnedMarkers | null>(null);
  const [preparedRevision, setPreparedRevision] = useState(0);
  const testOutcomes = useMavenStore((state) => state.testOutcomes);
  const active = enabled && Boolean(scope) && /\.java$/i.test(filePath);

  const owner = useMemo(
    () => ({ active, source, scope, filePath, includeTests, refreshRevision, preparedRevision }),
    [active, source, scope, filePath, includeTests, refreshRevision, preparedRevision],
  );
  const deferredOwner = useDeferredValue(owner);

  useEffect(() => {
    if (!active || !scope) return;
    return dependencies.whenPrepared(scope.root, () => setPreparedRevision((value) => value + 1));
  }, [active, scope, dependencies]);

  useEffect(() => {
    if (!active || !scope) {
      setOwned(null);
      return;
    }
    if (owner !== deferredOwner) return;
    let cancelled = false;
    void dependencies.discover(scope, filePath, source, includeTests)
      .then((sources) => {
        if (!cancelled) setOwned({ filePath, sources, owner });
      })
      .catch((error) => {
        if (cancelled) return;
        setOwned((current) => (current?.owner === owner ? current : null));
        dependencies.trace("warn", "run.javaRunMarkers", filePath, {
          error: error instanceof Error ? error.message : String(error),
        });
      });
    return () => {
      cancelled = true;
    };
  }, [active, deferredOwner, owner, source, filePath, includeTests, scope, dependencies]);

  useEffect(() => {
    if (!owned || owned.owner !== owner) {
      setProjected(null);
      return;
    }
    let cancelled = false;
    void dependencies.project(owned.sources, testOutcomes)
      .then((markers) => {
        if (!cancelled) setProjected({ owner: owned.owner, markers });
      })
      .catch((error) => {
        if (cancelled) return;
        dependencies.trace("warn", "run.javaRunMarkers.project", owned.filePath, {
          error: error instanceof Error ? error.message : String(error),
        });
      });
    return () => {
      cancelled = true;
    };
  }, [owned, owner, testOutcomes, dependencies]);

  const testMethods = useMemo(
    () => (owned ? javaTestMethodsFromItems(owned.sources.testItems) : []),
    [owned],
  );

  if (!active || owned?.owner !== owner) return EMPTY_STATE;
  return {
    markers: projected?.owner === owner ? projected.markers : [],
    testMethods,
  };
}
