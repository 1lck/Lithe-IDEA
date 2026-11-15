// Validates the two pins the desktop build depends on, before any lane spends time on a build
// that cannot resolve them: the viva replacement in desktop/go.mod and the core revision in
// scripts/desktop/build-desktop-core.sh. A pin that was force-pushed away, typed wrong, or points
// at a branch that does not carry the commit fails here in a minute instead of in a cold core
// build half an hour later.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const problems = [];

const pseudoVersion = /^v\d+\.\d+\.\d+-0\.\d{14}-([0-9a-f]{12})$/;
const revision = /^[0-9a-f]{40}$/;

// The viva replacement, as desktop/go.mod states it.
const gomod = readFileSync(join(root, "desktop/go.mod"), "utf8");
const replaceLine = gomod.split("\n").find((line) => line.startsWith("replace github.com/vivaui/viva =>"));
if (!replaceLine) {
  problems.push("desktop/go.mod has no replace for github.com/vivaui/viva");
}
let vivaVersion = "";
if (replaceLine) {
  vivaVersion = replaceLine.trim().split(/\s+/).pop();
  if (!pseudoVersion.test(vivaVersion)) {
    problems.push(`the viva replacement ${vivaVersion} is not a pseudo-version of a commit`);
  }
}

// The core revision, as build-desktop-core.sh states it.
const coreScript = readFileSync(join(root, "scripts/desktop/build-desktop-core.sh"), "utf8");
const pinMatch = coreScript.match(/^PINNED_CORE_REVISION="([^"]+)"/m);
if (!pinMatch) {
  problems.push("scripts/desktop/build-desktop-core.sh has no PINNED_CORE_REVISION");
}
const corePin = pinMatch ? pinMatch[1] : "";
if (pinMatch && !revision.test(corePin)) {
  problems.push(`the core pin ${corePin} is not a 40 character lowercase revision`);
}

// The viva commit must resolve from the module source the build reads.
if (vivaVersion && pseudoVersion.test(vivaVersion)) {
  try {
    execFileSync("go", ["list", "-m", "-json", `github.com/Lithe-IDEA/viva@${vivaVersion}`], {
      cwd: join(root, "desktop"),
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, GOFLAGS: "-mod=mod" },
    });
    console.log(`viva ${vivaVersion} resolves`);
  } catch (error) {
    problems.push(`the viva replacement ${vivaVersion} does not resolve: ${error.stderr?.toString().trim() || error.message}`);
  }
}

// The core commit must be fetchable from its repository; a commit that is not reachable by its
// revision means a rewrite or a typo, and the cold core build would fail on the same lookup.
if (revision.test(corePin)) {
  const scratch = mkdtempSync(join(tmpdir(), "lithe-pins-"));
  try {
    execFileSync("git", ["init", "--quiet", scratch], { stdio: "ignore" });
    execFileSync(
      "git",
      ["-C", scratch, "-c", "protocol.version=2", "fetch", "--quiet", "--depth=1", "--filter=blob:none",
        "https://github.com/Lithe-IDEA/Lithe-core-rust.git", corePin],
      { stdio: ["ignore", "pipe", "pipe"] },
    );
    console.log(`core ${corePin} is reachable`);
  } catch (error) {
    problems.push(`the core pin ${corePin} is not fetchable: ${error.stderr?.toString().trim() || error.message}`);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

if (problems.length > 0) {
  for (const problem of problems) console.error(`pin check: ${problem}`);
  process.exit(1);
}
console.log("pins are valid and reachable");
