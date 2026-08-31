#!/bin/bash
# tests/owned-source-discovery.sh — deriving the owned set from site state.
#
# The property that matters here is not "does it find the right plugins". It is
# that it CANNOT WIDEN ON MISSING EVIDENCE.
#
# The wp.org signal is a transient. On a fresh install, after a cache flush, or
# when wp.org is unreachable, it is absent — and if absence were treated as "no
# plugin is known to wp.org", every plugin would classify as the site's. On
# h44lacrosse.com that means handing a coding agent write access to WooCommerce
# and a Stripe payment gateway, produced by a piece of automation whose whole
# purpose is to be safer than an operator doing it by hand.
#
# So ownership is inferred only from the PRESENCE of evidence. Every assertion
# below about a missing, empty, or stale signal is really the same assertion:
# the derivation refuses rather than guesses, and the caller keeps the last
# recorded set.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

FAILED=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [ "$got" = "$want" ]; then echo "  ok   $name"; else
    echo "  FAIL $name"; echo "         got:  $got"; echo "         want: $want"
    FAILED=$((FAILED + 1))
  fi
}
assert_contains() {
  case "$1" in *"$2"*) echo "  ok   $3" ;; *) echo "  FAIL $3 (missing: $2)"; FAILED=$((FAILED + 1)) ;; esac
}
refute_contains() {
  case "$1" in *"$2"*) echo "  FAIL $3 (unexpectedly present: $2)"; FAILED=$((FAILED + 1)) ;; *) echo "  ok   $3" ;; esac
}
# Slug-exact. A substring test cannot tell `plugins/data-machine` from
# `plugins/data-machine-business`, which is exactly the pair this file has to
# distinguish: one is the agent's runtime, the other a vendor plugin.
refute_line() {
  if printf '%s\n' "$1" | grep -qxF "$2"; then
    echo "  FAIL $3 (unexpectedly present: $2)"; FAILED=$((FAILED + 1))
  else
    echo "  ok   $3"
  fi
}
assert_line() {
  if printf '%s\n' "$1" | grep -qxF "$2"; then echo "  ok   $3"; else
    echo "  FAIL $3 (missing line: $2)"; FAILED=$((FAILED + 1))
  fi
}

log() { :; }; warn() { :; }; info() { :; }
error() { echo "ERROR: $1" >&2; exit 1; }
# shellcheck disable=SC1091
source lib/owned-source-discovery.sh

# A stand-in for the real site, modelled on h44lacrosse.com's actual inventory.
# SIGNAL controls what the wp.org transient looks like: fresh | stale | missing | empty
make_site() {
  SIGNAL="${1:-fresh}"
  owned_discovery_supported() { return 0; }
  _owned_discovery_eval() {
    case "$1" in
      *update_plugins*last_checked*)
        case "$SIGNAL" in
          fresh)   echo 60 ;;
          stale)   echo 999999 ;;
          missing) echo missing ;;
          empty)   echo empty ;;
        esac ;;
      *get_plugins*)
        cat <<'EOF'
plugins akismet
plugins data-machine
plugins data-machine-business
plugins data-machine-code
plugins fluent-smtp
plugins h44-core
plugins h44-forms
plugins hello
plugins woocommerce
plugins woocommerce-gateway-stripe
themes h44-lacrosse-theme
themes twentytwentyfive
EOF
        ;;
      *update_themes*|*array_unique*)
        [ "$SIGNAL" = "fresh" ] || return 0
        cat <<'EOF'
woocommerce
akismet
hello
fluent-smtp
woocommerce-gateway-stripe
twentytwentyfive
EOF
        ;;
    esac
  }
}

echo "owned-source-discovery: derives the site's own components"

make_site fresh
OWNED_DISCOVERY_EXCLUSIONS=""
_source_policy_option_read() { return 0; }
DERIVED="$(owned_discovery_derive)"

assert_line "$DERIVED" "wp-content/plugins/h44-core" "finds a site plugin"
assert_line "$DERIVED" "wp-content/plugins/h44-forms" "finds a second site plugin"
assert_line "$DERIVED" "wp-content/themes/h44-lacrosse-theme" "finds the site theme"

# wp.org plugins are not the site's. Editing them is futile — the next update
# overwrites it — quite apart from WooCommerce being a payment surface.
for p in woocommerce woocommerce-gateway-stripe akismet fluent-smtp hello; do
  refute_line "$DERIVED" "wp-content/plugins/$p" "excludes wp.org plugin $p"
