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

For Kimaki bridge failures, inspect \`$HOME/.kimaki/kimaki.log\`. The log is reset every time Kimaki restarts, so it only covers the current run.
`;

const KIMAKI_GENERIC_SECTION_HEADINGS = [
  "## permissions",
  "## upgrading kimaki",
  "## debugging kimaki issues",
  "## uploading files to discord",
  "## requesting files from the user",
  "## archiving the current thread",
  "## aborting a session",
  "## discord user mentions",
  "## starting new sessions from CLI",
  "## running opencode commands via kimaki send",
  "## switching agents in the current session",
  "## scheduled sends and task management",
  "## reading other sessions",
  "## cross-project commands",
  "## waiting for a session to finish",
  "## creating worktrees",
  "## generating audio from text",
  "## running dev servers with tunnel access",
  "## markdown formatting",
  "## Callouts in Kimaki Discord",
];

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

/**
 * Identify Kimaki's generated system prompt without matching composed AGENTS.md
 * or other OpenCode system blocks from the managed install.
 *
 * @param {string} block - System prompt block.
 * @return {boolean} Whether this block is Kimaki's generated bridge prompt.
 */
function isKimakiSystemPrompt(block: string): boolean {
  return (
    block.includes("The user is reading your messages from inside Discord, via kimaki.dev") ||
    block.includes("## debugging kimaki issues") ||
    block.includes("## uploading files to discord") ||
    block.includes("Your current OpenCode session ID is:")
  );
}

function replaceKimakiSystemPrompt(block: string): string {
  const filteredBlock = stripKimakiGenericSections(block);
  const kimakiStart = kimakiSystemPromptStart(filteredBlock);
  if (kimakiStart === -1) {
    return filteredBlock;
  }

  const prefix = filteredBlock.slice(0, kimakiStart).trimEnd();
  const suffix = filteredBlock.slice(kimakiSystemPromptEnd(filteredBlock, kimakiStart)).trimStart();
  return [prefix, MANAGED_KIMAKI_SYSTEM_PROMPT, suffix].filter(Boolean).join("\n\n");
}

function stripKimakiGenericSections(block: string): string {
  let result = block;
  for (const heading of KIMAKI_GENERIC_SECTION_HEADINGS) {
    result = stripMarkdownSection(result, heading);
  }
  return result.replace(/\n{3,}/g, "\n\n").trimEnd();
}

function stripMarkdownSection(block: string, heading: string): string {
  const lines = block.split("\n");
  const level = headingLevel(heading);
  let start = -1;
  let inFence = false;

  for (let i = 0; i < lines.length; i++) {
    if (/^```/.test(lines[i])) {
      inFence = !inFence;
      continue;
    }
    if (!inFence && lines[i] === heading) {
      start = i;
      break;
    }
  }

  if (start === -1) {
    return block;
  }

  let end = lines.length;
  inFence = false;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^```/.test(lines[i])) {
      inFence = !inFence;
      continue;
    }
    const match = !inFence ? lines[i].match(/^(#{1,6})\s+\S/) : null;
    if (match && match[1].length <= level) {
      end = i;
      break;
    }
    if (!inFence && lines[i].startsWith("Instructions from: ")) {
      end = i;
      break;
    }
  }

  return [...lines.slice(0, start), ...lines.slice(end)].join("\n");
}

function headingLevel(heading: string): number {
  return heading.match(/^#+/)?.[0].length ?? 2;
}

function kimakiSystemPromptStart(block: string): number {
  const markers = [
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

function kimakiSystemPromptEnd(block: string, start: number): number {
  const trailingInstruction = block.slice(start).search(/\nInstructions from: /);
  if (trailingInstruction !== -1) {
    return start + trailingInstruction + 1;
  }
  return block.length;
}

export default fleetContextFilter;
