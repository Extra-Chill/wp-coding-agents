#!/bin/bash
# tests/verify.sh — the cross-layer invariant checker.
#
# The only property worth testing here is that it CATCHES things. A checker that
# passes on a healthy install and also passes on a broken one is worse than no
# checker, because it converts "nobody looked" into "something looked and said
# it was fine".
#
# So every assertion below breaks one seam and demands a specific complaint.
# The seams are the real ones: each corresponds to a defect that reached a live
# site during the managed-hosting rollout, where every individual component was
# correct and tested and nothing owned the space between them.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

FAILED=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

assert_contains() {
  case "$1" in *"$2"*) echo "  ok   $3" ;; *) echo "  FAIL $3 (missing: $2)"; FAILED=$((FAILED + 1)) ;; esac
}
refute_contains() {
  case "$1" in *"$2"*) echo "  FAIL $3 (unexpectedly present: $2)"; FAILED=$((FAILED + 1)) ;; *) echo "  ok   $3" ;; esac
}

# A fake install. wp is stubbed so this needs no database.
SITE="$TMP/site"
mkdir -p "$SITE/wp-content/mu-plugins" "$TMP/units" "$TMP/manifest/site"
# When running as root the manifest-writability check is live, so the fixture
# has to model a correctly-provisioned directory.
if [ "$(id -u)" -eq 0 ] && id -u www-data >/dev/null 2>&1; then
  chown root:www-data "$TMP/manifest/site" 2>/dev/null || true
  chmod 2775 "$TMP/manifest/site" 2>/dev/null || true
  chmod o+rx "$TMP" "$TMP/manifest" 2>/dev/null || true
fi
: > "$SITE/wp-config.php"
touch "$SITE/wp-content/mu-plugins/wp-coding-agents-source-reconcile.php" \
      "$SITE/wp-content/mu-plugins/wp-coding-agents-runtime-guard.php"

cat > "$TMP/wp" <<'WP'
#!/bin/bash
# Stub: `wp option get <name>`
for a in "$@"; do case "$a" in --path=*) ;; esac; done
case "$3" in
  wp_coding_agents_source_mode)   echo owned ;;
  wp_coding_agents_owned_sources) printf 'wp-content/plugins/acme-core\nwp-content/themes/acme\n' ;;
  *) : ;;
esac
WP
chmod +x "$TMP/wp"

write_manifest() { printf '%s\n' "$@" > "$TMP/manifest/site/owned-sources"; chmod 644 "$TMP/manifest/site/owned-sources"; }
write_opencode() {
  python3 - "$SITE/opencode.json" "$@" <<'PY'
import json, sys
out = sys.argv[1]
allows = sys.argv[2:]
rules = {}
for d in ("wp-admin/**","wp-includes/**","wp-content/plugins/**","wp-content/themes/**","wp-config.php"):
    rules[d] = "deny"
for a in allows:
    rules[a + "/**"] = "allow"
json.dump({"permission": {"edit": rules}}, open(out, "w"), indent=2)
PY
}
write_unit() {
  # $1 name, $2 User, $3 HOME, [$4 extra Environment line]
  { printf '[Service]\nUser=%s\nEnvironment=HOME=%s\n' "$2" "$3"
    [ -n "${4:-}" ] && printf '%s\n' "$4"
    printf 'ExecStart=/bin/true\n'
  } > "$TMP/units/$1"
}

run_verify() {
  PATH="$TMP:$PATH" \
  SYSTEMD_UNIT_DIR="$TMP/units" \
  SOURCE_POLICY_MANIFEST_ROOT="$TMP/manifest" \
    bash verify.sh --site-path "$SITE" 2>&1 || true
}

# Baseline: everything agrees.
write_manifest wp-content/plugins/acme-core wp-content/themes/acme
write_opencode wp-content/plugins/acme-core wp-content/themes/acme
write_unit kimaki.service opencode /home/opencode

echo "verify: a healthy install passes"
OUT="$(run_verify)"
refute_contains "$OUT" "FAIL" "no complaints when every seam agrees"
assert_contains "$OUT" "permission.edit allows exactly the declared set" "checks the permission seam"
assert_contains "$OUT" "manifest agrees with the recorded set" "checks the manifest seam"

