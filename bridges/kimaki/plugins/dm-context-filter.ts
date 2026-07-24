// dm-context-filter.ts — OpenCode plugin for WordPress agent VPSes with Data Machine.
//
// Replaces Kimaki's built-in system prompt on managed installs. Kimaki remains
// the Discord bridge and human coordination surface. Available runtime,
// orchestration, preview, tunnel, and workspace guidance comes from composed
// Data Machine AGENTS.md sections registered by the components present on the
// install.
//
// The replacement prompt is deliberately small. Repository, agent memory,
// scheduling, lab, preview, tunnel, and workspace instructions come from the
// composed Data Machine/AGENTS instruction stack, not from Kimaki's generic CLI
// prompt.
//
// What it removes from chat message injection:
// 1. MEMORY.md injection — Kimaki reads MEMORY.md from the project directory and
//    injects a condensed TOC. Conflicts with Data Machine's own memory files.
// 2. "Update MEMORY.md" time-gap reminder — Redundant with external memory system.
// Total savings depends on the Kimaki version and managed startup flags.
//
// How to use:
//   Add to opencode.json:  "plugin": ["/opt/kimaki-config/plugins/dm-context-filter.ts"]
//   Or place in .opencode/plugins/ in the project root.

/**
 * External dependencies
 */
import type { Plugin } from "@opencode-ai/plugin";

const MANAGED_KIMAKI_SYSTEM_PROMPT = `## Kimaki Discord Bridge

Kimaki connects this OpenCode session to Discord. Treat Discord as the human coordination surface: keep the thread updated, ask the user for files with the native upload tool when needed, upload user-facing artifacts when useful, mention users by Discord ID when action is required, and archive the thread when the user explicitly asks.

## Managed Coding Runtime

Use the composed Data Machine AGENTS.md guidance for the coding runtime, workspace, orchestration, preview, tunnel, and evidence capabilities available on this install.

## Bridge Diagnostics

For Kimaki bridge failures, inspect \$HOME/.kimaki/kimaki.log. The log is reset every time Kimaki restarts, so it only covers the current run.
`;

const fleetContextFilter: Plugin = async () => {
  return {
    // Replace Kimaki's generic CLI/orchestration prompt with managed guidance.
    "experimental.chat.system.transform": async (_input, output) => {
      output.system = output.system.map((block) => {
        return replaceKimakiSystemPrompt(block);
      });
    },

    // Kimaki passes its generated Discord prompt through promptAsync's per-call
    // `system` field. Some OpenCode releases do not expose that field through
    // the system transform hook before model dispatch, but the final message
    // transform still sees text parts that are about to reach the model. Keep a
    // second replacement pass here so managed installs do not depend on one
    // experimental hook shape.
    "experimental.chat.messages.transform": async (_input, output) => {
      for (const message of output.messages) {
        for (const part of message.parts) {
          if (part.type !== "text") {
            continue;
          }
          const text = (part as any).text;
          if (typeof text !== "string") {
            continue;
          }
          (part as any).text = replaceKimakiSystemPrompt(text);
        }
      }
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

// Replace only positively identified Kimaki prompt text. Both transforms use
// this helper because message transforms also receive unrelated text.
function replaceKimakiSystemPrompt(block: string): string {
  const kimakiStart = kimakiSystemPromptStart(block);
  if (kimakiStart === -1) {
    return block;
  }

  // Only replace a positively identified Kimaki prompt. Message transforms
  // also see ordinary user and composed AGENTS.md text.
  const prefix = block.slice(0, kimakiStart).trimEnd();
  return [prefix, MANAGED_KIMAKI_SYSTEM_PROMPT].filter(Boolean).join("\n\n");
}

function kimakiSystemPromptStart(block: string): number {
  const markers = [
    "## Kimaki Discord Bridge",
    "The user is reading your messages from inside Discord, via kimaki.dev",
    "Your current OpenCode session ID is:",
    "## debugging kimaki issues",
    "## uploading files to discord",
  ];

  return markers.reduce((earliest, marker) => {
    const index = block.indexOf(marker);
    if (index === -1) {
      return earliest;
    }
    return earliest === -1 ? index : Math.min(earliest, index);
  }, -1);
}

export default fleetContextFilter;
