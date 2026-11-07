import { expect, test } from "bun:test";
import {
  GeneratorFormSession,
  canReview,
  emptyForm,
  enumPresentation,
  pluginActions,
  type EvaluatedForm,
  type GeneratorEntry,
  type GeneratorFormPort,
  type GeneratorFormState,
} from "./generator-form-session";

const entry = (id = "app", enabled = true, identity = "digest-a"): GeneratorEntry => ({
  pluginID: "fixture.generator",
  pluginName: "Fixture Generator",
  pluginEnabled: enabled,
  packageIdentity: identity,
  canEnable: true,
  generator: { id, displayName: id, section: "project", fields: [] },
  requirements: [
    {
      languageID: "java",
      providers: [
        {
          pluginID: "fixture.generator",
          pluginName: "Fixture Generator",
          enabled,
          canEnable: true,
        },
      ],
    },
    {
      buildSystemID: "maven",
      providers: [
        { pluginID: "fixture.maven", pluginName: "Maven", enabled: false, canEnable: true },
      ],
    },
    { buildSystemID: "gradle", providers: [] },
  ],
});
const evaluated = (owner: GeneratorEntry, active: number[] = [0]): EvaluatedForm => ({
  valid: true,
  packageIdentity: owner.packageIdentity,
  projectName: {},
  fields: [],
  activeRequirements: active,
});
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}
function fixture(overrides: Partial<GeneratorFormPort> = {}) {
  const snapshots: GeneratorFormState[] = [];
  const port: GeneratorFormPort = {
    catalog: async () => [entry()],
    evaluate: async (owner) => evaluated(owner),
    enable: async () => {},
    ...overrides,
  };
  const session = new GeneratorFormSession(port, (state) => snapshots.push(state));
  return { session, snapshots };
}

test("conditional requirements use only Core active indices and never block an enabled generator", async () => {
  let active = [0];
  const { session } = fixture({ evaluate: async (owner) => evaluated(owner, active) });
  try {
    await session.reload();
    await session.choose(session.state.entries[0]);
    expect(pluginActions(session.state)).toEqual([]);
    active = [0, 1, 2];
    await session.update({ ...emptyForm(), values: { buildSystem: "anything-Core-understands" } });
    expect(pluginActions(session.state)).toEqual([
      { kind: "enable", pluginID: "fixture.maven", name: "Maven" },
      { kind: "marketplace", query: "gradle" },
    ]);
    expect(canReview(session.state)).toBe(true);
    active = [0];
    await session.update(emptyForm());
    expect(pluginActions(session.state)).toEqual([]);
  } finally {
    session.dispose();
  }
}, 1000);

test("disabled generators remain selectable and enable by explicit native action before refreshing", async () => {
  let enabled = false;
  let scans = 0;
  const enabledCalls: string[] = [];
  const { session } = fixture({
    catalog: async () => {
      ++scans;
      return [entry("app", enabled)];
    },
    enable: async (id) => {
      enabledCalls.push(id);
      enabled = true;
    },
  });
  try {
    await session.reload();
    await session.choose(session.state.entries[0]);
    await session.update({
      ...emptyForm(),
      projectName: "Draft",
      values: { group: "keep.me" },
      edited: ["group"],
    });
    expect(canReview(session.state)).toBe(false);
    expect(pluginActions(session.state)).toEqual([
      { kind: "enable", pluginID: "fixture.generator", name: "Fixture Generator" },
    ]);
    await session.enable("fixture.generator");
    expect(enabledCalls).toEqual(["fixture.generator"]);
    expect(scans).toBe(2);
    expect(canReview(session.state)).toBe(true);
    expect(session.state.form.projectName).toBe("Draft");
    expect(session.state.form.values.group).toBe("keep.me");
  } finally {
    session.dispose();
  }
}, 1000);

test.each(["rejected by trust policy", "native enable failed"])(
  "enable failure %s retains disabled state and draft",
  async (message) => {
    const { session } = fixture({
      catalog: async () => [entry("app", false)],
      enable: async () => {
        throw new Error(message);
      },
    });
    try {
      await session.reload();
      await session.choose(session.state.entries[0]);
      await session.update({ ...emptyForm(), projectName: "Keep" });
      await session.enable("fixture.generator");
      expect(session.state.selected?.pluginEnabled).toBe(false);
      expect(canReview(session.state)).toBe(false);
      expect((session.state.error as Error).message).toBe("generator.pluginEnableFailed");
      expect(session.state.form.projectName).toBe("Keep");
    } finally {
      session.dispose();
    }
  },
  1000,
);

