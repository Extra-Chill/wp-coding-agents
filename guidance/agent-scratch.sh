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
Scratch files, ad-hoc clones, and build output live under `$TMPDIR`, the bind-mounted `/tmp` inside systemd services, and are reclaimed after the configured age.
Python deps use `uv run --with <pkgs> script.py` or `uvx <tool>`, with `UV_CACHE_DIR` under `$TMPDIR`; never `pip install --user` or `--break-system-packages`.
Ad-hoc Cargo builds use `CARGO_TARGET_DIR` under `$TMPDIR`. Long-lived work belongs in a Homeboy worktree.
MD
}
