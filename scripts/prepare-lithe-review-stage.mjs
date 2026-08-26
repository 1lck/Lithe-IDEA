#!/usr/bin/env node

import { randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

function argument(name, fallback = "") {
    const index = process.argv.indexOf(`--${name}`);
    return index >= 0 ? process.argv[index + 1] ?? fallback : fallback;
}

function parseObject(rawValue) {
    try {
        const parsed = JSON.parse(rawValue);
        return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : null;
    } catch {
        return null;
    }
}

async function writePrivate(filePath, content) {
    await mkdir(path.dirname(filePath), { recursive: true });
    await writeFile(filePath, content, { mode: 0o600 });
}

async function writeGitHubOutput(name, value) {
    const outputPath = process.env.GITHUB_OUTPUT;
    if (!outputPath) {
        throw new Error("GITHUB_OUTPUT is required");
    }
    const delimiter = `lithe_${randomUUID()}`;
    await writeFile(outputPath, `${name}<<${delimiter}\n${value}\n${delimiter}\n`, { flag: "a" });
}

async function finalizeReview() {
    const candidatePath = argument("candidate");
    const finalPath = argument("output");
    let markdown = "";
    try {
        const candidate = parseObject(await readFile(candidatePath, "utf8"));
        markdown = String(candidate?.review_markdown ?? "").trim();
    } catch {
        // A missing result is expected when the model action fails.
    }

    if (!markdown.startsWith("## Lithe Review")) {
        await writePrivate(finalPath, "Review candidate missing or invalid.\n");
        await writeGitHubOutput("final_message", "");
        await writeGitHubOutput("review_outcome", "failure");
        return;
    }

    await writePrivate(finalPath, `${markdown}\n`);
    await writeGitHubOutput("final_message", markdown);
    await writeGitHubOutput("review_outcome", "success");
}

const command = process.argv[2];
if (command !== "finalize") {
    throw new Error(`Unknown command: ${command || "(missing)"}`);
}
await finalizeReview();
