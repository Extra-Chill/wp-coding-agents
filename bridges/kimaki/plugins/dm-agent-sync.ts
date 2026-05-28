// dm-agent-sync.ts — OpenCode plugin that refreshes Data Machine memory.
//
// On session start, asks Data Machine to recompose its memory files so
// OpenCode's top-level `instructions` and AGENTS.md auto-discovery read fresh
// content. Identity stays owned by Data Machine/channel routing; this plugin
// must not set OpenCode `agent.*.prompt` fields or register Data Machine agents
// into OpenCode's agent switcher.
//
// The filename is kept for upgrade compatibility with existing opencode.json
// plugin arrays that reference dm-agent-sync.ts.
//
// How to use:
//   Add to opencode.json:  "plugin": ["path/to/dm-agent-sync.ts"]
//   Or place in .opencode/plugins/ in the project root.

/**
 * External dependencies
 */
import type { Plugin } from "@opencode-ai/plugin";

const dmAgentSync: Plugin = async ({ $ }) => {
  return {
    config: async () => {
      const sitePath = getSitePath();
      const wpAvailable = await $`command -v wp`.quiet().nothrow();
      if (wpAvailable.exitCode !== 0) {
        return;
      }

      // Refresh composable files before the session reads them.
      // DM SectionRegistry callbacks render live state (configured sources,
      // skills, config). DM's own invalidation hooks cover state changes
      // that happen inside a WordPress request, but cron jobs, direct DB
      // edits, or other external processes would leave AGENTS.md stale.
      // Running compose here guarantees the file matches live state at the
      // moment OpenCode loads the session prompt.
      const composeResult = sitePath
        ? await $`wp --path=${sitePath} datamachine memory compose --allow-root`.quiet().nothrow()
        : await $`wp datamachine memory compose --allow-root`.quiet().nothrow();
      if (composeResult.exitCode !== 0) {
        console.warn(`[dm-agent-sync] memory compose failed (exit ${composeResult.exitCode}): ${await shellOutputText(composeResult)}`);
      }
    },
  };
};

function getSitePath(): string {
  return process.env.DATAMACHINE_SITE_PATH || process.env.SITE_PATH || process.env.PWD || "";
}

async function shellOutputText(output: any): Promise<string> {
  if (typeof output.text === "function") {
    return output.text();
  }
  return [output.stdout, output.stderr].filter(Boolean).join("\n");
}

export default dmAgentSync;