done
refute_line "$DERIVED" "wp-content/themes/twentytwentyfive" "excludes a wp.org bundled theme"

# The agent's own runtime is replaced wholesale by the next upgrade, and
# capturing it would commit this project's source into the site's repository.
for p in data-machine data-machine-code wp-codebox wp-coding-agents-integration ai-provider-for-claude-code; do
  refute_line "$DERIVED" "wp-content/plugins/$p" "excludes carried plugin $p"
done

echo ""
echo "owned-source-discovery: the exclusion escape hatch"

# A vendor plugin is on nobody's wp.org list and is not carried, so it derives
# as owned. It is no more the site's than WooCommerce is, and capturing it may
# put licensed code in the operator's repository. Measured on h44lacrosse.com:
# data-machine-business is exactly this case.
assert_line "$DERIVED" "wp-content/plugins/data-machine-business" \
  "a vendor plugin derives as owned without an exclusion (the false positive)"

OWNED_DISCOVERY_EXCLUSIONS="data-machine-business"
EXCLUDED_DERIVED="$(owned_discovery_derive)"
refute_contains "$EXCLUDED_DERIVED" "data-machine-business" "an exclusion removes it"
assert_line "$EXCLUDED_DERIVED" "wp-content/plugins/h44-core" "and leaves the real components"

# Slugs only: a path here would name something no installed component matches,
# and fail silently.
for bad in "wp-content/plugins/x" "" "two words"; do
  out=$(bash -c '
    error() { echo "ERROR: $1"; exit 1; }
    source lib/owned-source-discovery.sh
    owned_discovery_add_exclusion "'"$bad"'"
  ' 2>&1 || true)
  assert_contains "$out" "takes a plugin or theme slug" "--not-owned rejects '$bad'"
done

echo ""
echo "owned-source-discovery: NEVER widens on missing evidence"

# Each of these is the same danger in a different costume: absence of the wp.org
# signal must not be read as "nothing belongs to wp.org".
for signal in missing empty stale; do
  make_site "$signal"
  OWNED_DISCOVERY_EXCLUSIONS=""
  if out="$(owned_discovery_derive)"; then
    echo "  FAIL derived from a $signal signal instead of refusing"
    FAILED=$((FAILED + 1))
  else
    echo "  ok   refuses to derive from a $signal signal"
  fi
  if [ -n "${out:-}" ]; then
    echo "  FAIL a $signal signal produced output: $out"
    FAILED=$((FAILED + 1))
  fi
done

# The specific catastrophe, asserted directly rather than implied: a missing
# signal must never be the reason a payment plugin becomes editable.
make_site missing
out="$(owned_discovery_derive || true)"
refute_contains "$out" "woocommerce" "a missing signal cannot open WooCommerce"
refute_contains "$out" "stripe" "a missing signal cannot open the payment gateway"

echo ""
echo "owned-source-discovery: wiring"

# Derivation must beat the recorded set, or a plugin the agent creates never
# becomes editable and this changes nothing. It must LOSE to explicit flags,
# which are the operator overriding deliberately.
# Comments explaining the precedence legitimately name the functions in a
# different order than the code calls them, so order is checked on code only.
policy="$(sed -n '/^source_policy_resolve_owned_sources/,/^}/p' lib/source-policy.sh | sed 's/#.*//')"
assert_contains "$policy" 'OWNED_SOURCES_EXPLICIT' "explicit flags are checked"
assert_contains "$policy" "owned_discovery_derive" "derivation is consulted"
assert_contains "$policy" "source_policy_recorded_owned_sources" "recorded set is the fallback"

explicit_line=$(printf '%s\n' "$policy" | grep -n 'OWNED_SOURCES_EXPLICIT' | head -1 | cut -d: -f1)
derive_line=$(printf '%s\n' "$policy" | grep -n 'owned_discovery_derive' | head -1 | cut -d: -f1)
recorded_line=$(printf '%s\n' "$policy" | grep -n 'source_policy_recorded_owned_sources' | head -1 | cut -d: -f1)
if [ "$explicit_line" -lt "$derive_line" ] && [ "$derive_line" -lt "$recorded_line" ]; then
  echo "  ok   precedence is explicit > derived > recorded"
else
  echo "  FAIL precedence wrong (explicit=$explicit_line derive=$derive_line recorded=$recorded_line)"
  FAILED=$((FAILED + 1))
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "owned-source-discovery: all assertions passed"
else
  echo "owned-source-discovery: $FAILED assertion(s) failed"
  exit 1
fi
