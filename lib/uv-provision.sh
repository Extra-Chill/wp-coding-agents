#!/bin/bash
# managed-vps: pinned, checksum-verified uv in harness-owned storage, not ~/.local.
# potrace/fontforge/inkscape are intentionally NOT provisioned: Python packages
# via uv (potracer, fonttools, scikit-image, pillow) cover the need without large
# GUI dependency trees. Agents keep environments and caches in scratch space.

UV_PROVISION_VERSION="${UV_PROVISION_VERSION:-0.6.17}"
UV_PROVISION_LIB_DIR="${UV_PROVISION_LIB_DIR:-/usr/local/lib/wp-coding-agents/uv}"
UV_PROVISION_BIN_DIR="${UV_PROVISION_BIN_DIR:-${SYSTEMS_CAPABILITIES_BIN_DIR:-/usr/local/bin}}"
UV_PROVISION_RELEASE_URL="${UV_PROVISION_RELEASE_URL:-https://github.com/astral-sh/uv/releases/download}"

uv_provision_healthy() {
  local version
  [ -x "$UV_PROVISION_LIB_DIR/uv" ] && [ -x "$UV_PROVISION_LIB_DIR/uvx" ] || return 1
  version="$("$UV_PROVISION_LIB_DIR/uv" --version 2>/dev/null)" || return 1
  [ "$version" = "uv $UV_PROVISION_VERSION" ] || [[ "$version" == "uv $UV_PROVISION_VERSION "* ]]
}

uv_provision_download() {
  local arch asset url tmp_dir expected actual
  arch="$(uname -m)" || return 1
  case "$arch" in
    x86_64|aarch64) ;;
    *) warn "Unsupported uv architecture: $arch"; return 1 ;;
  esac
  asset="uv-$arch-unknown-linux-gnu"
  url="$UV_PROVISION_RELEASE_URL/$UV_PROVISION_VERSION/$asset.tar.gz"
  tmp_dir="$(mktemp -d)" || return 1
  if ! curl -fsSL "$url" -o "$tmp_dir/uv.tar.gz" ||
     ! curl -fsSL "$url.sha256" -o "$tmp_dir/uv.sha256"; then
    warn "Could not download uv or its checksum — refusing to install"
    rm -rf "$tmp_dir"
    return 1
  fi
  # Releases publish a hex digest (also accept the standard sha256sum format).
  expected="$(awk 'NR == 1 {print $1}' "$tmp_dir/uv.sha256")"
  actual="$(sha256sum "$tmp_dir/uv.tar.gz")" || actual=""
  actual="${actual%% *}"
  if ! [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || [ "$expected" != "$actual" ]; then
    warn "uv SHA-256 checksum mismatch — refusing to install"
    rm -rf "$tmp_dir"
    return 1
  fi
  if ! tar -xzf "$tmp_dir/uv.tar.gz" -C "$tmp_dir" "$asset/uv" "$asset/uvx" ||
     ! mkdir -p "$UV_PROVISION_LIB_DIR" ||
     ! install -m 0755 "$tmp_dir/$asset/uv" "$tmp_dir/$asset/uvx" "$UV_PROVISION_LIB_DIR/"; then
    warn "Could not extract/install uv"
    rm -rf "$tmp_dir"
    return 1
  fi
  rm -rf "$tmp_dir"
}

# Explicitly guard every mutating step: called under set -e, but provisioning
# must remain best-effort even on download, extraction, or filesystem failure.
uv_provision_apply() {
  systems_capabilities_enabled || return 0
  [ "$LOCAL_MODE" = false ] || return 0
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would install uv $UV_PROVISION_VERSION at $UV_PROVISION_LIB_DIR and expose uv/uvx in $UV_PROVISION_BIN_DIR"
    return 0
  fi
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    warn "uv provisioning requires root — run ./upgrade.sh --systems-capabilities managed-vps as root"
    return 0
  fi
  local tool
  for tool in curl sha256sum tar install; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      warn "$tool is not on PATH — cannot provision uv"
      return 0
    fi
  done
  if ! uv_provision_healthy; then
    if ! uv_provision_download; then
      warn "uv provisioning failed — continuing upgrade"
      return 0
    fi
    UPDATED_ITEMS+=("uv refreshed ($UV_PROVISION_VERSION)")
  fi
  for tool in uv uvx; do
    if [ "$(readlink "$UV_PROVISION_BIN_DIR/$tool" 2>/dev/null)" != "$UV_PROVISION_LIB_DIR/$tool" ]; then
      if ! mkdir -p "$UV_PROVISION_BIN_DIR" || ! ln -sfn "$UV_PROVISION_LIB_DIR/$tool" "$UV_PROVISION_BIN_DIR/$tool"; then
        warn "Could not expose $tool in $UV_PROVISION_BIN_DIR — continuing upgrade"
        return 0
      fi
      UPDATED_ITEMS+=("uv capability link installed ($UV_PROVISION_BIN_DIR/$tool)")
    fi
  done
  return 0
}