test("enable success is not synthesized when the fresh native catalog still says disabled", async () => {
  const { session } = fixture({ catalog: async () => [entry("app", false)] });
  try {
    await session.reload();
    await session.choose(session.state.entries[0]);
    await session.enable("fixture.generator");
    expect(canReview(session.state)).toBe(false);
  } finally {
    session.dispose();
  }
}, 1000);

test("switching generators during enable drops its late reload and keeps separate drafts", async () => {
  const enabled = deferred<void>();
  let scans = 0;
  const { session } = fixture({
    catalog: async () => {
      ++scans;
      return [entry("app", false), entry("other")];
    },
    enable: () => enabled.promise,
  });
  let pending: Promise<void> | undefined;
  try {
    await session.reload();
    const [first, second] = session.state.entries;
    await session.choose(first);
    await session.update({ ...emptyForm(), projectName: "First" });
    pending = session.enable("fixture.generator");
    await session.choose(second);
    await session.update({ ...emptyForm(), projectName: "Second" });
    enabled.resolve();
    await pending;
    expect(scans).toBe(1);
    expect(session.state.selected?.generator.id).toBe("other");
    expect(session.state.form.projectName).toBe("Second");
    await session.choose(first);
    expect(session.state.form.projectName).toBe("First");
  } finally {
    enabled.resolve();
    await pending;
    session.dispose();
  }
}, 1000);

test("close during enable and form evaluation never publishes a late result", async () => {
  const enabled = deferred<void>();
  let scans = 0;
  const { session, snapshots } = fixture({
    catalog: async () => {
      ++scans;
      return [entry("app", false)];
    },
    enable: () => enabled.promise,
  });
  await session.reload();
  await session.choose(session.state.entries[0]);
  const pending = session.enable("fixture.generator");
  session.dispose();
  const count = snapshots.length;
  enabled.resolve();
  await pending;
  expect(snapshots.length).toBe(count);
  expect(scans).toBe(1);
  const evaluation = deferred<EvaluatedForm>();
  const another = fixture({ evaluate: () => evaluation.promise });
  await another.session.reload();
  const choosing = another.session.choose(another.session.state.entries[0]);
  another.session.dispose();
  const before = another.snapshots.length;
  evaluation.resolve(evaluated(entry()));
  await choosing;
  expect(another.snapshots.length).toBe(before);
}, 1000);

test("same-version package replacement clears its draft and rejects an old form identity", async () => {
  let identity = "digest-a";
  const { session } = fixture({ catalog: async () => [entry("app", true, identity)] });
  try {
    await session.reload();
    await session.choose(session.state.entries[0]);
    await session.update({ ...emptyForm(), projectName: "Old draft" });
    identity = "digest-b";
    await session.reload();
    expect(session.state.form.projectName).toBe("");
    expect(session.state.selected?.packageIdentity).toBe("digest-b");
  } finally {
    session.dispose();
  }
  const stale = fixture({ evaluate: async () => evaluated(entry("app", true, "old-digest")) });
  try {
    await stale.session.reload();
    await stale.session.choose(stale.session.state.entries[0]);
    expect(canReview(stale.session.state)).toBe(false);
    expect((stale.session.state.error as Error).message).toBe("generator.stale");
  } finally {
    stale.session.dispose();
  }
}, 1000);

test("Core failure disables creation and stale evaluation cannot replace a newer field edit", async () => {
  const old = deferred<EvaluatedForm>();
  let calls = 0;
  const { session } = fixture({
    evaluate: (owner) => (++calls === 1 ? old.promise : Promise.resolve(evaluated(owner, [2]))),
  });
  await session.reload();
  const first = session.choose(session.state.entries[0]);
  try {
    await session.update({ ...emptyForm(), projectName: "Latest" });
    old.resolve(evaluated(entry(), [1]));
    await first;
    expect(session.state.evaluation?.activeRequirements).toEqual([2]);
    expect(session.state.form.projectName).toBe("Latest");
  } finally {
    old.resolve(evaluated(entry()));
    await first;
    session.dispose();
  }
  const failed = fixture({
    evaluate: async () => {
      throw new Error("Core rejected");
    },
  });
  try {
    await failed.session.reload();
    await failed.session.choose(failed.session.state.entries[0]);
    expect(canReview(failed.session.state)).toBe(false);
  } finally {
    failed.session.dispose();
  }
}, 1000);

