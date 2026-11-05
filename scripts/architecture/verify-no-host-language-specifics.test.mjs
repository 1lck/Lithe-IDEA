import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  ALLOWLIST_PATH,
  BASELINE_PATH,
  globToRegExp,
  listedWords,
  nameComparisons,
  scanText,
  schemaEnums,
  stripComments,
  toolTables,
  verify,
} from "./verify-no-host-language-specifics.mjs";

// Fixture repositories live in their own temporary directory, removed after
// each test whether it passed or failed.
function repository(t, files = {}) {
  const root = mkdtempSync(path.join(tmpdir(), "lithe-language-gate-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  write(root, files);
  return root;
}

function write(root, files) {
  for (const [file, content] of Object.entries(files)) {
    const absolute = path.join(root, file);
    mkdirSync(path.dirname(absolute), { recursive: true });
    writeFileSync(absolute, typeof content === "string" ? content : JSON.stringify(content, null, 2));
  }
}

const run = (root, ...args) => verify(["--root", root, ...args]);
const output = (result) => [...result.stdout, ...result.stderr].join("\n");

function allowlistEntry(overrides = {}) {
  return {
    glob: "windows/tauri/src/features/maven/**",
    reason: "Windows Maven pane served by the legacy crate",
    issue: "#1495",
    removeWhen: "Windows installs the Maven plugin",
    ...overrides,
  };
}

function git(root, ...args) {
  return execFileSync("git", [
    "-c", "user.name=Lithe Test",
    "-c", "user.email=test@example.invalid",
    "-c", "commit.gpgsign=false",
    "-c", "init.defaultBranch=main",
    "-C", root, ...args,
  ], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 10_000 });
}

function commitAll(root, message) {
  git(root, "add", "-A");
  git(root, "commit", "-q", "-m", message);
}

test("words split on case, separators and digits; JavaScript is one neutral word", { timeout: 1000 }, () => {
  assert.deepEqual(listedWords("mavenJavaHomePath"), ["maven", "java"]);
  assert.deepEqual(listedWords("JDT_LS jdtls lithe-java-run dev.lithe.plugin.java-support"), ["jdt", "jdtls", "java", "java"]);
  assert.deepEqual(listedWords("JUnitRunner MyBatisMapper TestNGSuite m2eProject SpringBoot"), ["junit", "mybatis", "testng", "m2e", "spring"]);
  assert.deepEqual(listedWords("JavaScript javascript javaScriptLanguage TypeScript"), []);
  // Exact words only: longer words that merely start with a listed word do not count.
  assert.deepEqual(listedWords("javac springframework mvnw gradlew Javadoc"), []);
});

test("comments are not counted; strings, raw strings and regex literals are handled", { timeout: 1000 }, () => {
  const rust = [
    "// java in a line comment",
    "/* outer /* nested java */ still a comment */",
    "let tool = \"maven\";",
    "let raw = r#\"gradle \"quoted\"\"#;",
    "fn f<'a>(value: &'a str) -> char { 'j' }",
  ].join("\n");
  assert.deepEqual(listedWords(stripComments(rust, "rust")), ["maven", "gradle"]);
  const swift = [
    "/// java documentation",
    "let url = \"https://example.invalid/// java\"",
    "let text = #\"\"\"",
    "  junit inside a raw multiline string",
    "  \"\"\"#",
  ].join("\n");
  assert.deepEqual(listedWords(stripComments(swift, "swift")), ["java", "junit"]);
  const script = [
    "const pattern = /\"[^\"]*\"/; // spring",
    "const label = `gradle ${name}`;",
    "/* mybatis */ const id = 'jdt';",
  ].join("\n");
  assert.deepEqual(listedWords(stripComments(script, "script")), ["gradle", "jdt"]);
  const keywordRegex = [
    "function f(s: string) { return /[/*]/.test(s); }",
    "const runtime = \"java\";",
    "const kind = typeof /[*/]/; const tool = 'maven';",
    "const half = options.in / 2; const other = 'gradle'; // spring",
  ].join("\n");
  assert.deepEqual(listedWords(stripComments(keywordRegex, "script")), ["java", "maven", "gradle"],
    "a regex after return or typeof does not open a block comment; `.in /` stays a division");
  const stripped = stripComments("a // java\nb", "rust");
  assert.equal(stripped.split("\n").length, 2, "line breaks survive so line numbers stay stable");
});

test("name comparisons with listed words are counted in Rust, Swift and TypeScript", { timeout: 1000 }, () => {
  const rust = [
    "if provider_id == \"java\" {}",
    "if \"maven\" != tool {}",
    "match kind {",
    "    \"maven\" | \"gradle\" => {}",
    "    Some(\"jdt\") => {}",
    "    \"python\" => {}",
    "    \"python\" | \"jvm\" | \"node\" => {}",
    "    _ => {}",
    "}",
    "if id.eq_ignore_ascii_case(\"JUnit\") {}",
    "let known = matches!(tool, \"node\" | \"java\");",
    "if tool == \"node\" {}",
  ].join("\n");
  assert.equal(nameComparisons(stripComments(rust, "rust"), "rust"), 7);
  const swift = [
    "switch descriptor.id {",
    "case \"java\": break",
    "case \"swift\", \"maven\": break",
    "default: break",
    "}",
    "guard descriptor.id == \"java\" else { return }",
  ].join("\n");
  assert.equal(nameComparisons(stripComments(swift, "swift"), "swift"), 3);
  const script = "if (languageId === 'gradle') {}\nswitch (id) { case \"maven\": break; case `typescript`: break }\nif (id !== \"javascript\") {}";
  assert.equal(nameComparisons(stripComments(script, "script"), "script"), 2);
});

test("a match arm scan stays linear on large files", { timeout: 5000 }, () => {
  // Blank lines left by stripped comments once made a multiline anchor backtrack quadratically.
  const code = `${"\n".repeat(20_000)}${"let value = \"java\";\n".repeat(2_000)}`;
  const started = performance.now();
  nameComparisons(code, "rust");
  assert.ok(performance.now() - started < 2_000, "the scan must finish well inside the test budget");
});

test("every entry of a Rust string table naming a language or tool is counted", { timeout: 1000 }, () => {
  const code = [
    "const KNOWN_RUNTIME_TOOLS: &[&str] = &[\"go\", \"node\"];",
    "pub(crate) const LAUNCH: &'static [&'static str] = &[\"java\"];",
    "static IGNORED: [&str; 2] = [\".gradle\", \"target\"];",
    "const ARCHITECTURES: &[&str] = &[\"arm64\", \"x86_64\"];",
  ].join("\n");
  assert.equal(toolTables(code), 5);
  const grown = code.replace("&[\"go\", \"node\"]", "&[\"go\", \"node\", \"python\"]");
  assert.equal(toolTables(grown), 6, "adding a tool to an existing table raises the count");
});

test("schema rules count the members of closed tool, runtime and import enums and of every hostIntegration", { timeout: 1000 }, () => {
  const schema = {
    properties: {
      launch: { properties: { tool: { enum: ["java", "node"] }, runtime: { oneOf: [{ const: "java" }] } } },
      languageImport: { properties: { kind: { enum: ["maven", "gradle"] } } },
      other: { properties: { kind: { enum: ["file", "folder"] } } },
      model: { properties: { hostIntegration: { type: "string" } } },
      server: { properties: { hostIntegration: { type: "object", properties: { id: { enum: ["jdt"] }, capabilities: { items: { enum: ["run", "debug"] } } } } } },
      build: { properties: { hostIntegration: { enum: ["maven"] } } },
      open: { properties: { tool: { type: "string", pattern: "^[a-z]+$" } } },
    },
  };
  // tool 2 + runtime 1 + kind 2 + one per hostIntegration; the object form counts its id values only.
  assert.equal(schemaEnums(schema), 8);
  const grown = structuredClone(schema);
  grown.properties.launch.properties.tool.enum.push("python");
  grown.properties.server.properties.hostIntegration.properties.id.enum.push("pyright");
  assert.equal(schemaEnums(grown), 10, "adding a member to an existing enum raises the count");
  const { counts } = scanText("shared/contracts/plugins/v1/plugin-manifest.schema.json", JSON.stringify(schema));
  assert.equal(counts.schemaEnums, 8);
  assert.equal(scanText("shared/contracts/plugins/v1/fixtures/example.json", JSON.stringify(schema)).counts.schemaEnums, undefined);
});

test("JavaScript names in host code are not reported", { timeout: 1000 }, (t) => {
  const root = repository(t, {
    "frontend/editor/src/language.ts": "export const id = languageId === \"javascript\" ? \"JavaScript\" : \"typescript\";\n",
  });
  const update = run(root, "--update-baseline");
  assert.equal(update.code, 0, output(update));
  assert.deepEqual(JSON.parse(readFileSync(path.join(root, BASELINE_PATH), "utf8")).files, {});
  assert.equal(run(root, "--strict").code, 0);
});

test("vendor, node_modules and hidden directories are not scanned", { timeout: 1000 }, (t) => {
  const root = repository(t, {
    "macos/Sources/Lithe/Resources/MarkdownPreview/vendor/plantuml/java.js": "const java = 'java';\n",
    "frontend/editor/src/node_modules/maven/index.js": "export const maven = 'maven';\n",
    "windows/tauri/src/.cache/gradle.ts": "export const gradle = 'gradle';\n",
    "rust/lithe-core/src/lib.rs": "pub fn generic() {}\n",
  });
  const result = run(root, "--strict");
  assert.equal(result.code, 0, output(result));
});

test("allowlist entries need glob, reason, issue and removeWhen, and must still match a file", { timeout: 1000 }, (t) => {
  const files = { "windows/tauri/src/features/maven/maven.store.ts": "export const maven = true;\n" };
  const cases = [
    [{ issue: undefined }, /missing "issue"/],
    [{ issue: "1495" }, /"issue" must look like #1495/],
    [{ removeWhen: " " }, /missing "removeWhen"/],
    [{ owner: "someone" }, /unknown key "owner"/],
    [{ glob: "windows/tauri/src/{features/{maven},other}/**" }, /nested "\{" is not supported/],
    [{ glob: "windows/tauri/src/features/gradle/**" }, /matches no file with language names; remove the entry/],
  ];
  for (const [overrides, pattern] of cases) {
    const root = repository(t, files);
    const entry = allowlistEntry(overrides);
    for (const key of Object.keys(entry)) if (entry[key] === undefined) delete entry[key];
    write(root, { [ALLOWLIST_PATH]: { entries: [entry] } });
    const result = run(root, "--strict");
    assert.equal(result.code, 1, JSON.stringify(overrides));
    assert.match(output(result), pattern);
  }
  const root = repository(t, files);
  write(root, { [ALLOWLIST_PATH]: { entries: [allowlistEntry()] } });
  const result = run(root, "--strict");
  assert.equal(result.code, 0, output(result));
  assert.match(output(result), /1 allowlisted files not counted/);
});

test("retired scanner tokens fail in every mode, even in allowlisted files", { timeout: 1000 }, (t) => {
  const root = repository(t, {
    "windows/tauri/src/features/maven/maven.store.ts": "// containsJavaMainMethod\nexport const maven = true;\n",
    [ALLOWLIST_PATH]: { entries: [allowlistEntry()] },
  });
  for (const args of [["--strict"], ["--update-baseline"], []]) {
    const result = run(root, ...args);
    assert.equal(result.code, 1, args.join(" "));
    assert.match(output(result), /maven\.store\.ts:1: containsJavaMainMethod/);
  }
  assert.equal(existsSync(path.join(root, BASELINE_PATH)), false, "a failing update must not write the baseline");
});

test("the ratchet rejects increases, new files and unrecorded decreases", { timeout: 1000 }, (t) => {
  const root = repository(t, {
    "rust/lithe-core/src/run.rs": "fn run() { let tool = \"java\"; let other = \"maven\"; }\n",
  });
  assert.equal(run(root).code, 1, "a missing baseline fails outside --update-baseline");
  assert.equal(run(root, "--update-baseline").code, 0);
  assert.deepEqual(JSON.parse(readFileSync(path.join(root, BASELINE_PATH), "utf8")).files, { "rust/lithe-core/src/run.rs": { words: 2 } });
  assert.equal(run(root).code, 0);

  write(root, { "rust/lithe-core/src/run.rs": "fn run() { let tool = \"java\"; let other = \"maven\"; let third = \"gradle\"; }\n" });
  let result = run(root);
  assert.equal(result.code, 1);
  assert.match(output(result), /rust\/lithe-core\/src\/run\.rs: words 2 -> 3/);
  result = run(root, "--update-baseline");
  assert.equal(result.code, 1, "the baseline only goes down");
  assert.match(output(result), /only goes down/);

  write(root, {
    "rust/lithe-core/src/run.rs": "fn run() { let tool = \"java\"; let other = \"maven\"; }\n",
    "macos/Sources/Lithe/Run.swift": "let tool = \"gradle\"\n",
  });
  result = run(root);
  assert.equal(result.code, 1);
  assert.match(output(result), /macos\/Sources\/Lithe\/Run\.swift: words 0 -> 1 \(new file\)/);
  rmSync(path.join(root, "macos"), { recursive: true });

  write(root, { "rust/lithe-core/src/run.rs": "fn run() { let tool = \"java\"; }\n" });
  result = run(root);
  assert.equal(result.code, 1, "a decrease must be recorded");
  assert.match(output(result), /run\.rs: words 2 -> 1/);
  assert.match(output(result), /--update-baseline/);
  result = run(root, "--update-baseline");
  assert.equal(result.code, 0, output(result));
  assert.match(output(result), /1 counts lowered/);
  assert.equal(run(root).code, 0);
});

test("the ratchet catches a regex after return and a tool added to existing closed lists", { timeout: 1000 }, (t) => {
  const root = repository(t, {
    "rust/lithe-core/src/tools.rs": "const KNOWN_RUNTIME_TOOLS: &[&str] = &[\"go\", \"node\"];\n",
    "shared/contracts/plugins/v1/plugin-manifest.schema.json": { properties: { launch: { properties: { tool: { enum: ["java", "node"] } } } } },
  });
  assert.equal(run(root, "--update-baseline").code, 0);
  write(root, {
    "frontend/editor/src/pattern.ts": "function f(s: string) { return /[/*]/.test(s); }\nconst runtime = \"java\";\n",
    "rust/lithe-core/src/tools.rs": "const KNOWN_RUNTIME_TOOLS: &[&str] = &[\"go\", \"node\", \"python\"];\n",
    "shared/contracts/plugins/v1/plugin-manifest.schema.json": { properties: { launch: { properties: { tool: { enum: ["java", "node", "python"] } } } } },
  });
  const result = run(root);
  assert.equal(result.code, 1);
  assert.match(output(result), /frontend\/editor\/src\/pattern\.ts: words 0 -> 1 \(new file\)/);
  assert.match(output(result), /tools\.rs: toolTables 2 -> 3/);
  assert.match(output(result), /plugin-manifest\.schema\.json: schemaEnums 2 -> 3/);
});

test("strict mode reports every counted file", { timeout: 1000 }, (t) => {
  const root = repository(t, {
    "rust/lithe-core/src/run.rs": "fn run() { if tool == \"java\" {} }\n",
    "shared/contracts/plugins/v1/plugin-manifest.schema.json": { properties: { hostIntegration: { type: "string" } } },
  });
  const result = run(root, "--strict");
  assert.equal(result.code, 1);
  assert.match(output(result), /rust\/lithe-core\/src\/run\.rs: words=1, nameComparisons=1/);
  assert.match(output(result), /plugin-manifest\.schema\.json: schemaEnums=1/);
});

test("--base rejects a baseline that grew or an allowlist that gained entries", { timeout: 15_000 }, (t) => {
  const root = repository(t, {
    "rust/lithe-core/src/run.rs": "fn run() { let tool = \"java\"; }\n",
    "windows/tauri/src/features/maven/maven.store.ts": "export const maven = true;\n",
    [ALLOWLIST_PATH]: { entries: [allowlistEntry()] },
  });
  git(root, "init", "-q");
  let result = run(root, "--update-baseline");
  assert.equal(result.code, 0, output(result));
  commitAll(root, "base");

  result = run(root, "--base", "HEAD");
  assert.equal(result.code, 0, output(result));

  // Hand-editing the baseline upward passes the local ratchet but not the base check.
  write(root, { "rust/lithe-core/src/run.rs": "fn run() { let tool = \"java\"; let other = \"jvm\"; }\n" });
  const baseline = JSON.parse(readFileSync(path.join(root, BASELINE_PATH), "utf8"));
  baseline.files["rust/lithe-core/src/run.rs"].words = 2;
  write(root, { [BASELINE_PATH]: baseline });
  assert.equal(run(root).code, 0);
  result = run(root, "--base", "HEAD");
  assert.equal(result.code, 1);
  assert.match(output(result), /grew compared with HEAD/);
  assert.match(output(result), /run\.rs: words 1 -> 2/);

  git(root, "checkout", "-q", "--", ".");
  write(root, {
    "windows/tauri/src/features/gradle/gradle.store.ts": "export const gradle = true;\n",
    [ALLOWLIST_PATH]: { entries: [allowlistEntry(), allowlistEntry({ glob: "windows/tauri/src/features/gradle/**" })] },
  });
  result = run(root, "--base", "HEAD");
  assert.equal(result.code, 1);
  assert.match(output(result), /gained entries compared with HEAD/);
  assert.match(output(result), /features\/gradle\/\*\*/);
});

test("--base skips the comparison when the base has no baseline and rejects unknown refs", { timeout: 15_000 }, (t) => {
  const root = repository(t, { "rust/lithe-core/src/lib.rs": "pub fn generic() {}\n" });
  git(root, "init", "-q");
  commitAll(root, "before the gate");
  assert.equal(run(root, "--update-baseline").code, 0);
  let result = run(root, "--base", "HEAD");
  assert.equal(result.code, 0, output(result));
  assert.match(output(result), /HEAD has no .*; skipped the base comparison/);
  result = run(root, "--base", "no-such-ref");
  assert.equal(result.code, 1);
  assert.match(output(result), /--base no-such-ref is not a commit/);
});

test("invalid arguments exit with usage code 2", { timeout: 1000 }, (t) => {
  const root = repository(t);
  for (const args of [["--unknown"], ["--strict", "--update-baseline"], ["--base"], ["--base", "--strict"]]) {
    const result = run(root, ...args);
    assert.equal(result.code, 2, args.join(" "));
    assert.match(output(result), /Usage:/);
  }
});

test("globs support **, * and unnested braces", { timeout: 1000 }, () => {
  const pattern = globToRegExp("windows/tauri/src/features/**/java-run-markers{,.test}.ts");
  assert.ok(pattern.test("windows/tauri/src/features/run/services/java-run-markers.ts"));
  assert.ok(pattern.test("windows/tauri/src/features/editor/engines/monaco/java-run-markers.test.ts"));
  assert.ok(!pattern.test("windows/tauri/src/features/run/services/java-run-markers.spec.ts"));
  assert.ok(globToRegExp("frontend/editor/src/textmate*.ts").test("frontend/editor/src/textmate-grammar.ts"));
  assert.ok(!globToRegExp("frontend/editor/src/textmate*.ts").test("frontend/editor/src/nested/textmate.ts"));
});
