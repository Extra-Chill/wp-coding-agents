---
name: wp-coding-agents-setup
description: "Orchestrate wp-coding-agents setup on a VPS or local WordPress install by collecting a setup profile, compiling the exact setup.sh command, dry-running it, and guiding verification."
compatibility: "For VPS: requires SSH access, Ubuntu/Debian recommended. For local: requires an existing WordPress install (WordPress Studio, MAMP, manual, etc.) and Node.js."
---

# WP Coding Agents Setup

Use this skill from the operator's **local machine** to install wp-coding-agents on a remote VPS or an existing local WordPress install. Once the runtime and chat bridge are installed, the new site agent takes over ongoing WordPress management.

This skill is only the orchestrator. Keep the setup matrix composable:

```text
wp-coding-agents-setup
  -> wp-coding-agents-setup-interview
  -> scripts/compile-setup-profile.mjs
  -> dry-run setup command
  -> confirmed setup command
  -> wp-coding-agents-setup-verify
```

## Source Of Truth

Use the scripts for operational details:

| Need | Source |
|---|---|
| Current setup flags and environment variables | `./setup.sh --help` |
| Setup profile compilation | `node scripts/compile-setup-profile.mjs <profile.json>` |
| Runtime implementations | `runtimes/*.sh` |
| Chat bridge implementations | `bridges/*.sh` and `bridges/_dispatch.sh` |
| Homeboy setup behavior | `lib/homeboy.sh` |
| WordPress/WP-CLI behavior | `lib/wordpress.sh` |
| Upgrade behavior | `./upgrade.sh --help` and `upgrade-wp-coding-agents` |

Do not duplicate script internals in this skill. Compile commands from the user's setup profile, then verify against script output.

## Procedure

1. **Clone or enter the repo.**
   ```bash
   git clone https://github.com/Extra-Chill/wp-coding-agents.git
   cd wp-coding-agents
   ./setup.sh --help
   ```

2. **Run the interview skill.**
   Use `wp-coding-agents-setup-interview` to collect a structured JSON setup profile. The interview collects facts only; it does not choose commands or verification steps.

3. **Run the deterministic compiler script.**
   Save the profile to a temporary JSON file or pipe it on stdin, then run `node scripts/compile-setup-profile.mjs <profile.json>` to turn the profile into:
   - the exact setup command,
   - the dry-run command,
   - verification overlay names.

   If the compiler rejects the profile, fix the profile or the setup script. Do not hand-compile around the failure.

4. **Summarize the compiled plan before execution.**
   Include target, WordPress path or domain, runtime axis, bridge axis, optional overlays, and the exact dry-run command. Ask for explicit confirmation before running setup for real.

5. **Dry-run first.**
   Always run the compiled command with `--dry-run` before making changes. Read the output and stop if target paths, runtime, bridge, Homeboy behavior, or WP-CLI command selection look wrong.

6. **Run setup after confirmation.**
   Drop `--dry-run` from the compiled command. Do not restart an existing live chat bridge unless the user explicitly asks; for a new install, follow the script's post-setup guidance.

7. **Run the verification skill.**
   Use `wp-coding-agents-setup-verify` with the compiler script's verification overlay names. Report exact failures and source them back to the relevant axis: install target, runtime, bridge, or optional overlay.

## Policy Boundaries

- Treat install target, runtime, chat bridge, and optional overlays as independent axes, not nested local/VPS branches.
- Preserve user state. Do not rewrite existing runtime config or chat auth files outside what `setup.sh` is designed to manage.
- Keep Codebox minion provider auth separate from optional WP AI Gateway external-client setup.
- Keep Homeboy external to wp-coding-agents. The WordPress site root is a Homeboy project, not a component.
- Use `WP_CMD="studio wp"` for WordPress Studio installs when the compiler selects that overlay.
- Use `--with-homeboy` only when the user wants the optional developer layer.
- Use `--no-chat` when the user wants terminal/SSH-only operation.
- Use `--with-skills` only when the user explicitly wants optional wp-coding-agents setup/upgrade skills installed into the target runtime.

## When To Use

Use when the user says things like:

- "Help me install wp-coding-agents on my server"
- "Set up a coding agent on this VPS"
- "Add Claude Code / OpenCode to my existing WordPress site"
- "Set up a local AI agent on my machine"
- "Install wp-coding-agents with WordPress Studio"
- "Set it up with Homeboy"
- "Enable repo-aware Homeboy workflows"

Do not use this for routine WordPress management after setup. The installed agent should handle that from its site-specific context.