test("only declared enum presentation uses segmented and unapproved enable requests do nothing", async () => {
  expect(
    enumPresentation({ id: "build", type: "enum", title: "Build", presentation: "segmented" }),
  ).toBe("segmented");
  expect(enumPresentation({ id: "build", type: "enum", title: "Build" })).toBe("menu");
  expect(
    enumPresentation({ id: "text", type: "text", title: "Text", presentation: "segmented" }),
  ).toBe("menu");
  let calls = 0;
  const { session } = fixture({
    enable: async () => {
      ++calls;
    },
  });
  try {
    await session.reload();
    await session.choose(session.state.entries[0]);
    await session.enable("arbitrary.unaccepted.plugin");
    expect(calls).toBe(0);
  } finally {
    session.dispose();
  }
}, 1000);

test("a failed advisory provider enable still refreshes and permits creation from a valid form", async () => {
  let scans = 0;
  const { session } = fixture({
    catalog: async () => {
      ++scans;
      return [entry()];
    },
    evaluate: async (owner) => evaluated(owner, [1]),
    enable: async () => {
      throw new Error("denied");
    },
  });
  try {
    await session.reload();
    await session.choose(session.state.entries[0]);
    await session.enable("fixture.maven");
    expect(scans).toBe(2);
    expect((session.state.error as Error).message).toBe("generator.pluginEnableFailed");
    expect(canReview(session.state)).toBe(true);
  } finally {
    session.dispose();
  }
}, 1000);

test("a failed refresh after switching entries leaves loading and permits an explicit retry", async () => {
  const catalog = deferred<GeneratorEntry[]>();
  let scans = 0;
  const { session } = fixture({
    catalog: () => (++scans === 2 ? catalog.promise : Promise.resolve([entry(), entry("other")])),
  });
  let refreshing: Promise<number | undefined> | undefined;
  try {
    await session.reload();
    await session.choose(session.state.entries[0]);
    refreshing = session.reload();
    await session.choose(session.state.entries[1]);
    await session.update({ ...emptyForm(), projectName: "Keep other" });
    catalog.reject(new Error("fixture catalog unavailable"));
    await refreshing;
    expect(session.state.loading).toBe(false);
    expect(session.state.selected?.generator.id).toBe("other");
    expect(session.state.form.projectName).toBe("Keep other");
    expect(canReview(session.state)).toBe(false);
    await session.reload();
    expect(canReview(session.state)).toBe(true);
    expect(session.state.form.projectName).toBe("Keep other");
  } finally {
    catalog.resolve([]);
    await refreshing;
    session.dispose();
  }
}, 1000);

test("a refresh reconciles a changed selection with its current package identity", async () => {
  const catalog = deferred<GeneratorEntry[]>();
  let scans = 0;
  const { session } = fixture({
    catalog: () => (++scans === 1 ? Promise.resolve([entry(), entry("other")]) : catalog.promise),
  });
  let refreshing: Promise<number | undefined> | undefined;
  try {
    await session.reload();
    await session.choose(session.state.entries[0]);
    refreshing = session.reload();
    await session.choose(session.state.entries[1]);
    await session.update({ ...emptyForm(), projectName: "Old package draft" });
    catalog.resolve([entry(), entry("other", true, "replacement-digest")]);
    await refreshing;
    expect(session.state.loading).toBe(false);
    expect(session.state.selected?.generator.id).toBe("other");
    expect(session.state.selected?.packageIdentity).toBe("replacement-digest");
    expect(session.state.evaluation?.packageIdentity).toBe("replacement-digest");
    expect(session.state.form.projectName).toBe("");
  } finally {
    catalog.resolve([]);
    await refreshing;
    session.dispose();
  }
}, 1000);
