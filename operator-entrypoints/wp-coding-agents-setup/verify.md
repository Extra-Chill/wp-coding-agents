# Setup Verification

Run post-setup verification using overlay names emitted by `scripts/compile-setup-profile.mjs`. This reference owns concrete verification command recipes; the compiler script owns only deterministic command construction and overlay selection.

Use the commands printed by `setup.sh` when they are more specific than the generic recipes below. Treat the script summary as the source of truth for generated paths, service names, bridge restart commands, and local launchd/systemd details.

## Required Overlays

### `verify-wordpress`

Standard WP-CLI:

```bash
wp option get siteurl --path=/path/to/site
```

VPS/root WP-CLI:

```bash
wp --allow-root option get siteurl --path=/path/to/site
```

### `verify-data-machine`

Standard WP-CLI:

```bash
wp plugin list --path=/path/to/site | grep data-machine
```

VPS/root WP-CLI:

```bash
wp --allow-root plugin list --path=/path/to/site | grep data-machine
```

## Target Overlays

### `verify-wordpress-studio`

```bash
studio wp option get siteurl
studio wp plugin list | grep data-machine
```

### `verify-vps-reachable`

```bash
curl -I https://yourdomain.com
```

## Runtime Overlays

### `verify-runtime-opencode`

```bash
opencode --version
```

### `verify-runtime-claude-code`

```bash
claude --version
```

### `verify-runtime-codex`

```bash
codex --version
test -f /path/to/site/AGENTS.md
test -f /path/to/site/AGENTS.override.md
grep -q 'WP_CODING_AGENTS_CODEX_MEMORY_START' /path/to/site/AGENTS.override.md
test -d /path/to/site/.agents/skills/upgrade-wp-coding-agents
```

### `verify-runtime-multiple`

Run the selected runtime checks for each runtime in the compiled profile. If the setup used auto-detection, compare the detected runtime list from setup output with installed runtime binaries.

## Bridge Overlays

### `verify-bridge-kimaki`

Use the service or launchd verification commands emitted by setup output. Do not restart an existing live Kimaki bridge unless the user explicitly asks.

For local Kimaki logs:

```bash
grep 'kimaki-config: WARNING' "$HOME/.kimaki/kimaki.log" || true
```

For VPS Kimaki logs, use the service name emitted by setup output. Typical command:

```bash
journalctl -u kimaki -n 100 --no-pager | grep 'kimaki-config: WARNING' || true
```

### `verify-bridge-kimaki-opencode-plugins`

Local Kimaki plugin paths:

```bash
KIMAKI_PLUGINS_DIR="$(npm root -g)/kimaki/plugins"
test -f "$KIMAKI_PLUGINS_DIR/dm-context-filter.ts" && test -f "$KIMAKI_PLUGINS_DIR/dm-agent-sync.ts" && test -f "$KIMAKI_PLUGINS_DIR/homeboy-notification-context.ts"
```

VPS Kimaki plugin paths:

```bash
test -f /opt/kimaki-config/plugins/dm-context-filter.ts && test -f /opt/kimaki-config/plugins/dm-agent-sync.ts && test -f /opt/kimaki-config/plugins/homeboy-notification-context.ts
```

If either plugin file is missing, rerun setup or upgrade before trusting a new OpenCode session. OpenCode silently skips missing plugin files.

### `verify-bridge-cc-connect`

Use the cc-connect config and service/launchd commands emitted by setup output. Verify the bridge can start, but do not restart a live bridge without user approval.

### `verify-bridge-telegram`

Confirm `TELEGRAM_BOT_TOKEN` and `TELEGRAM_ALLOWED_USER_ID` are configured, then use the service or launchd commands emitted by setup output. Verify by messaging the Telegram bot.

### `verify-bridge-none`

Verify the selected runtime can be started manually in the terminal or over SSH. No bridge service should be required.

## Optional Overlays

### `verify-homeboy`

This overlay proves Homeboy is installed, linked, and advertised to Data Machine. It does **not** prove the repo-aware Homeboy Codebox `agent-task` path can launch a sandbox, hydrate provider auth, mount the workspace at `/workspace`, and return patch/change evidence.

```bash
homeboy --version
homeboy extension list
homeboy project show <project-id>
homeboy project components list <project-id>
wp option get datamachine_code_homeboy_available --path=/path/to/site
wp datamachine memory compose AGENTS.md --path=/path/to/site
```

For WordPress Studio:

```bash
studio wp option get datamachine_code_homeboy_available
studio wp datamachine memory compose AGENTS.md
```

Expected model:

```text
WordPress site root = Homeboy project
DMC primary workspace checkouts = Homeboy components
DMC repo@branch worktrees = skipped by default
```

Do not create `homeboy.json` in the WordPress site root to fix a missing Homeboy project.

