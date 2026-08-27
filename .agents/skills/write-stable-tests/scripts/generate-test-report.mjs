#!/usr/bin/env node

import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const REPOSITORY_ROOT = path.resolve(SCRIPT_DIRECTORY, "../../../..");
const FAILURE_STATUSES = new Set(["failed", "error", "timeout", "incomplete"]);

function escapeHTML(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function escapeXML(value) {
  return escapeHTML(value);
}

function formatDuration(milliseconds) {
  if (!Number.isFinite(milliseconds)) return "—";
  if (milliseconds < 1000) return `${Math.round(milliseconds)} ms`;
  if (milliseconds < 60000) return `${(milliseconds / 1000).toFixed(2)} s`;
  return `${(milliseconds / 60000).toFixed(1)} min`;
}

function reportLabel(report) {
  if (report.runner === "swift") return "macOS · Swift";
  if (report.runner === "bun") return "Windows · Frontend";
  if (report.runner === "rust") {
    return report.package ? `Shared Rust · ${report.package}` : "Windows · Rust";
  }
  return String(report.runner ?? "Unknown runner");
}

function rustSuite(test) {
  const parts = String(test.name ?? "").split("::");
  const testsIndex = parts.indexOf("tests");
  const moduleParts = testsIndex > 0 ? parts.slice(0, testsIndex) : parts.slice(0, -1);
  const module = moduleParts.slice(0, 3).join("::");
  return module ? `${test.target} / ${module}` : String(test.target ?? "Rust tests");
}

function inferredSuite(report, test) {
  if (test.suite) return String(test.suite);
  if (test.target) return rustSuite(test);
  const combinedName = String(test.name ?? "");
  const separator = combinedName.lastIndexOf(" / ");
  if (separator > 0) return combinedName.slice(0, separator);
  return `${report.runner ?? "test"} / uncategorized`;
}

function normalizedEntries(reportEntries) {
  return reportEntries.flatMap(({ source, report }) => {
    const warnMs = Number(report.warnMs ?? 1000);
    const maxMs = Number(report.maxMs ?? 15000);
    return report.tests.map((test) => {
      const durationMs = Number(test.durationMs ?? 0);
      const status = String(test.status ?? "unknown").toLowerCase();
      const failed = FAILURE_STATUSES.has(status);
      const overBudget = durationMs >= maxMs;
      const slow = durationMs >= warnMs;
      return {
        source,
        runner: report.runner,
        reportLabel: reportLabel(report),
        suite: inferredSuite(report, test),
        name: String(test.name ?? "unknown test"),
        status,
        durationMs,
        warnMs,
        maxMs,
        failed,
        overBudget,
        slow,
        details: String(test.details ?? ""),
      };
    });
  });
}

function summarize(tests) {
  return {
    total: tests.length,
    passed: tests.filter((test) => test.status === "passed" && !test.overBudget).length,
    failed: tests.filter((test) => test.failed).length,
    skipped: tests.filter((test) => test.status === "skipped").length,
    overBudget: tests.filter((test) => test.overBudget).length,
    issues: tests.filter((test) => test.failed || test.overBudget).length,
    slow: tests.filter((test) => test.slow && !test.overBudget).length,
    durationMs: tests.reduce((total, test) => total + test.durationMs, 0),
  };
}

function statusPresentation(test) {
  if (["timeout", "incomplete"].includes(test.status)) return ["critical", test.status];
  if (test.failed) return ["critical", "failed"];
  if (test.overBudget) return ["critical", "over budget"];
  if (test.slow) return ["warning", "slow"];
  if (test.status === "skipped") return ["muted", "skipped"];
  return ["success", "passed"];
}

function moduleRows(tests) {
  const modules = new Map();
  for (const test of tests) {
    const key = `${test.reportLabel}\u0000${test.suite}`;
    const module = modules.get(key) ?? {
      reportLabel: test.reportLabel,
      suite: test.suite,
      tests: [],
    };
    module.tests.push(test);
    modules.set(key, module);
  }
  return [...modules.values()]
    .map((module) => ({ ...module, summary: summarize(module.tests) }))
    .sort((left, right) => {
      return right.summary.issues - left.summary.issues
        || right.summary.durationMs - left.summary.durationMs;
    });
}

function summaryCard(label, value, tone, hint) {
  return `<article class="summary-card ${tone}">
    <span>${escapeHTML(label)}</span>
    <strong>${escapeHTML(value)}</strong>
    <small>${escapeHTML(hint)}</small>
  </article>`;
}

function testTableRows(tests) {
  return tests.map((test) => {
    const [tone, label] = statusPresentation(test);
    const ratio = test.warnMs > 0 ? Math.round((test.durationMs / test.warnMs) * 100) : 0;
    return `<tr data-status="${tone}" data-search="${escapeHTML(
      `${test.reportLabel} ${test.suite} ${test.name}`.toLowerCase(),
    )}">
      <td><span class="badge ${tone}">${escapeHTML(label)}</span></td>
      <td><strong>${escapeHTML(test.name)}</strong>${
        test.details ? `<details><summary>错误详情</summary><pre>${escapeHTML(test.details)}</pre></details>` : ""
      }</td>
      <td>${escapeHTML(test.suite)}</td>
      <td>${escapeHTML(test.reportLabel)}</td>
      <td class="number">${escapeHTML(formatDuration(test.durationMs))}</td>
      <td class="number">${ratio}%</td>
    </tr>`;
  }).join("\n");
}

function performanceRows(tests) {
  return tests
    .filter((test) => test.slow || test.failed)
    .sort((left, right) => {
      const leftPriority = Number(left.failed || left.overBudget);
      const rightPriority = Number(right.failed || right.overBudget);
      return rightPriority - leftPriority || right.durationMs - left.durationMs;
    })
    .map((test) => {
      const [tone, label] = statusPresentation(test);
      const threshold = test.warnMs > 0 ? test.durationMs / test.warnMs : 0;
      const recommendation = test.failed
        ? "先检查失败日志与资源清理路径"
        : test.overBudget
          ? "已越过硬预算，应拆分外部 I/O、进程或高成本初始化"
          : "超过预警线，检查可复用 setup 与不必要的集成边界";
      return `<tr>
        <td><span class="badge ${tone}">${escapeHTML(label)}</span></td>
        <td><strong>${escapeHTML(test.name)}</strong><small>${escapeHTML(test.suite)}</small></td>
        <td class="number">${escapeHTML(formatDuration(test.durationMs))}</td>
        <td class="number">${threshold.toFixed(1)}×</td>
        <td>${escapeHTML(recommendation)}</td>
      </tr>`;
    }).join("\n");
}

function sourceLinks(reportEntries) {
  return reportEntries.map(({ source }) => {
    const stem = source.replace(/\.json$/i, "");
    return `<li><strong>${escapeHTML(stem)}</strong><span><a href="${escapeHTML(source)}">JSON</a> · <a href="${escapeHTML(stem)}.junit.xml">JUnit XML</a>${
      existsSync(path.join(path.dirname(reportEntries[0].path), `${stem}.log`))
        ? ` · <a href="${escapeHTML(stem)}.log">原始日志</a>`
        : ""
    }</span></li>`;
  }).join("\n");
}

export function renderHTML(reportEntries, title = "Lithe Test Stability Report") {
  const tests = normalizedEntries(reportEntries);
  const summary = summarize(tests);
  const modules = moduleRows(tests);
  const issueCount = summary.issues;
  const overallTone = issueCount > 0 ? "critical" : summary.slow > 0 ? "warning" : "success";
  const overallLabel = issueCount > 0 ? "需要处理" : summary.slow > 0 ? "通过，有性能预警" : "全部通过";
  const generatedAt = new Date().toISOString();
  const moduleHTML = modules.map((module) => {
    const issues = module.summary.issues;
    const tone = issues > 0 ? "critical" : module.summary.slow > 0 ? "warning" : "success";
    return `<tr>
      <td><span class="health ${tone}"></span><strong>${escapeHTML(module.suite)}</strong><small>${escapeHTML(module.reportLabel)}</small></td>
      <td class="number">${module.summary.total}</td>
      <td class="number">${issues}</td>
      <td class="number">${module.summary.slow}</td>
      <td class="number">${escapeHTML(formatDuration(module.summary.durationMs))}</td>
    </tr>`;
  }).join("\n");

  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHTML(title)}</title>
  <style>
    :root { color-scheme: light dark; --bg:#f5f7fb; --panel:#fff; --text:#172033; --muted:#68738a; --line:#dfe5ef; --good:#12805c; --warn:#b46800; --bad:#c9364f; --accent:#4f5bd5; }
    @media (prefers-color-scheme: dark) { :root { --bg:#10131a; --panel:#181d27; --text:#edf1f8; --muted:#9da8bc; --line:#303747; --good:#55d6a7; --warn:#ffbd66; --bad:#ff758a; --accent:#8d98ff; } }
    * { box-sizing:border-box; } body { margin:0; background:var(--bg); color:var(--text); font:14px/1.5 ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif; }
    main { width:min(1440px, calc(100% - 32px)); margin:32px auto 72px; } header { display:flex; justify-content:space-between; gap:24px; align-items:flex-end; margin-bottom:24px; }
    h1 { margin:0; font-size:30px; letter-spacing:-.03em; } h2 { margin:0 0 16px; font-size:18px; } p { color:var(--muted); margin:6px 0 0; }
    .overall { display:flex; align-items:center; gap:9px; color:var(--muted); } .health { display:inline-block; width:10px; height:10px; border-radius:50%; margin-right:9px; background:var(--muted); }
    .success { color:var(--good)!important; } .warning { color:var(--warn)!important; } .critical { color:var(--bad)!important; } .health.success,.badge.success { background:color-mix(in srgb,var(--good) 14%,transparent); } .health.warning,.badge.warning { background:color-mix(in srgb,var(--warn) 14%,transparent); } .health.critical,.badge.critical { background:color-mix(in srgb,var(--bad) 14%,transparent); } .health.success { background:var(--good); } .health.warning { background:var(--warn); } .health.critical { background:var(--bad); }
    .summary-grid { display:grid; grid-template-columns:repeat(6,minmax(120px,1fr)); gap:12px; margin-bottom:18px; } .summary-card,.panel { background:var(--panel); border:1px solid var(--line); border-radius:14px; box-shadow:0 8px 30px rgba(25,35,58,.05); }
    .summary-card { padding:16px; } .summary-card span,.summary-card small { display:block; color:var(--muted); } .summary-card strong { display:block; margin:5px 0 2px; font-size:26px; }
    .panel { padding:20px; margin-top:18px; overflow:hidden; } .panel-head { display:flex; justify-content:space-between; align-items:center; gap:16px; margin-bottom:12px; }
    table { width:100%; border-collapse:collapse; } th { color:var(--muted); font-size:12px; text-align:left; text-transform:uppercase; letter-spacing:.05em; } th,td { padding:11px 10px; border-bottom:1px solid var(--line); vertical-align:top; } tr:last-child td { border-bottom:0; } td small { display:block; color:var(--muted); margin-top:2px; } .number { text-align:right; white-space:nowrap; }
    .badge { display:inline-flex; padding:3px 8px; border-radius:999px; font-size:11px; font-weight:700; white-space:nowrap; background:color-mix(in srgb,var(--muted) 13%,transparent); color:var(--muted); }
    input,select { min-height:38px; border:1px solid var(--line); border-radius:9px; padding:0 11px; background:var(--panel); color:var(--text); } input { width:min(360px,50vw); }
    details { margin-top:7px; color:var(--muted); } pre { max-width:760px; overflow:auto; white-space:pre-wrap; color:var(--bad); } .empty { padding:28px; color:var(--muted); text-align:center; }
    .sources { display:grid; grid-template-columns:repeat(auto-fit,minmax(260px,1fr)); gap:8px; padding:0; list-style:none; } .sources li { display:flex; justify-content:space-between; gap:12px; padding:10px 12px; border:1px solid var(--line); border-radius:9px; } a { color:var(--accent); text-decoration:none; }
    @media (max-width:900px) { .summary-grid { grid-template-columns:repeat(2,1fr); } header,.panel-head { align-items:flex-start; flex-direction:column; } main { width:min(100% - 20px,1440px); margin-top:18px; } .table-wrap { overflow-x:auto; } }
  </style>
</head>
<body>
<main>
  <header><div><h1>${escapeHTML(title)}</h1><p>生成时间 ${escapeHTML(generatedAt)} · 慢测试以各 runner 的 warn/max 预算判定</p></div><div class="overall"><span class="health ${overallTone}"></span><strong>${overallLabel}</strong></div></header>
  <section class="summary-grid">
    ${summaryCard("测试总数", summary.total, "", "全部 runner")}
    ${summaryCard("正常通过", summary.passed, "success", "未触发性能预警")}
    ${summaryCard("失败 / 超时", summary.failed, summary.failed ? "critical" : "", "功能或稳定性问题")}
    ${summaryCard("超过硬预算", summary.overBudget, summary.overBudget ? "critical" : "", "会导致测试门禁失败")}
    ${summaryCard("性能预警", summary.slow, summary.slow ? "warning" : "", "超过 warn，尚未超过 max")}
    ${summaryCard("累计测试耗时", formatDuration(summary.durationMs), "", "逐测试耗时之和")}
  </section>
  <section class="panel"><h2>模块健康度</h2><div class="table-wrap"><table><thead><tr><th>模块 / Suite</th><th class="number">测试</th><th class="number">问题</th><th class="number">慢测试</th><th class="number">耗时</th></tr></thead><tbody>${moduleHTML || '<tr><td colspan="5" class="empty">没有测试数据</td></tr>'}</tbody></table></div></section>
  <section class="panel"><h2>问题与性能优化队列</h2><div class="table-wrap"><table><thead><tr><th>等级</th><th>测试</th><th class="number">耗时</th><th class="number">预警线比例</th><th>建议</th></tr></thead><tbody>${performanceRows(tests) || '<tr><td colspan="5" class="empty">没有失败、超时或性能预警</td></tr>'}</tbody></table></div></section>
  <section class="panel"><div class="panel-head"><h2>全部测试</h2><div><input id="search" type="search" placeholder="搜索模块或测试名称"><select id="status"><option value="all">全部状态</option><option value="critical">问题</option><option value="warning">慢测试</option><option value="success">通过</option><option value="muted">跳过</option></select></div></div><div class="table-wrap"><table><thead><tr><th>状态</th><th>测试</th><th>模块</th><th>Runner</th><th class="number">耗时</th><th class="number">预警线比例</th></tr></thead><tbody id="tests">${testTableRows(tests)}</tbody></table></div></section>
  <section class="panel"><h2>原始报告</h2><ul class="sources">${sourceLinks(reportEntries)}</ul></section>
</main>
<script>
  const search = document.querySelector('#search'); const status = document.querySelector('#status'); const rows = [...document.querySelectorAll('#tests tr')];
  function filterRows() { const query = search.value.trim().toLowerCase(); for (const row of rows) row.hidden = !row.dataset.search.includes(query) || (status.value !== 'all' && row.dataset.status !== status.value); }
  search.addEventListener('input', filterRows); status.addEventListener('change', filterRows);
</script>
</body>
</html>\n`;
}

export function renderJUnitXML({ source, report }) {
  const tests = normalizedEntries([{ source, report }]);
  const errorStatuses = new Set(["error", "timeout", "incomplete"]);
  const failures = tests.filter(
    (test) => !errorStatuses.has(test.status) && (test.status === "failed" || test.overBudget),
  ).length;
  const errors = tests.filter((test) => errorStatuses.has(test.status)).length;
  const skipped = tests.filter((test) => test.status === "skipped").length;
  const totalSeconds = tests.reduce((total, test) => total + test.durationMs, 0) / 1000;
  const cases = tests.map((test) => {
    let outcome = "";
    if (["error", "timeout", "incomplete"].includes(test.status)) {
      outcome = `<error type="${escapeXML(test.status)}" message="${escapeXML(test.details || test.status)}"/>`;
    } else if (test.status === "failed" || test.overBudget) {
      const message = test.overBudget
        ? `Performance budget exceeded: ${test.durationMs}ms >= ${test.maxMs}ms`
        : test.details || "Test failed";
      outcome = `<failure type="${test.overBudget ? "performance-budget" : "assertion"}" message="${escapeXML(message)}">${escapeXML(test.details)}</failure>`;
    } else if (test.status === "skipped") {
      outcome = "<skipped/>";
    }
    return `    <testcase classname="${escapeXML(test.suite)}" name="${escapeXML(test.name)}" time="${(test.durationMs / 1000).toFixed(3)}">${outcome}</testcase>`;
  }).join("\n");
  return `<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="${escapeXML(reportLabel(report))}" tests="${tests.length}" failures="${failures}" errors="${errors}" skipped="${skipped}" time="${totalSeconds.toFixed(3)}">
  <testsuite name="${escapeXML(reportLabel(report))}" tests="${tests.length}" failures="${failures}" errors="${errors}" skipped="${skipped}" time="${totalSeconds.toFixed(3)}">
${cases}
  </testsuite>
</testsuites>\n`;
}

function loadReport(reportPath) {
  const report = JSON.parse(readFileSync(reportPath, "utf8"));
  if (!report.runner || !Array.isArray(report.tests)) {
    throw new Error(`Unsupported test report: ${reportPath}`);
  }
  return { path: reportPath, source: path.basename(reportPath), report };
}

function reportPathsIn(directory) {
  if (!existsSync(directory)) return [];
  return readdirSync(directory)
    .filter((name) => name.endsWith(".json"))
    .map((name) => path.join(directory, name))
    .sort();
}

export function writeTestReportArtifacts(reportPath) {
  const directory = path.dirname(reportPath);
  const entry = loadReport(reportPath);
  const stem = entry.path.replace(/\.json$/i, "");
  writeFileSync(`${stem}.junit.xml`, renderJUnitXML(entry));
  writeFileSync(`${stem}.html`, renderHTML([entry], `${reportLabel(entry.report)} Test Report`));
  const indexPath = path.join(directory, "index.html");
  // A runner must not silently merge stale local reports into the current
  // result. CI performs an explicit directory aggregation after all lanes.
  writeFileSync(indexPath, renderHTML([entry]));
  console.log(`HTML test report: ${indexPath}`);
  return indexPath;
}

function parseArguments(arguments_) {
  const options = {
    inputDirectory: path.join(REPOSITORY_ROOT, ".artifacts/test-stability"),
    output: null,
    title: "Lithe Test Stability Report",
  };
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--input-dir") options.inputDirectory = path.resolve(arguments_[++index]);
    else if (argument === "--output") options.output = path.resolve(arguments_[++index]);
    else if (argument === "--title") options.title = arguments_[++index];
    else throw new Error(`Unknown argument: ${argument}`);
  }
  options.output ??= path.join(options.inputDirectory, "index.html");
  return options;
}

function main() {
  try {
    const options = parseArguments(process.argv.slice(2));
    const entries = reportPathsIn(options.inputDirectory).map(loadReport);
    if (entries.length === 0) throw new Error(`No JSON test reports found in ${options.inputDirectory}.`);
    mkdirSync(path.dirname(options.output), { recursive: true });
    for (const entry of entries) {
      writeFileSync(entry.path.replace(/\.json$/i, ".junit.xml"), renderJUnitXML(entry));
    }
    writeFileSync(options.output, renderHTML(entries, options.title));
    console.log(`HTML test report: ${options.output}`);
  } catch (error) {
    console.error(`Test report generation failed: ${error.message}`);
    process.exitCode = 1;
  }
}

if (path.resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) main();
