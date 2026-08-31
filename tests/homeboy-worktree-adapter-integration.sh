#!/bin/bash
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SITE_PATH="$TMP/site"
WORKSPACE="$TMP/workspace"
BIN="$TMP/bin"
LOG="$TMP/homeboy.log"
mkdir -p "$SITE_PATH/wp-content/mu-plugins" "$WORKSPACE/homeboy/.git" "$BIN"
WORKSPACE_REAL="$(cd "$WORKSPACE" && pwd -P)"

WP_CLI_VERSION="2.12.0"
WP_CLI_SHA256="ce34ddd838f7351d6759068d09793f26755463b4a4610a5a5c0a97b68220d85c"
WP_CLI_URL="https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar"
DMC_VERSION="0.74.1"
DMC_COMMIT="f9509db9168cdc1274237ce2e32f1179647bb756"
DMC_SHA256="45107900643a74e6a76b51b28cd7332aea68756ddb2eaac5f9360e0f9823b62b"
DMC_URL="https://codeload.github.com/Extra-Chill/data-machine-code/tar.gz/${DMC_COMMIT}"
HOMEBOY_RELEASE_VERSION="0.367.3"
HOMEBOY_RELEASE_BUILD="3fa0c185d41b"
HOMEBOY_RELEASE_TARGET=""
HOMEBOY_RELEASE_SHA256=""
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) HOMEBOY_RELEASE_TARGET="aarch64-apple-darwin"; HOMEBOY_RELEASE_SHA256="634731246fb92bc6846e2576552dc2c903f990b2252e161cf77645020e1e59e8" ;;
  Linux-x86_64) HOMEBOY_RELEASE_TARGET="x86_64-unknown-linux-gnu"; HOMEBOY_RELEASE_SHA256="cd373e81613de9140e5ada23189cca408ddd06a8160fb7cc4031cf536b9ea6e4" ;;
  Linux-aarch64) HOMEBOY_RELEASE_TARGET="aarch64-unknown-linux-gnu"; HOMEBOY_RELEASE_SHA256="c0726076f8ab6620e50e761a534240ee49e49b0046732474ed20ba974e1cf764" ;;
esac
FIXTURE_CACHE_DIR="${WP_CODING_AGENTS_FIXTURE_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME:-$TMP}/.cache}/wp-coding-agents/test-fixtures}"
mkdir -p "$FIXTURE_CACHE_DIR"

verify_sha256() {
  printf '%s  %s\n' "$1" "$2" | shasum -a 256 -c - >/dev/null 2>&1
}

download_verified() {
  local url="$1" sha256="$2" destination="$3" download
  download="$TMP/$(basename "$destination").download"
  if [ -f "$destination" ] && verify_sha256 "$sha256" "$destination"; then
    return
  fi
  rm -f "$destination" "$download"
  curl --fail --location --silent --show-error --retry 3 --connect-timeout 10 --max-time 120 --output "$download" "$url"
  if ! verify_sha256 "$sha256" "$download"; then
    echo "FAIL: downloaded fixture failed pinned SHA-256 verification: $url" >&2
    rm -f "$download"
    return 1
  fi
  mv "$download" "$destination"
}

WP_CLI_PHAR="$FIXTURE_CACHE_DIR/wp-cli-${WP_CLI_VERSION}-${WP_CLI_SHA256}.phar"
DMC_ARCHIVE="$FIXTURE_CACHE_DIR/data-machine-code-${DMC_VERSION}-${DMC_COMMIT}-${DMC_SHA256}.tar.gz"
download_verified "$WP_CLI_URL" "$WP_CLI_SHA256" "$WP_CLI_PHAR"
download_verified "$DMC_URL" "$DMC_SHA256" "$DMC_ARCHIVE"
# Recheck cache hits immediately before either upstream artifact is loaded.
verify_sha256 "$WP_CLI_SHA256" "$WP_CLI_PHAR" || { echo "FAIL: cached WP-CLI checksum changed" >&2; exit 1; }
verify_sha256 "$DMC_SHA256" "$DMC_ARCHIVE" || { echo "FAIL: cached DMC checksum changed" >&2; exit 1; }

