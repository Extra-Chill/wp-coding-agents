// dm-context-filter.ts — OpenCode plugin for WordPress agent VPSes with Data Machine.
//
// Strips Kimaki built-in features from the agent context when Data Machine
// manages memory, scheduling, and other concerns.
//
// What it removes from the system prompt:
// 1. Scheduling — ~500 tokens of --send-at, cron, task management instructions.
// 2. Tunnel / dev server — ~500 tokens about kimaki tunnel and tmux. DM-managed
//    WordPress installs already have a site runtime (Studio locally, a live
//    site on VPS). Tunnels are task-specific for inbound public URLs like
//    webhooks/OAuth callbacks, not the default way to interact with the site.
// 3. Critique — ~900 tokens of diff-sharing instructions. We use GitHub PRs.
// 4. Waiting for sessions — ~150 tokens. Rarely used, discoverable via --help.
// 5. Session/workspace conflicts — generic Kimaki agent override examples can
//    bypass the Data Machine-bound default agent slot.
// 8. Permissions — ~80 tokens describing which Discord roles can message the
//    bot. The agent has no capability to act on this; pure metadata leakage.
// 9. Upgrading kimaki — ~80 tokens of /upgrade-and-restart playbook. The user
//    runs the slash command themselves when they want to upgrade.
// 10. Reading other sessions — ~250 tokens documenting `kimaki session list
//    --project` / `session search --channel <id>`. These are cross-project
//    discovery vectors; on a single-project fleet server the agent only ever
//    needs to list sessions in the current project (no flags required).
// 11. Agent override inlines — `--agent <current_agent>` examples from the
//    generic Kimaki prompt. On DM-managed sites the Discord channel owns the
//    personal-agent binding; passing the runtime agent (for example `opencode`)
//    bypasses that binding and starts the wrong kind of minion session.
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
// Total savings: ~2,400+ tokens per session.
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
        result = stripSection(result, "## worktree");
        result = stripSection(result, "## reading other sessions");
        result = stripSection(result, "## waiting for a session to finish");
        result = stripSection(result, "## running opencode commands via kimaki send");
        result = stripSection(result, "## switching agents in the current session");
        result = stripSection(result, "## showing diffs");
        result = stripSection(result, "## about critique");
        result = stripSection(result, "### always show diff at end of session");
        result = stripSection(result, "### fetching user comments from critique diffs");
        result = stripSection(result, "### reviewing diffs with AI");
        result = stripAgentOverrideInlines(result);
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

/**
 * Remove generic Kimaki agent override examples from surviving sections.
 *
 * On Data Machine-managed sites the Discord channel selects the personal
 * agent. Passing `--agent <current_agent>` teaches the runtime agent to turn
 * the synthetic reminder value (often `opencode`) into a real session routing
 * override, bypassing the channel-bound Franklin agent.
 *
 * @param {string} block System prompt block.
 * @return {string} System prompt block without agent override examples.
 */
function stripAgentOverrideInlines(block: string): string {
  let result = block;

  // Delete the generic instruction that recommends passing the current runtime
  // agent to spawned sessions.
  result = result.replace(
    /\n+Prefer passing the current agent with `--agent <current_agent>`[^\n]*\n/g,
    "\n"
  );

  // Remove the generic "pick an agent" example from the surviving start-new-
  // sessions section; normal minions should rely on the channel binding.
  result = result.replace(
    /\n+Use --agent to specify which agent to use for the session:[\s\S]*?\nkimaki send --channel [^\n]* --agent [^\n]*\n/g,
    "\n"
  );

  // Surviving `kimaki send` examples should rely on channel routing. This
  // keeps examples usable while removing the footgun.
  result = result.replace(/ --agent <current_agent>/g, "");

  return result;
}

export default fleetContextFilter;
