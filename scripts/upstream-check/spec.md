# upstream-check spec

Daily CI (`upstream-compat-watch`, `.github/workflows/upstream-compat-watch.yml`) that watches upstream agent CLI versions and reports compat results to Slack. Cursor is out of scope (no machine-readable version source).

## Watched packages (npm dist-tags.latest)

| harness  | npm package                       |
| -------- | --------------------------------- |
| claude   | `@anthropic-ai/claude-code`       |
| codex    | `@openai/codex`                   |
| dsh      | `@deepseek-ai/dsh-llm`            |
| hermes   | `hermes-agent`                    |
| opencode | `opencode-ai`                     |
| pi       | `@earendil-works/pi-coding-agent` |

## Pipeline

```
detect (daily cron 11:00 KST + workflow_dispatch)
  └─ check.mjs — diff latest vs versions.json; emit changed matrix
unit-e2e (matrix: changed harnesses only)
  ├─ install-and-test.sh <name> <to> — install new version, run that
  │   harness's unit suite (test/harnesses/<name>) under a sandbox HOME
  └─ e2e.sh <name> <to> — skipped if unit failed (steps.unit.outcome
     == 'success') or FRIENDLIAI_API_KEY is not configured
notify
  ├─ report: per-harness version bump + unit + e2e to Slack
  ├─ heartbeat line on no-change days
  └─ commit versions.json only when unit passed (failed versions retry
     and re-alert daily)
```

## Files

- `check.mjs` — npm lookup + diff. Snapshot keys are the real npm package names; the harness alias lives in check.mjs's WATCH list. Records latest locally; commit is the workflow's job. Registry failure = `::warning::` only.
- `versions.json` — last passing snapshot, keyed by npm package name. Source of truth for the diff.
- `install-and-test.sh` — `npm install -g <pkg>@<to>` then `pnpm test -- test/harnesses/<name>` with HOME/XDG/DSH_HOME/PI_CODING_AGENT_DIR pointed at a throwaway sandbox (Hermes resolves its per-test home from the test context). Skipped tests are treated as failure: with the real CLI installed, `describe.skipIf(binary)` must not skip.
- `e2e.sh` — one harness, typed like a user: re-exec into an `env -i` shell with an empty throwaway HOME → install the harness (`<to>`) → install frlink from `main` with the public `install.sh` → `frlink login` → start `scripts/friendli-relay.mjs` (logging proxy) and `frlink <name> on --model <cheapest model>` (picked each run from `GET /v1/models`: cheapest by input+output price among models with a reasoning `toggle` → level `off`, or an `effort` option → its lowest level), pointing the harness at the proxy (claude/codex/pi `--base-url`, opencode `OPENCODE_CONFIG_CONTENT`, hermes `hermes config set model.base_url`, dsh plugin `baseURL`) → one inference with that level set by the harness's own command, never by frlink (off: claude `MAX_THINKING_TOKENS=0`, codex `-c model_reasoning_effort=none`, opencode `--variant off`, pi `--thinking off`, hermes `--reasoning none`, dsh `reasoningEffort: off`; effort: claude `--effort`, the others the same flags with the level in `settings.yaml` + plugin `thinking: disabled`) → check the proxy capture: at least one inference request, every one answered 200, none with reasoning in the response when it was turned off; on failure the non-2xx Friendli answers (e.g. 429) are printed to stderr, so they reach the Slack log → `frlink <name> off` → assert `status` no longer routed and the API key is gone from HOME → `logout` → HOME removed. The key is withheld from the environment until `login`, so third-party installers never see it. Any failing command fails the leg.
- `notify.mjs` — appends, per failed e2e harness, the tail of its stdout/stderr (leg uploads artifact `e2e-log-<name>`, notify downloads them into `E2E_LOG_DIR`) to the report; builds the Slack message from the changed matrix + per-harness unit/e2e verdicts (`unit-results.mjs`, read from the Actions jobs API steps), or `RESULTS`/`MODE` env for local runs. No `SLACK_WEBHOOK_URL` → `::warning::`, exit 0.

Model-catalog fetch failures stop before JSON parsing and log the stage
(`model-catalog`), HTTP method, full endpoint URL, HTTP status, and curl exit
code. The summary follows curl's diagnostic so the Slack log tail identifies
the failed request without a secondary empty-input JSON error.

Login credential-check failures preserve the unexpected HTTP status or network
error in the CLI output, so the e2e failure log and Slack report retain the
reason instead of only saying that the API key could not be verified.

## Secrets

- `SLACK_WEBHOOK_URL` — incoming webhook for the target org public channel.
- `FRIENDLIAI_API_KEY` — Friendli API key for the e2e inference (one tiny request per changed harness). Missing → e2e reported as `skipped (no API key)`.

## User-facing requirements (fixed)

1. Alert on version update.
2. Unit test results for that update.
3. e2e results for that update (real inference through the harness; pass / fail / skipped).
4. Only changed harnesses run; unit failure skips e2e.