HOMEBOY_VERSION_OUTPUT="homeboy ${HOMEBOY_RELEASE_VERSION}+${HOMEBOY_RELEASE_BUILD}"
if [ -n "$HOMEBOY_RELEASE_TARGET" ]; then
  HOMEBOY_RELEASE_URL="https://github.com/Extra-Chill/homeboy/releases/download/v${HOMEBOY_RELEASE_VERSION}/homeboy-${HOMEBOY_RELEASE_TARGET}.tar.xz"
  HOMEBOY_RELEASE_ARCHIVE="$FIXTURE_CACHE_DIR/homeboy-${HOMEBOY_RELEASE_VERSION}-${HOMEBOY_RELEASE_TARGET}-${HOMEBOY_RELEASE_SHA256}.tar.xz"
  download_verified "$HOMEBOY_RELEASE_URL" "$HOMEBOY_RELEASE_SHA256" "$HOMEBOY_RELEASE_ARCHIVE"
  verify_sha256 "$HOMEBOY_RELEASE_SHA256" "$HOMEBOY_RELEASE_ARCHIVE" || { echo "FAIL: cached Homeboy checksum changed" >&2; exit 1; }
  mkdir -p "$TMP/homeboy-release"
  tar -xJf "$HOMEBOY_RELEASE_ARCHIVE" -C "$TMP/homeboy-release"
  OFFICIAL_HOMEBOY="$TMP/homeboy-release/homeboy-${HOMEBOY_RELEASE_TARGET}/homeboy"
  [ -x "$OFFICIAL_HOMEBOY" ] || { echo "FAIL: pinned Homeboy archive omitted its executable" >&2; exit 1; }
  HOMEBOY_VERSION_OUTPUT="$("$OFFICIAL_HOMEBOY" --version)"
  [ "$HOMEBOY_VERSION_OUTPUT" = "homeboy ${HOMEBOY_RELEASE_VERSION}+${HOMEBOY_RELEASE_BUILD}" ] || { echo "FAIL: pinned Homeboy release returned unexpected version output" >&2; exit 1; }
fi

DMC_FIXTURE_ROOT="$TMP/data-machine-code-${DMC_COMMIT}"
mkdir -p "$DMC_FIXTURE_ROOT"
tar -xzf "$DMC_ARCHIVE" --strip-components=1 -C "$DMC_FIXTURE_ROOT"
for source in inc/Cli/Commands/WorkspaceCommand.php inc/Cli/CliResponseRenderer.php inc/Workspace/WorktreeContextInjector.php; do
  [ -f "$DMC_FIXTURE_ROOT/$source" ] || { echo "FAIL: pinned DMC archive omitted $source" >&2; exit 1; }
done

cat > "$BIN/homeboy" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HOMEBOY_ADAPTER_TEST_LOG"
if [ "$*" = "--version" ]; then
  if [ "${HOMEBOY_VERSION+x}" = x ]; then
    printf 'homeboy %s\n' "$HOMEBOY_VERSION"
  else
    printf '%s\n' "$HOMEBOY_VERSION_OUTPUT"
  fi
  exit 0
fi
if [ "${HOMEBOY_LEGACY:-false}" = true ]; then
  case "$*" in
    worktree\ create\ *\ --branch\ *\ --require-handoff-freshness\ --from\ *)
      printf '%s\n' "error: unexpected argument '--require-handoff-freshness' found" >&2
      exit 2
      ;;
  esac
fi
case "$*" in
  "worktree create $HOMEBOY_TEST_REPOSITORY_PATH --branch fix/534-adapter-defaults --require-handoff-freshness --from origin/main --task-url https://github.com/Extra-Chill/wp-coding-agents/issues/534 --run-id studio-run-534 --cleanup-policy remove-when-safe")
    printf '%s\n' '{"schema":"homeboy/command-result/v3","success":true,"data":{"record":{"id":"homeboy@fix-534-adapter-defaults","component_id":"homeboy","worktree_path":"/workspace/homeboy@fix-534-adapter-defaults","branch":"fix/534-adapter-defaults","base_ref":"origin/main","run_id":"studio-run-534","state":"active"},"handoff_freshness":{"status":"verified","proof":{"proof_id":"proof-534","worktree_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","resolved_base_ref":"origin/main","resolved_base_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","remote_default_ref":"refs/remotes/origin/main","remote_default_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","remote_default_advertised_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","verified_at":"2026-08-31T00:00:00Z"}}}}'
    ;;
  "worktree create $HOMEBOY_TEST_REPOSITORY_PATH --branch fix/534-adapter-defaults --from origin/main --task-url https://github.com/Extra-Chill/wp-coding-agents/issues/534 --run-id studio-run-534 --cleanup-policy remove-when-safe")
    printf '%s\n' '{"schema":"homeboy/command-result/v3","success":true,"data":{"record":{"id":"homeboy@fix-534-adapter-defaults","component_id":"homeboy","worktree_path":"/workspace/homeboy@fix-534-adapter-defaults","branch":"fix/534-adapter-defaults","base_ref":"origin/main","run_id":"studio-run-534","state":"active"}}}'
    ;;
  *)
    printf '%s\n' '{"schema":"homeboy/command-result/v3","success":false,"summary":"unexpected integration command"}'
    exit 1
    ;;
esac
SH
chmod +x "$BIN/homeboy"

export PATH="$BIN:$PATH" HOMEBOY_ADAPTER_TEST_LOG="$LOG" HOMEBOY_TEST_REPOSITORY_PATH="$WORKSPACE_REAL/homeboy" HOMEBOY_VERSION_OUTPUT
SCRIPT_DIR="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/homeboy.sh"
UPDATED_ITEMS=()
DRY_RUN=false
service_file_normalize_perms() { chmod 0664 "$1"; }
homeboy_worktree_adapter_sync
ADAPTER="$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-homeboy-worktrees.php"

