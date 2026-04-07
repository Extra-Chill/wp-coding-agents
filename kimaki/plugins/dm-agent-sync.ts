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

import type { Plugin } from "@opencode-ai/plugin";

interface DmAgent {
  agent_id: number;
  agent_slug: string;
  agent_name: string;
  owner_id: number;
  status: string;
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
      try {
        // Query all agents from Data Machine.
        const agentsRaw = await $`wp datamachine agents list --format=json --allow-root 2>/dev/null`.quiet().nothrow().text();

        // wp datamachine agents list appends a summary line ("Total: N agent(s).")
        // after the JSON array. Strip it to get valid JSON.
        const jsonMatch = agentsRaw.match(/\[[\s\S]*\]/);
        if (!jsonMatch) return;

        const agents: DmAgent[] = JSON.parse(jsonMatch[0]);
        if (!agents.length) return;

        // Ensure agent config object exists.
        if (!config.agent) config.agent = {};

        for (const agent of agents) {
          if (agent.status !== "active") continue;

          // Get agent file paths.
          let paths: DmPaths;
          try {
            paths = await $`wp datamachine agent paths --agent=${agent.agent_slug} --format=json --allow-root 2>/dev/null`.quiet().json();
          } catch {
            continue;
          }

          if (!paths?.relative_files?.length) continue;

          // Build the prompt from discovered files (layered: AGENTS.md → SITE.md → SOUL.md → MEMORY.md → USER.md).
          const prompt = [
            "{file:./AGENTS.md}",
            ...paths.relative_files.map((f: string) => `{file:./${f}}`),
          ].join("\n");

          // Resolve model from agent config.
          const agentModel =
            agent.agent_config?.default_model ||
            (agent.agent_config?.model?.default
              ? `${agent.agent_config.model.default.provider}/${agent.agent_config.model.default.model}`
              : undefined);

          // Resolve tool policy from agent config.
          const tools = agent.agent_config?.tool_policy;

          // Register as both "build" and "plan" variants for the agent.
          // The first agent becomes the default build/plan agents.
          // Additional agents get their own named entries.
          const agentSlug = agent.agent_slug;

          // Build agent entry.
          const buildEntry: Record<string, unknown> = {
            prompt,
            mode: "primary" as const,
          };
          if (agentModel) buildEntry.model = agentModel;
          if (tools) buildEntry.tools = tools;

          // Check if this agent is already defined in the config (user override).
          // Don't overwrite explicit user config — only fill in missing agents.
          if (config.agent.build && config.agent.plan && agents.length === 1) {
            // Single agent + build/plan already defined = user has configured it.
            // Still update the prompt to ensure file paths are current.
            if (!isUserOverride(config.agent.build)) {
              config.agent.build.prompt = prompt;
            }
            if (!isUserOverride(config.agent.plan)) {
              config.agent.plan.prompt = prompt;
            }
            continue;
          }

          // For multi-agent setups, register each agent by slug.
          // First active agent also populates build/plan defaults if not set.
          if (!config.agent.build) {
            config.agent.build = { ...buildEntry };
          }
          if (!config.agent.plan) {
            config.agent.plan = {
              prompt,
              mode: "primary" as const,
              ...(agentModel ? { model: agentModel } : {}),
              ...(tools ? { tools } : {}),
            };
          }

          // Always register by slug name for the switcher.
          if (!config.agent[agentSlug]) {
            config.agent[agentSlug] = {
              ...buildEntry,
              description: `Data Machine agent: ${agent.agent_name}`,
            };
          }
        }
      } catch {
        // If WP-CLI is unavailable or Data Machine isn't installed, silently skip.
        // The plugin is a no-op on systems without Data Machine.
      }
    },
  };
};

/**
 * Check if an agent config entry looks like an intentional user override
 * (has a model set, which means the user chose something specific).
 */
function isUserOverride(agent: Record<string, unknown>): boolean {
  return typeof agent.model === "string" && agent.model.length > 0;
}

export default dmAgentSync;
