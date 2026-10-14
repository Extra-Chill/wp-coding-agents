#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/global/node_modules/@extrachill/roadie"
printf '{"version":"0.0.0"}\n' > "$tmp/global/node_modules/@extrachill/roadie/package.json"
cat > "$tmp/bin/npm" <<'SH'
#!/bin/bash
if [ "$1" = root ]; then printf '%s\n' "$FAKE_NPM_ROOT/node_modules"; exit 0; fi  # real npm root -g ends in node_modules
printf '%s\n' "$*" >> "$FAKE_CALLS"
[ "${FAKE_NPM_FAIL:-0}" = 0 ] || exit 1
mkdir -p "$FAKE_NPM_ROOT/node_modules/@extrachill/roadie"
printf '{"version":"%s"}\n' "$(tr -d '[:space:]' < "$FAKE_PIN")" > "$FAKE_NPM_ROOT/node_modules/@extrachill/roadie/package.json"
SH
cat > "$tmp/bin/launchctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_CALLS"
SH
chmod +x "$tmp/bin/npm" "$tmp/bin/launchctl"
export PATH="$tmp/bin:/usr/bin:/bin" FAKE_NPM_ROOT="$tmp/global" FAKE_CALLS="$tmp/calls" FAKE_PIN="$ROOT/bridges/roadie/roadie-version"
export ROADIE_DATA_DIR="$tmp/data"

# Already pinned: record success without reinstalling or restarting.
want="$(tr -d '[:space:]' < "$FAKE_PIN")"
printf '{"version":"%s"}\n' "$want" > "$tmp/global/node_modules/@extrachill/roadie/package.json"
bash "$ROOT/scripts/roadie-local-upgrade"
[ ! -s "$tmp/calls" ]
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert s["result"] == "ok" and s["from"] == s["to"]' "$ROADIE_DATA_DIR/roadie-upgrade-state.json"

# Install success: upgrade package and restart Roadie.
printf '{"version":"0.0.0"}\n' > "$tmp/global/node_modules/@extrachill/roadie/package.json"
: > "$tmp/calls"
bash "$ROOT/scripts/roadie-local-upgrade"
grep -q '^kickstart -k gui/' "$tmp/calls"

# Install failure: persist failure, leave Roadie running.
printf '{"version":"0.0.0"}\n' > "$tmp/global/node_modules/@extrachill/roadie/package.json"
: > "$tmp/calls"
export FAKE_NPM_FAIL=1
if bash "$ROOT/scripts/roadie-local-upgrade"; then echo 'expected npm failure' >&2; exit 1; fi
! grep -q '^kickstart' "$tmp/calls"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["result"] == "failed"' "$ROADIE_DATA_DIR/roadie-upgrade-state.json"
printf 'PASS: tests/roadie-local-upgrade.sh\n'
