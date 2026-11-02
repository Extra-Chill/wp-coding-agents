#!/bin/bash
# Scratch placement is generic runtime policy, independent of tool vendors.
guidance_id() { printf 'agent-scratch'; }
guidance_priority() { printf '25'; }
guidance_label() { printf 'Agent scratch'; }
guidance_description() { printf 'Keep temporary work off the system volume.'; }
guidance_applies() { [ -n "${AGENT_TMPDIR:-}" ]; }
guidance_render() {
  cat <<'MD'
## Agent scratch
Put scratch files, ad-hoc clones, and build output under `$TMPDIR` or a managed worktree, never a hardcoded `/tmp/...` path.
For ad-hoc Cargo builds, set `CARGO_TARGET_DIR` to a directory under `$TMPDIR`.
MD
}
