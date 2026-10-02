#!/usr/bin/env node
/**
 * Upstream compat watch — per-leg unit + e2e verdicts from the Actions jobs API.
 *
 * The matrix job's aggregate result (needs.unit-e2e.result) cannot say WHICH
 * harness failed, but each matrix leg is its own entry in
 * GET /repos/{repo}/actions/runs/{run_id}/jobs. A leg's name embeds the
 * harness: "upstream compat watch / unit-e2e (claude, ..., 3)" — we match the
 * harness against the matrix parameters instead of parsing the parenthesized
 * shard text, so a harness name that appears in another shard's version
 * string cannot cross-wire the verdict.
 *
 * Env: GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_TOKEN (optional).
 * Output: JSON {harness: {unit, e2e}, ...} on stdout. The unit and e2e steps
 * are judged separately: a failing e2e fails the whole job, which must not
 * read as a unit failure. unit: "pass" | "fail"; e2e: "pass" | "fail" |
 * "skipped (unit failed)" | "skipped (no API key)".
 */

const WATCHED = new Set(["claude", "codex", "dsh", "hermes", "opencode", "pi"]);

const repo = process.env.GITHUB_REPOSITORY;
const runId = process.env.GITHUB_RUN_ID;
if (!repo || !runId) {
  console.error("GITHUB_REPOSITORY and GITHUB_RUN_ID are required");
  process.exit(1);
}

const headers = { accept: "application/vnd.github+json" };
if (process.env.GITHUB_TOKEN) {
  headers.authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
}
const response = await fetch(
  `https://api.github.com/repos/${repo}/actions/runs/${runId}/jobs?per_page=100`,
  { headers },
);
if (!response.ok) {
  console.error(`::error::jobs API HTTP ${response.status}`);
  process.exit(1);
}
const { jobs = [] } = await response.json();

const verdicts = {};
for (const job of jobs) {
  if (!job.name?.startsWith("unit-e2e")) continue;
  // ponytail: shard-name matching — jobs API exposes no matrix params, so we
  // match the harness token inside the shard suffix "(name, from, to)". A
  // version containing a harness token could confuse this; switch to the
  // check-run output API if that ever bites.
  const suffix = job.name.match(/\((.*)\)$/)?.[1] ?? "";
  const tokens = suffix.split(",").map((t) => t.trim());
  const conclusion = (prefix) =>
    job.steps?.find((step) => step.name.startsWith(prefix))?.conclusion;
  const unit = conclusion("Install ") === "success" ? "pass" : "fail";
  const e2eStep = conclusion("e2e (");
  let e2e = "fail";
  if (unit !== "pass") e2e = "skipped (unit failed)";
  else if (e2eStep === "success") e2e = "pass";
  else if (e2eStep === "skipped") e2e = "skipped (no API key)";
  for (const harness of tokens) {
    if (WATCHED.has(harness)) {
      verdicts[harness] = { unit, e2e };
    }
  }
}
console.log(JSON.stringify(verdicts));