### `verify-homeboy-codebox-canary`

Use this explicit opt-in overlay when the install should prove the advertised Homeboy fleet-cooking path actually runs through Codebox. This can call a model and requires provider secret **environment variable names**, so do not run it as part of a casual setup smoke check and never paste secret values into the command.

The canary is intentionally bounded:

- read-only `/workspace` mount
- no file edits, commits, pushes, or PRs in the prompt
- one task, one attempt, concurrency `1`
- low `--max-turns`
- status/log/artifact validation only

Example for a WordPress Studio install with Data Machine-bundled Agents API:

```bash
./scripts/verify-homeboy-codebox-canary.sh \
  --workspace /path/to/existing/repo-or-dmc-worktree \
  --repo wp-coding-agents \
  --task-url https://github.com/Extra-Chill/wp-coding-agents/issues/190 \
  --secret-env OPENAI_API_KEY \
  --agents-api /path/to/wp-content/plugins/data-machine/vendor/wordpress/agents-api \
  --agent-runtime /path/to/wp-content/plugins/data-machine \
  --agent-runtime-tools /path/to/wp-content/plugins/data-machine-code \
  --provider-plugin-path /path/to/wp-content/plugins/ai-provider-for-openai \
  --homeboy-extensions "$HOME/.config/homeboy/extensions/wordpress" \
  --model gpt-4.1-mini \
  --max-turns 4
```

The command above prints the resolved dispatch shape without executing it. Add `--run` only when the operator intentionally wants to spend a model call and has the named secret env var available to Homeboy:

```bash
./scripts/verify-homeboy-codebox-canary.sh ... --run
```

Passing criteria:

- `homeboy agent-task status <run-id>` reports terminal `succeeded`
- `homeboy agent-task logs <run-id>` includes a succeeded task event
- `homeboy agent-task artifacts <run-id>` includes `codebox-changed-files`
- `codebox-changed-files.metadata.count` is `0`
- artifacts include `codebox-patch`
- `codebox-patch` is empty (`metadata.bytes` or `size_bytes` is `0`)

Actionable failure interpretation:

- Missing Homeboy extension/provider: fix `homeboy extension list` / `homeboy agent-task providers` before rerunning.
- Missing runtime component defaults: pass explicit `--agents-api`, `--agent-runtime`, and `--agent-runtime-tools` paths instead of relying on discovery.
- Agents API path mismatch: point `--agents-api` at Data Machine's bundled `vendor/wordpress/agents-api` path.
- Missing provider secret env names: pass `--secret-env NAME`; pass only env var names, never token values.
- Missing `/workspace` mount: verify the provider config contains a read-only mount with `target: "/workspace"` and `source` set to the existing repo/worktree path.

This canary is stronger than `datamachine_code_homeboy_available=1`: that option means Data Machine should advertise Homeboy guidance, while the canary proves the Codebox executor returned durable run, log, changed-files, and patch evidence for a repo-aware task.

### `verify-codex-codebox-provider`

Use this only for the Codebox minion provider-auth path. Do not configure WP AI Gateway just because Codex is involved.

```bash
wp plugin list | grep -E 'php-ai-client|ai-provider-for-openai|wp-codebox'
wp plugin is-active ai-provider-for-openai
wp plugin is-active wp-codebox
```

If provider login/status commands exist, run them. If they do not exist yet, report that Codex auth belongs upstream in the provider stack rather than adding local token shims.

### `verify-wp-ai-gateway`

Use this only when the operator selected the external OpenCode/Kimaki OpenAI-compatible endpoint path.

```bash
wp plugin is-active wp-ai-gateway
wp plugin is-active ai-provider-for-openai
wp ai-gateway status
```

Then verify the OpenAI-compatible surface with the site's gateway URL, token, and selected model:

```bash
curl -sS "$WP_AI_GATEWAY_BASE_URL/models" \
  -H "Authorization: Bearer $WP_AI_GATEWAY_TOKEN"

curl -sS "$WP_AI_GATEWAY_BASE_URL/chat/completions" \
  -H "Authorization: Bearer $WP_AI_GATEWAY_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"model":"<codex-model>","messages":[{"role":"user","content":"Reply with ok."}]}'
```

## Reporting

Report verification by overlay name:

```yaml
verification:
  verify-wordpress: passed
  verify-data-machine: passed
  verify-runtime-opencode: passed
  verify-bridge-kimaki-opencode-plugins: failed
failures:
  - overlay: verify-bridge-kimaki-opencode-plugins
    evidence: "dm-context-filter.ts missing from configured Kimaki plugin path"
    next_step: "rerun setup or upgrade before starting a new OpenCode session"
```

Stop at the first verification failure that means the installed agent would start with missing context, missing provider auth, or missing bridge wiring. Fix the underlying setup path before treating the install as complete.
