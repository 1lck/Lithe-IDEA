#!/usr/bin/env node
// A green matrix is insufficient if a shard was omitted or selected no cases.
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export function verifyRustShards(reports) {
  if (!reports.length) throw new Error('No Rust shard reports');
  const count = reports[0].selection?.shardCount;
  if (!Number.isInteger(count) || count < 1 || reports.length !== count) throw new Error('Missing Rust shards');
  const inventory = new Set(reports[0].inventory);
  if (!inventory.size) throw new Error('Empty Rust test inventory');
  const indices = new Set();
  const executed = new Set();
  for (const report of reports) {
    const selection = report.selection;
    if (selection?.shardCount !== count || selection.testPrefix ||
        !Number.isInteger(selection.shardIndex) || selection.shardIndex < 1 || selection.shardIndex > count ||
        indices.has(selection.shardIndex)) throw new Error('Invalid or duplicate Rust shard');
    indices.add(selection.shardIndex);
    if (report.inventory?.length !== inventory.size || !report.inventory.every(id => inventory.has(id))) throw new Error('Rust shards discovered different tests');
    if (report.suite?.timedOut || !report.tests?.length) throw new Error('Incomplete Rust shard');
    for (const test of report.tests) {
      const id = `${test.target}::${test.name}`;
      if (!inventory.has(id) || executed.has(id)) throw new Error(`Unexpected or duplicate Rust test: ${id}`);
      if (!['passed', 'skipped'].includes(test.status) || test.durationMs >= (test.maxMs ?? report.maxMs)) throw new Error(`Failed Rust test: ${id}`);
      executed.add(id);
    }
  }
  if (executed.size !== inventory.size) throw new Error(`Incomplete Rust coverage: ${executed.size}/${inventory.size}`);
  return executed.size;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const count = verifyRustShards(process.argv.slice(2).map(file => JSON.parse(readFileSync(file, 'utf8'))));
  console.log(`All ${count} Rust cases accounted for exactly once across shards.`);
}
