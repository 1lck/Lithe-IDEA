export interface BuildDiagnostic {
  path: string; line: number; column?: number; severity: "error" | "warning" | "information" | "hint"; message: string;
}
export interface BuildTestCase {
  project?: string; suite: string; case: string; status: "passed" | "failed" | "error" | "skipped";
  message?: string; durationMillis?: number; path?: string; line?: number; invocations: number;
}
export interface BuildTestResults {
  tests: BuildTestCase[];
  summary: { total: number; passed: number; failed: number; errors: number; skipped: number };
  success: boolean;
  coverage?: Array<{ project: string; suite?: string; case?: string }>;
}
export interface BuildTestSelector {
  id: string; suite: string; case: string;
  project?: { id: string; name: string; path: string };
  target?: { id: string; name: string; path: string; projectID?: string };
}
export interface BuildResultDetail { diagnostics: BuildDiagnostic[]; tests?: BuildTestResults }
export interface BuildTestDiscovery { revision: string; tests: BuildTestSelector[] }

const MAX_RECENT_RESULTS = 4;

/** Core owns decoding, aggregation and coverage. This store retains only a
 * few current projections; raw Provider reports and output are never copied. */
export class BuildResultStore {
  private readonly results = new Map<string, { owner: string; value: BuildResultDetail }>();
  private readonly discoveries = new Map<string, BuildTestDiscovery>();
  result(id: string): BuildResultDetail | undefined {
    const value = this.results.get(id)?.value; return value && structuredClone(value);
  }
  discovery(owner: string): BuildTestDiscovery | undefined {
    const value = this.discoveries.get(owner); return value && structuredClone(value);
  }
  remember(id: string, owner: string, value: BuildResultDetail): void {
    this.results.delete(id); this.results.set(id, { owner, value: structuredClone(value) }); this.bound(this.results);
  }
  rememberDiscovery(owner: string, value: BuildTestDiscovery): void {
    this.discoveries.delete(owner); this.discoveries.set(owner, structuredClone(value)); this.bound(this.discoveries);
  }
  forget(owner: string): void {
    for (const [id, result] of this.results) if (result.owner === owner) this.results.delete(id);
    this.discoveries.delete(owner);
  }
  forgetDiscovery(owner: string): void { this.discoveries.delete(owner); }
  forgetDiscoveries(): void { this.discoveries.clear(); }
  clear(): void { this.results.clear(); this.discoveries.clear(); }
  private bound<T>(values: Map<string, T>): void {
    while (values.size > MAX_RECENT_RESULTS) values.delete(values.keys().next().value!);
  }
}
