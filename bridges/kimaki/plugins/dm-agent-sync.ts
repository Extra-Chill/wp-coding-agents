// dm-agent-sync.ts — OpenCode plugin that refreshes Data Machine memory.
//
// On session start it:
//   1. Recomposes Data Machine's composable memory files (e.g. AGENTS.md) so
//      they match live WordPress state before OpenCode reads them.
//   2. Derives OpenCode's top-level `instructions` list from Data Machine's
//      registered injectable memory files, instead of relying on a static,
//      hand-maintained list in opencode.json that silently drifts whenever a
//      new memory file is registered in Data Machine.
//
// Agent identity stays in Data Machine's channel/session binding and OpenCode's
// top-level instructions instead of mutating config.agent.* prompts.
//
// Layer note: Data Machine is agnostic to how its memory files are consumed —
// `datamachine memory injectable-files` returns generic resolved paths and
// knows nothing about OpenCode. The OpenCode-specific knowledge (writing those
// paths into config.instructions) lives here, in the integration layer.
//
// How to use:
//   Add to opencode.json:  "plugin": ["path/to/dm-agent-sync.ts"]
//   Or place in .opencode/plugins/ in the project root.

/**
 * External dependencies
 */
import type { Plugin } from "@opencode-ai/plugin";

interface InjectableFile {
  filename: string;
  layer: string;
  path: string;
  priority: number;
}

const dmAgentSync: Plugin = async ({ $ }) => {
  return {
    config: async (input) => {
      const wpCli = await resolveWpCli($);
      if (!wpCli) {
        return;
      }

      const sitePath = getSitePath();
      const agentSlug = getAgentSlug(input);

      // Refresh composable files before the session reads them.
      // DM SectionRegistry callbacks render live state (configured sources,
      // skills, config). DM's own invalidation hooks cover state changes
      // that happen inside a WordPress request, but cron jobs, direct DB
      // edits, or other external processes would leave AGENTS.md stale.
      // Running compose here guarantees the file matches live state at the
      // moment OpenCode loads the session prompt.
      const composeResult = await runDatamachineCommand($, wpCli, sitePath, agentSlug, "compose");
      if (composeResult.exitCode !== 0) {
        // eslint-disable-next-line no-console -- intentional operational log to the OpenCode session console
        console.warn(`[dm-agent-sync] memory compose failed (exit ${composeResult.exitCode}): ${await shellOutputText(composeResult)}`);
        return;
      }
      // eslint-disable-next-line no-console -- intentional operational log to the OpenCode session console
      console.warn("[dm-agent-sync] recomposed Data Machine memory");

      // Derive the instructions list from DM's registered injectable memory
      // files so it stays in sync with the registry. If DM is too old to
      // provide the command, or it returns nothing usable, leave whatever
      // static list opencode.json already has untouched (graceful no-op).
      await syncInstructions(input, sitePath, $, wpCli, agentSlug);
    },
  };
};

type WpCli = string;

async function resolveWpCli($: any): Promise<WpCli | null> {
  const configured = process.env.DATAMACHINE_WP_CMD || process.env.WP_CMD || "";
  if (configured) {
    return configured;
  }

  const wpAvailable = await $`command -v wp`.quiet().nothrow();
  if (wpAvailable.exitCode === 0) {
    return "wp";
  }

  return null;
}

async function runDatamachineCommand($: any, wpCli: WpCli, sitePath: string, agentSlug: string, command: "compose" | "injectable-files"): Promise<any> {
  const args = ["datamachine", "memory", command];
  if (command === "injectable-files") {
    args.push("--format=json");
  }
  if (agentSlug) {
    args.push(`--agent=${agentSlug}`);
  }
  if (sitePath) {
    args.push(`--path=${sitePath}`);
  }
  args.push("--allow-root");

  // Do not start a login shell here. Service-user profiles are unrelated user
  // state and may contain interactive, stale, or failing initialization.
  return $`sh -c ${[wpCli, ...args.map(shellQuote)].join(" ")}`.quiet().nothrow();
}

/**
 * Replace config.instructions with the absolute paths Data Machine reports as
 * injectable for the active agent. Only existing files are included (DM already
 * filters to on-disk files), so a registered-but-not-yet-written file like a
 * freshly added briefing won't break session load.
 */
async function syncInstructions(
  input: { instructions?: string[] },
  sitePath: string,
  $: any,
  wpCli: WpCli,
  agentSlug: string,
): Promise<void> {
  if (!agentSlug) {
    // eslint-disable-next-line no-console -- intentional operational log to the OpenCode session console
    console.warn("[dm-agent-sync] agent slug unavailable; leaving instructions unchanged");
    return;
  }

  const result = await runDatamachineCommand($, wpCli, sitePath, agentSlug, "injectable-files");

  if (result.exitCode !== 0) {
    // DM predates the command, or the call failed — keep the existing list.
    // eslint-disable-next-line no-console -- intentional operational log to the OpenCode session console
    console.warn(`[dm-agent-sync] injectable-files unavailable (exit ${result.exitCode}); leaving instructions unchanged`);
    return;
  }

  const raw = await shellOutputText(result);
  let files: InjectableFile[];
  try {
    files = JSON.parse(raw);
  } catch {
    // eslint-disable-next-line no-console -- intentional operational log to the OpenCode session console
    console.warn("[dm-agent-sync] could not parse injectable-files output; leaving instructions unchanged");
    return;
  }

  const paths = Array.isArray(files)
    ? files.map((f) => f?.path).filter((p): p is string => typeof p === "string" && p.length > 0)
    : [];

  if (paths.length === 0) {
    // eslint-disable-next-line no-console -- intentional operational log to the OpenCode session console
    console.warn("[dm-agent-sync] injectable-files returned no paths; leaving instructions unchanged");
    return;
  }

  input.instructions = paths;
  // eslint-disable-next-line no-console -- intentional operational log to the OpenCode session console
  console.warn(`[dm-agent-sync] synced ${paths.length} instruction file(s) from Data Machine`);
}

function getSitePath(): string {
  return process.env.DATAMACHINE_SITE_PATH || process.env.SITE_PATH || process.env.PWD || "";
}

function getAgentSlug(input: { instructions?: string[] }): string {
  const envSlug = process.env.DATAMACHINE_AGENT_SLUG || process.env.AGENT_SLUG || process.env.DATAMACHINE_AGENT || "";
  if (envSlug) {
    return envSlug;
  }

  const instructions = Array.isArray(input.instructions) ? input.instructions : [];
  for (const instruction of instructions) {
    const match = instruction.match(/(?:^|\/)agents\/([^/]+)\//);
    if (match?.[1]) {
      return match[1];
    }
  }

  return "";
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'"'"'`)}'`;
}

async function shellOutputText(output: any): Promise<string> {
  if (typeof output.text === "function") {
    return output.text();
  }
  return [output.stdout, output.stderr].filter(Boolean).join("\n");
}

export default dmAgentSync;
