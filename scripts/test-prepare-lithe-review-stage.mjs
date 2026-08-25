#!/usr/bin/env node

import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
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
    return result.stdout.trim();
}

test("uses deterministic assignments when planner output is missing", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "lithe-review-stage-"));
    const planPath = path.join(directory, "plan.json");
    const source = runStage([
        "ensure-plan",
        "--candidate", path.join(directory, "missing.json"),
        "--output", planPath,
    ]);
    const plan = JSON.parse(await readFile(planPath, "utf8"));

    assert.equal(source, "fallback");
    assert.deepEqual(
        plan.assignments.map((assignment) => assignment.role_id),
        ["correctness", "architecture", "resilience"],
    );
});

test("builds focused and aggregate prompts without trusting intermediate findings", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "lithe-review-stage-"));
    const workersDirectory = path.join(directory, "workers");
    await mkdir(workersDirectory);
    const basePromptPath = path.join(directory, "base.md");
    const planPath = path.join(directory, "plan.json");
    const reviewerPromptPath = path.join(directory, "reviewer.md");
    const aggregatorPromptPath = path.join(directory, "aggregator.md");
    await writeFile(basePromptPath, "Original trusted review instructions.\n");
    await writeFile(planPath, JSON.stringify({
        change_summary: "Changes cancellation.",
        assignments: [
            { role_id: "correctness", focus_paths: ["Sources/Feature.swift"], questions: ["Is cancellation correct?"] },
            { role_id: "architecture", focus_paths: [], questions: [] },
            { role_id: "resilience", focus_paths: [], questions: [] },
        ],
    }));
    await writeFile(path.join(workersDirectory, "correctness.json"), JSON.stringify({
        role_id: "correctness",
        summary: "Candidate issue.",
        findings: [],
    }));

    runStage([
        "reviewer",
        "--base-prompt", basePromptPath,
        "--plan", planPath,
        "--role-id", "correctness",
        "--output", reviewerPromptPath,
    ]);
    runStage([
        "aggregator",
        "--base-prompt", basePromptPath,
        "--plan", planPath,
        "--workers", workersDirectory,
        "--output", aggregatorPromptPath,
    ]);

    const reviewerPrompt = await readFile(reviewerPromptPath, "utf8");
    const aggregatorPrompt = await readFile(aggregatorPromptPath, "utf8");
    assert.match(reviewerPrompt, /正确性与端到端行为/);
    assert.match(reviewerPrompt, /不可信的模型中间结果/);
    assert.match(aggregatorPrompt, /必须重新读取 head\/base/);
    assert.match(aggregatorPrompt, /Candidate issue/);
});

test("publishes a clearly marked partial review when final aggregation fails", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "lithe-review-stage-"));
    const workersDirectory = path.join(directory, "workers");
    const outputPath = path.join(directory, "final.md");
    const githubOutputPath = path.join(directory, "github-output.txt");
    await mkdir(workersDirectory);
    await writeFile(path.join(workersDirectory, "correctness.json"), JSON.stringify({
        role_id: "correctness",
        summary: "Found a regression.",
        findings: [{
            priority: "P1",
            title: "Cancellation result can escape",
            path: "Sources/Feature.swift",
            line: 42,
            evidence: "The completion callback ignores the operation ID.",
            impact: "A stale result can replace current state.",
            suggestion: "Check the operation ID before publishing.",
            confidence: "high",
        }],
    }));

    runStage([
        "finalize",
        "--candidate", path.join(directory, "missing.json"),
        "--workers", workersDirectory,
        "--base-sha", "base1234",
        "--head-sha", "head5678",
        "--output", outputPath,
    ], { GITHUB_OUTPUT: githubOutputPath });

    const markdown = await readFile(outputPath, "utf8");
    const githubOutput = await readFile(githubOutputPath, "utf8");
    assert.match(markdown, /❓ 信息不足/);
    assert.match(markdown, /尚未经过最终 verifier 复核/);
    assert.match(markdown, /Sources\/Feature\.swift:42/);
    assert.match(githubOutput, /review_outcome<<.*\npartial\n/s);
});