BOOTSTRAP="$ROOT_DIR/tests/fixtures/homeboy-worktree-adapter-dispatch.php"
export HOMEBOY_ADAPTER_PATH="$ADAPTER"
export WP_CLI_PHAR
export DMC_FIXTURE_ROOT
export DMC_WORKSPACE_PATH="$WORKSPACE_REAL"
export DMC_FINALIZER_LOG="$TMP/finalizer.log"
WP=(php -d error_reporting=22527 "$BOOTSTRAP")

COMMAND=("${WP[@]}" datamachine-code workspace worktree add homeboy fix/534-adapter-defaults --from=origin/main --task-url=https://github.com/Extra-Chill/wp-coding-agents/issues/534 --reuse-policy=isolated --owner-run-ref=studio-run-534 --cleanup-policy=remove_on_success --format=json)
RESULT="$("${COMMAND[@]}")"
php -r '$r=json_decode($argv[1],true); if (($r["success"]??false)!==true || ($r["context_injected"]??true)!==false || ($r["handoff_freshness"]["status"]??null)!=="verified") exit(1);' "$RESULT"
[ "$(grep -c "^worktree create $WORKSPACE_REAL/homeboy " "$LOG")" -eq 1 ]
grep -q -- '--require-handoff-freshness' "$LOG"
[ "$(grep -c '^finalized$' "$DMC_FINALIZER_LOG")" -eq 1 ]

HELP="$("${WP[@]}" --dispatcher-help)"
for FLAG in inject-context bootstrap skip-context-injection skip-bootstrap; do
	grep -q -- "--$FLAG" <<< "$HELP"
done
grep -q 'context injection and dependency bootstrap are omitted by default' <<< "$HELP"

if "${WP[@]}" datamachine-code workspace worktree add homeboy invalid --unknown-adapter-flag >/dev/null 2>&1; then
  echo "FAIL: registered WP-CLI synopsis accepted an unknown flag" >&2
  exit 1
fi

: > "$LOG"
"${WP[@]}" datamachine-code workspace worktree add homeboy native-purpose --purpose=issue-534 --format=json >/dev/null
[ ! -s "$LOG" ] || { echo "FAIL: non-empty purpose reached Homeboy instead of native DMC" >&2; exit 1; }

: > "$LOG"
HOMEBOY_VERSION=0.367.2 "${COMMAND[@]}" >/dev/null
grep -q '^--version$' "$LOG"
if grep -q '^worktree create ' "$LOG"; then
  echo "FAIL: pre-0.367.3 Homeboy received an unsupported repository path" >&2
  exit 1
fi

: > "$LOG"
"${WP[@]}" datamachine-code workspace worktree add homeboy explicit-context --inject-context --format=json >/dev/null
[ ! -s "$LOG" ] || { echo "FAIL: explicit context injection reached Homeboy instead of native DMC" >&2; exit 1; }
"${WP[@]}" datamachine-code workspace worktree add homeboy explicit-bootstrap --bootstrap --format=json >/dev/null
[ ! -s "$LOG" ] || { echo "FAIL: explicit dependency bootstrap reached Homeboy instead of native DMC" >&2; exit 1; }

: > "$LOG"
if LEGACY="$(HOMEBOY_LEGACY=true "${COMMAND[@]}")"; then
  echo "FAIL: legacy Homeboy unexpectedly created a strict-freshness worktree" >&2
  exit 1
fi
php -r '$e=json_decode($argv[1],true)["error"]??array(); if (($e["code"]??null)!=="worktree_handoff_freshness_unverified" || ($e["data"]["remediation"]??null)!=="upgrade_homeboy") exit(1);' "$LEGACY"
[ "$(grep -c "^worktree create $WORKSPACE_REAL/homeboy " "$LOG")" -eq 1 ]
grep -q -- '--require-handoff-freshness' "$LOG"

: > "$LOG"
FALLBACK="$(HOMEBOY_LEGACY=true "${COMMAND[@]}" --allow-unverified-freshness)"
php -r '$r=json_decode($argv[1],true); if (($r["handoff_freshness"]["status"]??null)!=="unverified") exit(1);' "$FALLBACK"
[ "$(grep -c "^worktree create $WORKSPACE_REAL/homeboy " "$LOG")" -eq 2 ]
grep -q -- '--require-handoff-freshness' "$LOG"

: > "$LOG"
SKIP_ALIAS="$("${COMMAND[@]}" --skip-context-injection --skip-bootstrap)"
php -r '$r=json_decode($argv[1],true); if (($r["success"]??false)!==true) exit(1);' "$SKIP_ALIAS"

if "${WP[@]}" datamachine-code workspace worktree add homeboy conflicting-context --inject-context --skip-context-injection >/dev/null 2>&1; then
  echo "FAIL: conflicting context flags unexpectedly succeeded" >&2
  exit 1
fi

for SKEW_MODE in arity types return definition; do
  SKEW="$(DMC_VERSION_SKEW="$SKEW_MODE" "${WP[@]}" datamachine-code workspace worktree add homeboy version-skew)"
  [ "$SKEW" = 'native-version-skew-command' ] || { echo "FAIL: $SKEW_MODE skew replaced native registration" >&2; exit 1; }
done

echo "OK: real WP-CLI 2.12.0 dispatch and pinned production DMC 0.74.1 command-class compatibility retain version-skew safety"