if PATH="$TMP:$PATH" SYSTEMD_UNIT_DIR="$TMP/units" SOURCE_POLICY_MANIFEST_ROOT="$TMP/manifest" bash verify.sh --site-path "$SITE" --quiet; then
  echo "  ok   exits 0 when healthy"
else
  echo "  FAIL healthy install exited non-zero"
  FAILED=$((FAILED + 1))
fi

echo ""
echo "verify: it catches the defects that reached a live site"

# 1. The identity bug. The migration rendered User=opencode with HOME=/root, and
#    the agent would have started with a home it cannot read. Nothing owned the
#    relationship between those two lines.
write_unit kimaki.service opencode /root
OUT="$(run_verify)"
assert_contains "$OUT" "User=opencode but HOME=/root" "catches a User/HOME mismatch"

# 2. A value left pointing into the home the install migrated away from. PATH and
#    KIMAKI_DATA_DIR both did this; enumerating key names would have missed it.
write_unit kimaki.service opencode /home/opencode "Environment=KIMAKI_DATA_DIR=/root/.kimaki"
OUT="$(run_verify)"
assert_contains "$OUT" "points outside opencode's home" "catches a stale value from the old identity"

write_unit kimaki.service opencode /home/opencode

# 3. Manifest drift. Capture reads the manifest; permissions come from the
#    option. Disagreement means the agent edits what nothing records.
write_manifest wp-content/plugins/acme-core wp-content/plugins/GONE
OUT="$(run_verify)"
assert_contains "$OUT" "manifest disagrees with the recorded set" "catches manifest drift"
assert_contains "$OUT" "acme-core" "names both sides of the disagreement"

# 4. Manifest missing entirely — the state h44lacrosse.com was in after the
#    first release that was supposed to create it.
rm -f "$TMP/manifest/site/owned-sources"
OUT="$(run_verify)"
assert_contains "$OUT" "manifest missing" "catches a missing manifest"
write_manifest wp-content/plugins/acme-core wp-content/themes/acme

# 5. A deny removed. This is the one that matters most: it is the difference
#    between an agent that cannot touch a payment gateway and one that can.
python3 - "$SITE/opencode.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["permission"]["edit"].pop("wp-content/plugins/**", None)
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
OUT="$(run_verify)"
assert_contains "$OUT" "NOT denied: wp-content/plugins/**" "catches a removed deny"
write_opencode wp-content/plugins/acme-core wp-content/themes/acme

# 6. Permissions that do not match the declaration.
write_opencode wp-content/plugins/acme-core
OUT="$(run_verify)"
assert_contains "$OUT" "permission.edit disagrees with the declared set" "catches declared-but-not-allowed"
write_opencode wp-content/plugins/acme-core wp-content/themes/acme

# 7. A missing owned-mode component.
mv "$SITE/wp-content/mu-plugins/wp-coding-agents-source-reconcile.php" "$TMP/held"
OUT="$(run_verify)"
assert_contains "$OUT" "wp-coding-agents-source-reconcile is missing" "catches a half-applied owned mode"
mv "$TMP/held" "$SITE/wp-content/mu-plugins/wp-coding-agents-source-reconcile.php"

echo ""
echo "verify: failure is reported, not repaired"

# A checker that fixes what it finds cannot be trusted to report honestly, and
# the failure it hides is the one worth seeing.
write_manifest wp-content/plugins/acme-core wp-content/plugins/GONE
run_verify >/dev/null
if grep -q 'GONE' "$TMP/manifest/site/owned-sources"; then
  echo "  ok   a broken manifest is left broken"
else
  echo "  FAIL verify repaired the manifest instead of reporting it"
  FAILED=$((FAILED + 1))
fi

if PATH="$TMP:$PATH" SYSTEMD_UNIT_DIR="$TMP/units" SOURCE_POLICY_MANIFEST_ROOT="$TMP/manifest" bash verify.sh --site-path "$SITE" --quiet; then
  echo "  FAIL exited 0 despite a disagreement"
  FAILED=$((FAILED + 1))
else
  echo "  ok   exits non-zero on disagreement"
fi

# An invariant that could not be checked must not report as healthy.
OUT="$(run_verify)"
assert_contains "$OUT" "skip" "unverifiable invariants are skipped, not passed"

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "verify: all assertions passed"
else
  echo "verify: $FAILED assertion(s) failed"
  exit 1
fi
