#!/usr/bin/env bash
# Upstream compat watch — e2e for ONE harness, typed the way a user would.
# Usage: e2e.sh <name> <to>      (needs FRIENDLIAI_API_KEY in the env)
#
# Clean terminal -> install harness -> install frlink from main -> login -> on
# -> ONE tiny inference, reasoning off via the harness's own command -> check
# the relay capture (200, no reasoning field) -> off -> check the reset.
# Any failing command fails the run (set -e).

set -euo pipefail

name="${1:-}" to="${2:-}"
[[ -z "$name" || -z "$to" ]] && { echo "usage: e2e.sh <name> <to>"; exit 2; }
case "$name" in claude|codex|opencode|pi|hermes|dsh) ;; *) echo "unknown harness: $name"; exit 2 ;; esac

# --- clean terminal: empty env, empty HOME, thrown away on exit ---------------
if [[ -z "${E2E_CLEAN:-}" ]]; then
  : "${FRIENDLIAI_API_KEY:?FRIENDLIAI_API_KEY is required}"
  exec env -i E2E_CLEAN=1 HOME="$(mktemp -d)" TERM=dumb \
    PATH="$(dirname "$(command -v node)"):/usr/local/bin:/usr/bin:/bin" \
    FRIENDLIAI_API_KEY="$FRIENDLIAI_API_KEY" bash "$0" "$@"
fi
relay="$(cd "$(dirname "$0")/.." && pwd)/friendli-relay.mjs"
trap 'kill "${relay_pid:-}" 2>/dev/null || true; rm -rf "$HOME"' EXIT
cd "$HOME"

# The key stays out of the environment until the user "types" it, so the
# third-party installs below never see it.
key="$FRIENDLIAI_API_KEY"
unset FRIENDLIAI_API_KEY

model="zai-org/GLM-5.2"
prompt="Reply with only the word: pong"

export NPM_CONFIG_PREFIX="$HOME/.npm-global"
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$HOME/.hermes/bin:$PATH"

# --- 1. install the harness (the version under test) --------------------------
case "$name" in
  claude)   npm install -g "@anthropic-ai/claude-code@$to" ;;
  codex)    npm install -g "@openai/codex@$to" ;;
  opencode) npm install -g "opencode-ai@$to" ;;
  pi)       npm install -g "@earendil-works/pi-coding-agent@$to" ;;
  hermes)   curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash ;;
  dsh)      npm install -g "@deepseek-ai/dsh-llm@$to" pnpm ;;
esac

# --- 2. install frlink from the latest main -----------------------------------
curl -fsSL https://raw.githubusercontent.com/friendliai/friendlilink/main/install.sh | bash

frlink check status | grep "^  $name (.*): not routed"

# --- 3. turn the harness on, run one inference, turn it off -------------------
frlink login --api-key "$key"

proxy=http://127.0.0.1:8787
node "$relay" --port 8787 --log capture.jsonl --bodies 1000000 --quiet 2>/dev/null &
relay_pid=$!
until curl -s -o /dev/null "$proxy"; do kill -0 "$relay_pid"; sleep 0.2; done

profile=()
[[ "$name" == dsh ]] && profile=(--profile headless)

case "$name" in
  claude)
    frlink claude on --model "$model" --base-url "$proxy"
    out="$(MAX_THINKING_TOKENS=0 claude -p "$prompt")" ;;
  codex)
    frlink codex on --model "$model" --base-url "$proxy"
    out="$(codex exec --skip-git-repo-check -c model_reasoning_effort=none "$prompt")" ;;
  opencode)
    frlink opencode on --model "$model"
    export OPENCODE_CONFIG_CONTENT='{"provider":{"friendli":{"options":{"baseURL":"'"$proxy"'/v1"}}}}'
    out="$(opencode run --variant off --title e2e "$prompt")" ;;
  pi)
    frlink pi on --model "$model" --base-url "$proxy"
    out="$(pi -p --thinking off "$prompt")" ;;
  hermes)
    frlink hermes on --model "$model"
    hermes config set model.base_url "$proxy/v1"
    out="$(hermes chat -Q --reasoning none -q "$prompt")" ;;
  dsh)
    frlink dsh on "${profile[@]}" --model "$model"
    cat > .dsh/settings.yaml <<YAML
agent-default-model: { provider: friendli, model: $model, reasoningEffort: "off" }
YAML
    cat > thinking-off.yml <<YAML
- id: "@friendliai/dsh-llm-friendli"
  config: { thinking: disabled, baseURL: "$proxy/v1" }
YAML
    out="$(dsh "${profile[@]}" --patch thinking-off.yml "$prompt")" ;;
esac
echo "$out"
grep -qi pong <<<"$out"

# The proxy saw every inference request: each one answered 200, none with
# reasoning (chat-completions, Responses and Messages wire shapes).
node -e '
const rows = require("fs").readFileSync("capture.jsonl", "utf8").trim().split("\n").map(JSON.parse)
  .filter((r) => r.request.method === "POST" && /\/(chat\/completions|responses|messages)(\?|$)/.test(r.request.path));
if (!rows.length) throw new Error("no inference request reached Friendli");
for (const r of rows) {
  if (r.response.status !== 200) throw new Error(`${r.request.path} answered ${r.response.status}`);
  if (/reasoning_content":"[^"]|"reasoning":"[^"]|"thinking_delta"|"type":"thinking"|reasoning[a-z_.]*\.delta/.test(JSON.stringify(r.response.body)))
    throw new Error(`${r.request.path}: reasoning came back although it was turned off`);
}
console.log(`proxy: ${rows.length} inference response(s), all 200, none with reasoning`);
'

frlink "$name" status "${profile[@]}" | grep "routed through FriendliAI"
frlink "$name" off "${profile[@]}"

# --- 4. the reset really happened ---------------------------------------------
frlink "$name" status "${profile[@]}" | grep "not managed by frlink"
if grep -rIlF "$key" "$HOME" --exclude-dir=.frlink; then
  echo "e2e: API key still present in the files above after \`frlink $name off\`"
  exit 1
fi
frlink logout
frlink check status | grep "API key: not saved"
echo "e2e: $name $to passed"
