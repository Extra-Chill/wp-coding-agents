// dm-agent-sync.ts — refresh Data Machine memory for OpenCode chat sessions.
//
// Setup and upgrade synchronize Data Machine's injectable file registry into
// OpenCode's static `instructions` array. This plugin recomposes those files
// before a session's first chat message, when OpenCode has not yet built the
// model prompt. Config-only commands therefore never start WordPress.

import { spawn } from "node:child_process";
import type { Plugin } from "@opencode-ai/plugin";

type WpCli = string[];

const DEFAULT_COMPOSE_TIMEOUT_MS = 10_000;
const OUTPUT_LIMIT = 16 * 1024;

const dmAgentSync: Plugin = async () => {
  let sessionConfig: { wpCli: WpCli; sitePath: string; agentSlug: string } | undefined;
  const synchronizedSessions = new Map<string, Promise<void>>();

  return {
    config: async (input) => {
      if (process.env.EXTERNAL_WORDPRESS === "true") {
        return;
      }

      // Config runs for every CLI command. Capture only local state here;
      // invoking WordPress belongs to the real chat lifecycle below.
      const wpCli = resolveWpCliTransport();
      if (!wpCli) {
        return;
      }
      sessionConfig = {
        wpCli,
        sitePath: getSitePath(),
        agentSlug: getAgentSlug(input),
      };
    },
    "chat.message": async ({ sessionID }) => {
      if (!sessionConfig) {
        return;
      }

      let sync = synchronizedSessions.get(sessionID);
      if (!sync) {
        sync = composeMemory(sessionConfig.wpCli, sessionConfig.sitePath, sessionConfig.agentSlug);
        synchronizedSessions.set(sessionID, sync);
      }
      await sync;
    },
  };
};

async function composeMemory(wpCli: WpCli, sitePath: string, agentSlug: string): Promise<void> {
  const startedAt = Date.now();
  const result = await runBoundedCommand(datamachineArgv(wpCli, sitePath, agentSlug), getComposeTimeoutMs());
  const durationMs = Date.now() - startedAt;

  if (result.timedOut) {
    // Existing composed files remain the fallback. A WordPress outage must not
    // prevent OpenCode from accepting a chat message.
    // eslint-disable-next-line no-console -- intentional operational log to the OpenCode session console
    console.warn(`[dm-agent-sync] memory compose timed out after ${durationMs}ms; using existing memory files`);
    return;
  }
  if (result.exitCode !== 0) {
    // eslint-disable-next-line no-console -- intentional operational log to the OpenCode session console
    console.warn(`[dm-agent-sync] memory compose failed (exit ${result.exitCode}) after ${durationMs}ms: ${result.output}`);
    return;
  }
  // eslint-disable-next-line no-console -- intentional operational log to the OpenCode session console
  console.warn(`[dm-agent-sync] recomposed Data Machine memory in ${durationMs}ms`);
}

function datamachineArgv(wpCli: WpCli, sitePath: string, agentSlug: string): string[] {
  const args = [...wpCli, "datamachine", "memory", "compose"];
  if (agentSlug) {
    args.push(`--agent=${agentSlug}`);
  }
  if (sitePath) {
    args.push(`--path=${sitePath}`);
  }
  args.push("--allow-root");
  return args;
}

function runBoundedCommand(argv: string[], timeoutMs: number): Promise<{ exitCode: number; output: string; timedOut: boolean }> {
  return new Promise((resolve) => {
    const child = spawn(argv[0], argv.slice(1), { detached: process.platform !== "win32", stdio: ["ignore", "pipe", "pipe"] });
    let output = "";
    let settled = false;
    const finish = (exitCode: number, timedOut: boolean) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      resolve({ exitCode, output, timedOut });
    };
    const terminate = () => {
      if (child.pid && process.platform !== "win32") {
        try {
          process.kill(-child.pid, "SIGTERM");
          return;
        } catch {
          // The process may have already exited; fall through to child.kill().
        }
      }
      child.kill("SIGTERM");
    };
    const timeout = setTimeout(() => {
      terminate();
      finish(1, true);
    }, timeoutMs);
    const append = (chunk: Buffer) => {
      output += chunk.toString();
      if (output.length > OUTPUT_LIMIT) {
        output = output.slice(0, OUTPUT_LIMIT);
        terminate();
        finish(1, false);
      }
    };
    child.stdout.on("data", append);
    child.stderr.on("data", append);
    child.on("error", () => finish(1, false));
    child.on("close", (code) => finish(code ?? 1, false));
  });
}

function getComposeTimeoutMs(): number {
  const configured = Number(process.env.DATAMACHINE_COMPOSE_TIMEOUT_MS);
  return Number.isFinite(configured) && configured > 0 ? configured : DEFAULT_COMPOSE_TIMEOUT_MS;
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

function resolveWpCliTransport(): WpCli | undefined {
  const json = process.env.DATAMACHINE_WP_TRANSPORT_JSON;
  if (json) {
    try {
      const value = JSON.parse(json) as unknown;
      if (Array.isArray(value) && value.length > 0 && value.every((item) => typeof item === "string" && item.length > 0 && !item.includes("\0"))) {
        return value;
      }
    } catch {
      return undefined;
    }
    return undefined;
  }

  // Shipped service files used a whitespace-delimited command string. Keep
  // that input boundary until upgraded services restart with canonical JSON.
  const legacy = process.env.DATAMACHINE_WP_CMD || process.env.WP_CMD || "wp";
  const parts = legacy.trim().split(/[ \t]+/).filter(Boolean);
  return parts.length > 0 ? parts : undefined;
}

export default dmAgentSync;
