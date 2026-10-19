#!/bin/bash
# scripts/roadie-local-upgrade moves a local launchd Roadie to the pin merged
# to main, never to whatever the operator's checkout has checked out (#740).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }

# Checkout fixture: main pins 9.9.9 on origin; the local checkout sits on a
# stale branch pinning 0.1.0.
g init -q --bare "$tmp/origin.git"
g init -q "$tmp/checkout"
mkdir -p "$tmp/checkout/scripts" "$tmp/checkout/bridges/roadie"
cp "$ROOT/scripts/roadie-local-upgrade" "$tmp/checkout/scripts/"
cp "$ROOT/bridges/roadie.sh" "$tmp/checkout/bridges/"
printf '9.9.9\n' > "$tmp/checkout/bridges/roadie/roadie-version"
g -C "$tmp/checkout" add -A && g -C "$tmp/checkout" commit -qm main
g -C "$tmp/checkout" remote add origin "$tmp/origin.git"
g -C "$tmp/checkout" push -q origin main
g -C "$tmp/checkout" checkout -qb stale
printf '0.1.0\n' > "$tmp/checkout/bridges/roadie/roadie-version"
g -C "$tmp/checkout" commit -qam stale
UPGRADE="$tmp/checkout/scripts/roadie-local-upgrade"

mkdir -p "$tmp/bin" "$tmp/global/node_modules/@extrachill/roadie"
installed() { printf '{"version":"%s"}\n' "$1" > "$tmp/global/node_modules/@extrachill/roadie/package.json"; }
cat > "$tmp/bin/npm" <<'SH'
#!/bin/bash
if [ "$1" = root ]; then printf '%s\n' "$FAKE_NPM_ROOT/node_modules"; exit 0; fi  # real npm root -g ends in node_modules
printf '%s\n' "$*" >> "$FAKE_CALLS"
[ "${FAKE_NPM_FAIL:-0}" = 0 ] || exit 1
version="${*##*extrachill-roadie-}"; version="${version%.tgz}"
printf '{"version":"%s"}\n' "$version" > "$FAKE_NPM_ROOT/node_modules/@extrachill/roadie/package.json"
SH
cat > "$tmp/bin/launchctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_CALLS"
SH
chmod +x "$tmp/bin/npm" "$tmp/bin/launchctl"
export PATH="$tmp/bin:/usr/bin:/bin" FAKE_NPM_ROOT="$tmp/global" FAKE_CALLS="$tmp/calls"
export ROADIE_DATA_DIR="$tmp/data"
state() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$ROADIE_DATA_DIR/roadie-upgrade-state.json" "$1"; }

# Already on main's pin: record success without reinstalling or restarting.
installed 9.9.9
bash "$UPGRADE"
[ ! -s "$tmp/calls" ]
[ "$(state result)" = ok ] && [ "$(state to)" = 9.9.9 ]

# Newer than the stale checkout's pin, older than main's: installs main's pin
# and restarts Roadie.
installed 0.5.0
: > "$tmp/calls"
bash "$UPGRADE"
grep -q 'extrachill-roadie-9.9.9.tgz' "$tmp/calls"
! grep -q '0\.1\.0' "$tmp/calls"
grep -q '^kickstart -k gui/' "$tmp/calls"
[ "$(state from)" = 0.5.0 ] && [ "$(state to)" = 9.9.9 ]

# Install failure: persist failure, leave Roadie running.
installed 0.5.0
: > "$tmp/calls"
if FAKE_NPM_FAIL=1 bash "$UPGRADE"; then echo 'expected npm failure' >&2; exit 1; fi
! grep -q '^kickstart' "$tmp/calls"
[ "$(state result)" = failed ]

# main unreachable: fail without installing anything, never fall back to the
# checkout's own pin.
g -C "$tmp/checkout" remote set-url origin "$tmp/missing.git"
: > "$tmp/calls"
if bash "$UPGRADE" 2>/dev/null; then echo 'expected fetch failure' >&2; exit 1; fi
[ ! -s "$tmp/calls" ]
[ "$(state result)" = failed ]
case "$(state detail)" in *origin/main*) ;; *) echo "unexpected detail: $(state detail)" >&2; exit 1 ;; esac
printf 'PASS: tests/roadie-local-upgrade.sh\n'
