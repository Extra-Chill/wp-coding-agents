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
// 4. Worktree creation — ~150 tokens. We use feature branches in workspace repos.
// 5. Cross-project commands — ~200 tokens. Single-project fleet servers.
// 6. Waiting for sessions — ~150 tokens. Rarely used, discoverable via --help.
// 7. Worktree conflicts — inline --worktree/--cwd examples in "starting new
//    sessions from CLI", the orphan "Worktrees are useful..." lead-in, and the
//    per-turn "## worktree" section. Data Machine Code manages its own
//    workspace and worktrees; keeping Kimaki's worktree language around causes
//    the agent to try using Kimaki worktrees instead of DM Code's workspace.
// 8. Permissions — ~80 tokens describing which Discord roles can message the
//    bot. The agent has no capability to act on this; pure metadata leakage.
// 9. Upgrading kimaki — ~80 tokens of /upgrade-and-restart playbook. The user
//    runs the slash command themselves when they want to upgrade.
// 10. Reading other sessions — ~250 tokens documenting `kimaki session list
//    --project` / `session search --channel <id>`. These are cross-project
//    discovery vectors; on a single-project fleet server the agent only ever
//    needs to list sessions in the current project (no flags required).
// 11. Project discovery inlines — scattered `kimaki project list|add|create`,
//    `kimaki send --project`, and bare `kimaki send --channel <channel_id>`
//    examples that survive section stripping. These let the agent discover
//    other Discord channels and route minion sessions away from the current
//    thread. See Extra-Chill/data-machine-code#49.
// 12. Agent override inlines — `--agent <current_agent>` examples from the
//    generic Kimaki prompt. On DM-managed sites the Discord channel owns the
//    personal-agent binding; passing the runtime agent (for example `opencode`)
//    bypasses that binding and starts the wrong kind of minion session.
//
// What it injects into the system prompt:
// - `## WordPress Site Runtime` — positive instruction replacing Kimaki's
//   generic tunnel/dev-server section with the local/VPS WordPress boundary:
//   use the existing site runtime by default; tunnel only for inbound public
//   URLs like webhooks/OAuth callbacks or explicit browser previews.
// - `## Minion Session Routing` — positive instruction telling the agent that
//   all minion sessions go in the current channel. Defense in depth on top of
//   the stripping above: even if the agent discovers channel IDs some other
//   way (training data, --help output, user mention), the instruction steers
//   it back to ${channelId}. Use --cwd to target a different repo dir.
//
// NOTE: "## debugging kimaki issues" is intentionally kept — when Kimaki itself
// throws errors, the agent needs the kimaki.log path to investigate.
//
// What it removes from chat message injection:
// 8. MEMORY.md injection — Kimaki reads MEMORY.md from the project directory and
//    injects a condensed TOC. Conflicts with Data Machine's own memory files.
// 9. "Update MEMORY.md" time-gap reminder — Redundant with external memory system.
// 10. Worktree system-reminder — Kimaki injects a <system-reminder> telling the
//     agent to operate inside its worktree and not touch the main repo. This
//     overrides Data Machine Code's workspace, which is the real working dir.
//
// Total savings: ~2,400+ tokens per session.
//
// How to use:
//   Add to opencode.json:  "plugin": ["/opt/kimaki-config/plugins/dm-context-filter.ts"]
//   Or place in .opencode/plugins/ in the project root.

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
        result = stripSection(result, "## creating worktrees");
        result = stripSection(result, "## worktree");
        result = stripSection(result, "## cross-project commands");
        result = stripSection(result, "## reading other sessions");
        result = stripSection(result, "## waiting for a session to finish");
        result = stripSection(result, "## running opencode commands via kimaki send");
        result = stripSection(result, "## switching agents in the current session");
        result = stripSection(result, "## showing diffs");
        result = stripSection(result, "## about critique");
        result = stripSection(result, "### always show diff at end of session");
        result = stripSection(result, "### fetching user comments from critique diffs");
        result = stripSection(result, "### reviewing diffs with AI");
        result = stripWorktreeInlines(result);
        result = stripProjectDiscoveryInlines(result);
        result = stripAgentOverrideInlines(result);
        // Clean up leftover double/triple blank lines.
        result = result.replace(/\n{3,}/g, "\n\n");
        // Append positive routing instruction so the agent never tries to
        // discover or send sessions to other channels, even if it learns
        // channel IDs from --help or training data.
        result = appendWordPressSiteRuntimeInstruction(result);
        result = appendMinionRoutingInstruction(result);
        return result;
      });
    },

    // Filter out Kimaki's MEMORY.md injection, time-gap MEMORY.md reminders,
    // and worktree system-reminders.
    "chat.message": async (_input, output) => {
      // Walk backwards so splice indices stay valid.
      for (let i = output.parts.length - 1; i >= 0; i--) {
        const part = output.parts[i];
        if (part.type !== "text" || !(part as any).synthetic) {
          continue;
        }
        const text = (part as any).text as string;
        if (!text) continue;

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

        // Remove Kimaki's worktree system-reminder. Data Machine Code manages
        // the real working directory; Kimaki's reminder conflicts with it.
        if (text.includes("running inside a git worktree")) {
          output.parts.splice(i, 1);
          continue;
        }
      }
    },
  };
};

