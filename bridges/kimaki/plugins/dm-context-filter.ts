// dm-context-filter.ts — OpenCode plugin for WordPress agent VPSes with Data Machine.
//
// Strips Kimaki built-in features from the agent context when Data Machine
// owns the corresponding memory, scheduling, or site-runtime policy.
//
// What it removes from the system prompt:
// 1. Scheduling — Data Machine owns recurring automation, flows, jobs, and
//    reminders, so the agent should not learn a second scheduler path.
// 2. Tunnel / dev server — DM-managed
//    WordPress installs already have a site runtime (Studio locally, a live
//    site on VPS). Tunnels are task-specific for inbound public URLs like
//    webhooks/OAuth callbacks, not the default way to interact with the site.
// 3. Permissions — metadata describing which Discord roles can message the
//    bot. The agent has no capability to act on this; pure metadata leakage.
// 4. Upgrading kimaki — the /upgrade-and-restart playbook. The user
//    runs the slash command themselves when they want to upgrade.
// 5. Reading other sessions — cross-session discovery commands such as
//    `kimaki session list
//    --project` / `session search --channel <id>`. These are cross-project
//    discovery vectors; on a single-project fleet server the agent only ever
//    needs to list sessions in the current project (no flags required).
//
// What it intentionally keeps under Kimaki 0.13:
// - Generic `--agent <current_agent>` examples. Kimaki now falls back to the
//   build agent when a requested agent does not exist, so Data Machine no
//   longer needs prompt surgery to compensate for runtime-agent names.
// - Critique instructions. wp-coding-agents starts managed Kimaki services with
//   `--no-critique`, so the section is absent before this filter runs.
//
// This plugin is strip-only. Positive guidance about how to use Kimaki's
// session bridge or the WordPress site runtime belongs in Data Machine's
// instruction stack (AGENTS.md, SOUL.md, SITE.md, etc.) — not pre-injected
// into every prompt by a runtime bridge filter. Bridge-specific guidance
// pre-injected here would recreate the same problem we're trying to solve:
// runtime-bridge concerns leaking into the generic agent context.
//
// NOTE: "## debugging kimaki issues" is intentionally kept — when Kimaki itself
// throws errors, the agent needs the kimaki.log path to investigate.
//
// What it removes from chat message injection:
// 8. MEMORY.md injection — Kimaki reads MEMORY.md from the project directory and
//    injects a condensed TOC. Conflicts with Data Machine's own memory files.
// 9. "Update MEMORY.md" time-gap reminder — Redundant with external memory system.
// Total savings depends on the Kimaki version and managed startup flags.
//
// How to use:
//   Add to opencode.json:  "plugin": ["/opt/kimaki-config/plugins/dm-context-filter.ts"]
//   Or place in .opencode/plugins/ in the project root.

/**
 * External dependencies
 */
import type { Plugin } from "@opencode-ai/plugin";

const fleetContextFilter: Plugin = async () => {
  return {
    // Strip sections from the system prompt.
    "experimental.chat.system.transform": async (_input, output) => {
      output.system = output.system.map((block) => {
        let result = block;
        result = stripSection(result, "## permissions");
        result = stripSection(result, "## upgrading kimaki");
        result = stripSection(result, "## scheduled sends and task management");
        result = stripSection(result, "## running dev servers with tunnel access");
        result = stripSection(result, "## reading other sessions");
        // Clean up leftover double/triple blank lines.
        result = result.replace(/\n{3,}/g, "\n\n");
        return result;
      });
    },

    // Filter out Kimaki's MEMORY.md injection and time-gap MEMORY.md reminders.
    "chat.message": async (_input, output) => {
      // Walk backwards so splice indices stay valid.
      for (let i = output.parts.length - 1; i >= 0; i--) {
        const part = output.parts[i];
        if (part.type !== "text" || !(part as any).synthetic) {
          continue;
        }
        const text = (part as any).text as string;
        if (!text) {
          continue;
        }

        // Remove MEMORY.md TOC injection.
        if (text.includes("Project memory from MEMORY.md")) {
          output.parts.splice(i, 1);
          continue;
        }

        // Remove "update MEMORY.md" time-gap reminder.
        if (text.includes("update MEMORY.md before starting the new task")) {
          output.parts.splice(i, 1);
          continue;
        }

      }
    },
  };
};

/**
 * Remove a markdown section from a system prompt block.
 *
 * @param {string} block   - System prompt block.
 * @param {string} heading - Section heading to remove.
 * @return {string} System prompt block without the requested section.
 */
function stripSection(block: string, heading: string): string {
  const lines = block.split("\n");
  const level = (heading.match(/^#+/) || ["##"])[0].length;

  // Find the heading line. Match exact (whole-line) so a heading like
  // "## scheduled sends and task management" doesn't accidentally match
  // "## scheduled sends and task management with a suffix".
  let start = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i] === heading) {
      start = i;
      break;
    }
  }
  if (start === -1) {
    return block;
  }

  // Walk forward looking for the next heading of the same or higher level
  // (i.e. fewer-or-equal `#` characters), tracking fenced-code-block state
  // so `# bash comments` inside ```bash``` are ignored.
  let inFence = false;
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    const line = lines[i];
    if (/^```/.test(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) {
      continue;
    }
    const m = line.match(/^(#{1,6})\s+\S/);
    if (m && m[1].length <= level) {
      end = i;
      break;
    }
  }

  // Splice out [start, end). Preserve a trailing newline so the next
  // section's leading "\n" doesn't collapse into the previous one.
  const before = lines.slice(0, start);
  const after = lines.slice(end);
  return [...before, ...after].join("\n");
}

export default fleetContextFilter;
