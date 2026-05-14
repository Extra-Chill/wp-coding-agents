// dm-agent-sync.ts — OpenCode plugin that syncs Data Machine agents into
// OpenCode's agent switcher.
//
// On session start, queries Data Machine for all registered agents and their
// file paths, then registers each as an OpenCode agent with the correct
// identity files (SOUL.md, MEMORY.md, USER.md, SITE.md) and AGENTS.md.
//
// This gives every Data Machine agent its own identity in the agent switcher
// without manual opencode.json maintenance.
//
// How to use:
//   Add to opencode.json:  "plugin": ["path/to/dm-agent-sync.ts"]
//   Or place in .opencode/plugins/ in the project root.

/**
 * External dependencies
 */
import type { Plugin } from "@opencode-ai/plugin";

interface DmAgent {
  agent_id: number;
  agent_slug: string;
  agent_name: string;
  owner_id: number;
  status?: string;
  agent_config?: {
    default_model?: string;
    tool_policy?: Record<string, boolean>;
    model?: {
      default?: {
        provider?: string;
        model?: string;
      };
    };
  };
}

interface DmPaths {
  agent_slug: string;
  relative_files: string[];
}

const dmAgentSync: Plugin = async ({ $ }) => {
  return {
    config: async (config) => {
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

      // Query all agents from Data Machine.
      const agentsResult = sitePath
        ? await $`wp --path=${sitePath} datamachine agents list --format=json --allow-root`.quiet().nothrow()
        : await $`wp datamachine agents list --format=json --allow-root`.quiet().nothrow();
      if (agentsResult.exitCode !== 0) {
        console.warn(`[dm-agent-sync] agents list failed (exit ${agentsResult.exitCode}): ${await shellOutputText(agentsResult)}`);
        return;
      }

      const agentsRaw = await shellOutputText(agentsResult);
      const jsonMatch = agentsRaw.match(/\[[\s\S]*\]/);
      if (!jsonMatch) {
        console.warn("[dm-agent-sync] agents list did not contain a JSON array");
        return;
      }

      let agents: DmAgent[];
      try {
        agents = JSON.parse(jsonMatch[0]);
      } catch (error) {
        console.warn(`[dm-agent-sync] agents list returned invalid JSON: ${String(error)}`);
        return;
      }

      const entries = [];
      for (const agent of agents) {
        const status = agent.status || "active";
        if (status !== "active") {
          continue;
        }

        const pathsResult = sitePath
          ? await $`wp --path=${sitePath} datamachine memory paths --agent=${agent.agent_slug} --format=json --allow-root`.quiet().nothrow()
          : await $`wp datamachine memory paths --agent=${agent.agent_slug} --format=json --allow-root`.quiet().nothrow();
        if (pathsResult.exitCode !== 0) {
          console.warn(`[dm-agent-sync] memory paths failed for ${agent.agent_slug} (exit ${pathsResult.exitCode}): ${await shellOutputText(pathsResult)}`);
          continue;
        }

        let paths: DmPaths;
        try {
          paths = JSON.parse(await shellOutputText(pathsResult));
        } catch (error) {
          console.warn(`[dm-agent-sync] memory paths returned invalid JSON for ${agent.agent_slug}: ${String(error)}`);
          continue;
        }

        if (!paths?.relative_files?.length) {
          console.warn(`[dm-agent-sync] memory paths returned no files for ${agent.agent_slug}`);
          continue;
        }

        const promptRoot = sitePath || ".";
        const prompt = [
          `{file:${promptRoot}/AGENTS.md}`,
          ...paths.relative_files.map((f: string) => `{file:${promptRoot}/${f}}`),
        ].join("\n");

        const agentModel =
          agent.agent_config?.default_model ||
          (agent.agent_config?.model?.default
            ? `${agent.agent_config.model.default.provider}/${agent.agent_config.model.default.model}`
            : undefined);
        const tools = agent.agent_config?.tool_policy;
        const entry: Record<string, unknown> = {
          prompt,
          mode: "primary" as const,
        };
        if (agentModel) {
          entry.model = agentModel;
        }
        if (tools) {
          entry.tools = tools;
        }

        entries.push({ agent, entry, prompt });
      }

      if (!entries.length) {
        console.warn(`[dm-agent-sync] no active Data Machine agents with usable memory paths found (${agents.length} listed)`);
        return;
      }

      if (!config.agent) {
        config.agent = {};
      }

      const primary = entries[0];
      syncDefaultSlot(config.agent, "build", primary.entry);
      syncDefaultSlot(config.agent, "plan", primary.entry);

      for (const { agent, entry } of entries) {
        const agentSlug = agent.agent_slug;
        if (!config.agent[agentSlug]) {
          config.agent[agentSlug] = {
            ...entry,
            description: `Data Machine agent: ${agent.agent_name}`,
          };
        }
      }

      console.warn(`[dm-agent-sync] registered ${entries.length} Data Machine agent(s); build/plan prompt uses ${primary.agent.agent_slug}`);
    },
  };
};

function getSitePath(): string {
  return process.env.DATAMACHINE_SITE_PATH || process.env.SITE_PATH || process.env.PWD || "";
}

/**
 * Populate build/plan defaults without clobbering user-authored fields.
 *
 * @param {Record<string, unknown>} agentConfig  - OpenCode agent config object.
 * @param {"build"|"plan"}          slot         - Default slot to synchronize.
 * @param {Record<string, unknown>} managedEntry - Data Machine-managed entry.
 */
function syncDefaultSlot(
  agentConfig: Record<string, unknown>,
  slot: "build" | "plan",
  managedEntry: Record<string, unknown>
): void {
  const existing = agentConfig[slot];
  if (!existing || typeof existing !== "object" || Array.isArray(existing)) {
    agentConfig[slot] = { ...managedEntry };
    return;
  }

  const existingEntry = existing as Record<string, unknown>;
  if (typeof existingEntry.prompt === "string" && existingEntry.prompt.length > 0) {
    return;
  }

  agentConfig[slot] = {
    ...managedEntry,
    ...existingEntry,
    prompt: managedEntry.prompt,
  };
}

async function shellOutputText(output: any): Promise<string> {
  if (typeof output.text === "function") {
    return output.text();
  }
  return [output.stdout, output.stderr].filter(Boolean).join("\n");
}

export default dmAgentSync;