/**
 * Remove a markdown section from a system prompt block. Matches from the
 * heading to just before the next heading at the same or higher level, or
 * to the end of the block.
 *
 * Supports both ## and ### headings. For ##, stops at the next ## or #.
 * For ###, stops at the next ###, ##, or #.
 *
 * Fence-aware: lines that look like headings but live inside fenced code
 * blocks (``` … ```) are NOT treated as section terminators. Bash code
 * examples in the kimaki system prompt routinely contain `# Comment`
 * lines, which a naive regex would mistake for a level-1 heading and
 * stop the section early — leaving the rest of the section unstripped.
 * The previous regex-only implementation hit this bug on every section
 * containing a ```bash block with `#`-prefixed comments (notably
 * "## waiting for a session to finish", which left a `--worktree`
 * reference in the filtered prompt).
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
  if (start === -1) return block;

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
    if (inFence) continue;
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
 * Remove inline worktree/--worktree/--cwd content that lives inside sections
 * we otherwise want to keep (like "## starting new sessions from CLI") or
 * as standalone paragraphs between sections.
 *
 * These exist because Kimaki assumes worktrees are a first-class feature, but
 * Data Machine Code owns the workspace and worktrees on DM-managed sites.
 * Leaving the language in causes the agent to try `kimaki send --worktree`
 * or treat a Kimaki worktree as its working directory instead of using the
 * DM Code workspace.
 */
function stripWorktreeInlines(block: string): string {
  let result = block;

  // Standalone lead-in paragraph that sits above the (stripped) "## creating
  // worktrees" section. After the section is stripped, this line is orphaned.
  result = result.replace(
    /\n+Worktrees are useful for handing off parallel tasks[^\n]*\n/g,
    "\n"
  );

  // Inline "IMPORTANT: NEVER use --worktree" warning inside
  // "## starting new sessions from CLI".
  result = result.replace(
    /\n+IMPORTANT: NEVER use `--worktree`[^\n]*\n/g,
    "\n"
  );

  // "Use --worktree to create a git worktree for the session..." example block.
  // Covers the intro line, the code example, and trailing blank line.
  result = result.replace(
    /\n+Use --worktree to create a git worktree[\s\S]*?--worktree [^\n]*\n/g,
    "\n"
  );

  // "Use --cwd to start a session in an existing git worktree..." example block.
  result = result.replace(
    /\n+Use --cwd to start a session in an existing git worktree[\s\S]*?--cwd [^\n]*\n/g,
    "\n"
  );

  // "Important:" bullet list about --worktree that follows the examples above.
  // Only strip if the list is clearly about worktrees (first bullet mentions it).
  result = result.replace(
    /\n+Important:\n(?:- [^\n]*\n)*?- NEVER use `--worktree`[^\n]*\n(?:- [^\n]*\n)*/g,
    "\n"
  );

  return result;
}

/**
 * Remove project / channel discovery examples that survive section stripping.
 *
 * The system prompt bakes the current channel ID into most `kimaki send`
 * examples via `${channelId}`, which is the safe/correct form for this
 * session. But several other forms leak the *capability* to target other
 * channels or projects:
 *
 *   - `kimaki project list|add|create` — enumerates every registered project
 *     with its Discord channel ID.
 *   - `kimaki send --project <dir>` — resolves a channel from a project dir.
 *   - `kimaki send --channel <channel_id>` with a literal `<channel_id>`
 *     placeholder (as opposed to the baked-in current-channel ID) — teaches
 *     the agent it can pick a channel freely.
 *
 * On DM-managed sites the current Discord thread is the only correct target
 * for minion sessions. Cross-repo work uses DM Code's workspace worktrees,
 * not cross-channel kimaki sends. See Extra-Chill/data-machine-code#49.
 *
 * We keep `${channelId}` examples untouched — those are the intended,
 * session-scoped forms.
 */
