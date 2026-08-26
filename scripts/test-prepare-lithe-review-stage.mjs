#!/usr/bin/env node

import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const scriptPath = path.resolve("scripts/prepare-lithe-review-stage.mjs");

function runStage(argumentsList, environment = {}) {
    const result = spawnSync(process.execPath, [scriptPath, ...argumentsList], {
        encoding: "utf8",
        env: { ...process.env, ...environment },
    });
    assert.equal(result.status, 0, result.stderr);
}

test("exports a valid single-pass review", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "lithe-review-stage-"));
    const candidatePath = path.join(directory, "candidate.json");
    const outputPath = path.join(directory, "final.md");
    const githubOutputPath = path.join(directory, "github-output.txt");
    await writeFile(candidatePath, JSON.stringify({
        review_markdown: "## Lithe Review\n\n**结论：** ✅ 未发现明确问题\n\nLGTM",
    }));

    runStage([
        "finalize",
        "--candidate", candidatePath,
        "--output", outputPath,
    ], { GITHUB_OUTPUT: githubOutputPath });

    const markdown = await readFile(outputPath, "utf8");
    const githubOutput = await readFile(githubOutputPath, "utf8");
    assert.match(markdown, /LGTM/);
    assert.match(githubOutput, /final_message<<.*## Lithe Review/s);
    assert.match(githubOutput, /review_outcome<<.*\nsuccess\n/s);
});

test("reports failure when the model output is missing or malformed", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "lithe-review-stage-"));
    const outputPath = path.join(directory, "final.md");
    const githubOutputPath = path.join(directory, "github-output.txt");

    runStage([
        "finalize",
        "--candidate", path.join(directory, "missing.json"),
        "--output", outputPath,
    ], { GITHUB_OUTPUT: githubOutputPath });

    const markdown = await readFile(outputPath, "utf8");
    const githubOutput = await readFile(githubOutputPath, "utf8");
    assert.equal(markdown, "Review candidate missing or invalid.\n");
    assert.match(githubOutput, /final_message<<.*\n\n.*\n/s);
    assert.match(githubOutput, /review_outcome<<.*\nfailure\n/s);
});

test("workflow uses one model call and publishes after review failure or timeout", async () => {
    const workflow = await readFile(".github/workflows/lithe-pr-review.yml", "utf8");
    const codexActionCalls = workflow.match(/uses: openai\/codex-action@v1/g) ?? [];

    assert.equal(codexActionCalls.length, 1);
    assert.doesNotMatch(workflow, /^  (planner|reviewers|aggregate):/m);
    assert.match(workflow, /group: lithe-pr-review-.*needs\.prepare\.outputs\.head_sha/);
    assert.match(workflow, /publish:\n[\s\S]*?if: >-\n\s+always\(\)/);
});

test("review prompt enforces high-signal findings and bounded searches", async () => {
    const prompt = await readFile(".github/lithe-review/review-prompt.md", "utf8");

    assert.match(prompt, /低于 80\/100 时不要报告/);
    assert.match(prompt, /不得运行无路径限制、无 glob 限制的全仓库/);
    assert.match(prompt, /--max-filesize 1M --max-columns 240/);
    assert.match(prompt, /LGTM/);
});
