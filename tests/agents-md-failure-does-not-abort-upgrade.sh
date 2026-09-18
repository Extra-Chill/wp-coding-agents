#!/bin/bash
# tests/agents-md-failure-does-not-abort-upgrade.sh
#
# A failed AGENTS.md composition must fail the run WITHOUT truncating it.
#
# upgrade.sh runs under `set -e`, and regenerate_agents_md is the only phase
# function in it with a non-zero return path. Called bare, one stale memory file
# ended the run at that line: eleven reconciliation phases and print_summary
# never executed, and the log stopped with nothing saying the rest had been
# skipped (#607).
#
# This runs the real execute block from upgrade.sh against stubbed phases rather
# than asserting on its source text, so it fails if the capture is dropped no
# matter how the call is written.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UPGRADE="$ROOT_DIR/upgrade.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wpca-agents-md-abort.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The execute block is everything from the first status accumulator to EOF.
sed -n '/^PLUGIN_ONLY_EXIT_STATUS=0$/,$p' "$UPGRADE" > "$WORK/execute.sh"
if [ ! -s "$WORK/execute.sh" ]; then
  echo "FAIL: could not extract the execute block from upgrade.sh" >&2
  exit 1
fi

# Every phase reached after regenerate_agents_md. If the abort returns, these
# stop appearing in the transcript.
PHASES_AFTER=(
  runtime_guidance_sync_managed_codex_projection
  sync_claude_code_runtime
  sync_runtime_signature
  sync_runtime_instructions
  opencode_project_subagents_optional
  update_chat_bridge_systemd
  update_chat_bridge_launchd
  reconcile_wordpress_service
  reconcile_datamachine_worker_service
  refresh_opencode_runtime_signature_phase
  installation_profile_write
  print_summary
)

{
  echo 'set -eu'
  # Narrow-scope flags off; this is the full default upgrade path.
  for flag in PLUGINS_ONLY SKILLS_ONLY KIMAKI_ONLY AGENTS_MD_ONLY RECONCILE_SERVICES_ONLY DRY_RUN; do
    echo "${flag}=false"
  done
  echo 'SITE_PATH=/tmp/site'
  echo 'SCRIPT_DIR=/tmp/wpca'
  echo 'INSTALLATION_OPERATION_UPGRADE=upgrade'
  echo '_run_filter_active() { return 0; }'
  echo 'update_data_machine_plugins() { :; }'
  echo 'convergence_run() { :; }'
  echo 'reconciler_print_partial_evidence() { echo "RAN reconciler_print_partial_evidence"; }'

  # Phases before the failing one, plus the unconditional ones.
  for phase in reconcile_provider_and_service_state sync_cli_transport_runtime \
    update_ai_gateway sync_chat_bridge_config systems_capabilities_apply \
    check_opencode_json_drift ai_gateway_configure_opencode sync_skills \
    "${PHASES_AFTER[@]}"; do
    echo "${phase}() { echo \"RAN ${phase}\"; }"
  done

  # The failure under test.
  echo 'regenerate_agents_md() { echo "RAN regenerate_agents_md"; return 1; }'

  cat "$WORK/execute.sh"
} > "$WORK/harness.sh"

set +e
transcript="$(bash "$WORK/harness.sh" 2>&1)"
status=$?
set -e

failed=0

if [ "$status" -eq 0 ]; then
  echo "FAIL: a failed AGENTS.md composition must still exit non-zero (got 0)" >&2
  failed=1
fi

for phase in "${PHASES_AFTER[@]}"; do
  case "$transcript" in
    *"RAN ${phase}"*) ;;
    *)
      echo "FAIL: ${phase} did not run after the AGENTS.md failure" >&2
      failed=1
      ;;
  esac
done

# Guard the inverse: the capture must not swallow the failure into a clean exit
# reported as success by the summary.
case "$transcript" in
  *"RAN regenerate_agents_md"*) ;;
  *)
    echo "FAIL: harness never reached regenerate_agents_md" >&2
    failed=1
    ;;
esac

if [ "$failed" -ne 0 ]; then
  echo "--- transcript ---" >&2
  echo "$transcript" >&2
  echo "--- exit status: $status ---" >&2
  exit 1
fi

echo "ok   remaining phases run after an AGENTS.md composition failure"
echo "ok   the run still exits non-zero (${status})"
echo "OK (tests/agents-md-failure-does-not-abort-upgrade.sh)"