function stripProjectDiscoveryInlines(block: string): string {
  let result = block;

  // Standalone `kimaki project ...` commands on their own lines (inside any
  // surviving section or orphaned between sections). Covers list|add|create.
  result = result.replace(
    /\n+kimaki project (?:list|add|create)[^\n]*\n/g,
    "\n"
  );

  // `kimaki send --project /path/...` bash examples, as full lines.
  result = result.replace(
    /\n+kimaki send --project [^\n]*\n/g,
    "\n"
  );

  // `kimaki send --channel <channel_id> ...` examples that use the literal
  // placeholder `<channel_id>` rather than the baked-in session channel.
  // The `${channelId}` form is template-substituted before this plugin runs,
  // so by the time we see the prompt the current channel is already a
  // concrete numeric ID — it will not match `<channel_id>` and stays intact.
  result = result.replace(
    /\n+kimaki send --channel <channel_id>[^\n]*\n/g,
    "\n"
  );

  // Matching `kimaki session search "..." --channel <channel_id>` examples.
  result = result.replace(
    /\n+kimaki session search [^\n]*--channel <channel_id>[^\n]*\n/g,
    "\n"
  );

  // Any remaining `--project /path/...` flag usage in inline prose or code
  // blocks. Conservative: only strip whole lines where the flag is the
  // dominant content (starts with command + --project).
  result = result.replace(
    /\n+kimaki (?:session|task) [^\n]*--project [^\n]*\n/g,
    "\n"
  );

  return result;
}

/**
 * Remove generic Kimaki agent override examples from surviving sections.
 *
 * On Data Machine-managed sites the Discord channel selects the personal
 * agent. Passing `--agent <current_agent>` teaches the runtime agent to turn
 * the synthetic reminder value (often `opencode`) into a real session routing
 * override, bypassing the channel-bound Franklin agent.
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

/**
 * Append positive WordPress runtime guidance after stripping Kimaki's generic
 * tunnel/dev-server section.
 *
 * Local and VPS installs intentionally use different plugin paths, but the
 * runtime policy is the same: the WordPress site already exists. Local Studio
 * agents should use Studio's site runtime and `studio wp`; VPS agents should
 * use the live site and `wp`. A tunnel is still useful when the task needs an
 * inbound public URL, but it is not the default path for interacting with the
 * site.
 */
function appendWordPressSiteRuntimeInstruction(block: string): string {
  const instruction = `

## WordPress Site Runtime

This is a Data Machine-managed WordPress agent install. Use the existing WordPress site runtime by default — do not start a separate dev server just to work on the site.

On local WordPress Studio installs, use Studio and \`studio wp\` against the existing site. On VPS installs, use the live WordPress site and \`wp\` in the configured site path.

Use \`kimaki tunnel\` only when the task specifically needs an inbound public URL, such as GitHub webhooks, OAuth callbacks, or an explicit browser preview for someone who cannot access the local/VPS site directly.
`;
  return block.replace(/\s*$/, "") + instruction;
}

/**
 * Append a positive minion-session routing instruction.
 *
 * Stripping alone is not enough: the agent can still learn channel IDs from
 * `kimaki --help`, other agents' mentions, or training data. This instruction
 * is defense in depth — it tells the agent the *policy* (all minion sessions
 * go in this channel) so that even if a channel ID surfaces some other way,
 * the agent still routes correctly. Cross-repo work is handled by pointing
 * `--cwd` at a Data Machine Code workspace worktree, not by switching
 * channels.
 */
function appendMinionRoutingInstruction(block: string): string {
  const instruction = `

## Minion Session Routing

All minion sessions for this agent go in THIS Discord channel — the one this session is running in. NEVER send sessions to other channels, even if you happen to know another channel ID. Do not run \`kimaki project list\`, \`kimaki project add\`, \`kimaki project create\`, or \`kimaki send --project\` — those are cross-project discovery commands that route sessions to other agents' channels.

Do not pass \`--agent\` when spawning normal minion sessions. The channel selects the personal agent. Passing the runtime agent (for example \`--agent opencode\`) bypasses the channel binding and starts the wrong kind of session.

If a minion needs to work in a different repo directory, use \`kimaki send --cwd /path/to/repo\` so the session stays in this channel but operates on a different checkout. For code changes in external repos, prefer Data Machine Code's workspace worktrees (\`studio wp datamachine-code workspace worktree add <repo> <branch>\`) — the worktree becomes the \`--cwd\` target for any follow-up minion session.
`;
  // Ensure exactly one blank line between existing content and the appendix.
  return block.replace(/\s*$/, "") + instruction;
}

export default fleetContextFilter;
