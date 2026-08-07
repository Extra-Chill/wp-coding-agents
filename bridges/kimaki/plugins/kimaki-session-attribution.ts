// Temporary compatibility bridge for remorses/kimaki#137.
// Remove after the native KIMAKI_THREAD_ID contract ships and is installed.

import { spawn } from "node:child_process";
import type { Plugin, PluginInput } from "@opencode-ai/plugin";

type SessionAwareHooks = Awaited<ReturnType<Plugin>> & {
  "shell.env": (
    input: { cwd: string; sessionID?: string; callID?: string },
    output: { env: Record<string, string> },
  ) => Promise<void>;
};

const DISCORD_THREAD_URL = /^https:\/\/discord\.com\/channels\/\d{17,20}\/(\d{17,20})\/?$/;
const LOOKUP_TIMEOUT_MS = 2_000;
const OUTPUT_LIMIT = 1_024;

const sessionAttribution = (async (_input: PluginInput): Promise<SessionAwareHooks> => {
  const cache = new Map<string, Promise<string | null>>();

  return {
    "shell.env": async ({ sessionID }, output) => {
      if (!sessionID || output.env.KIMAKI_THREAD_ID) {
        return;
      }

      let lookup = cache.get(sessionID);
      if (!lookup) {
        lookup = resolveThreadId(sessionID);
        cache.set(sessionID, lookup);
      }

      const threadId = await lookup;
      if (!threadId) {
        if (cache.get(sessionID) === lookup) {
          cache.delete(sessionID);
        }
        return;
      }

      if (!output.env.KIMAKI_THREAD_ID) {
        output.env.KIMAKI_THREAD_ID = threadId;
      }
    },
    event: async ({ event }) => {
      if (event.type === "session.deleted") {
        cache.delete(event.properties.info.id);
      }
    },
  };
}) satisfies Plugin;

function resolveThreadId(sessionID: string): Promise<string | null> {
  return new Promise((resolve) => {
    const child = spawn(process.env.KIMAKI_BIN || "kimaki", ["session", "discord-url", sessionID], {
      shell: false,
      stdio: ["ignore", "pipe", "ignore"],
    });
    let stdout = "";
    let settled = false;
    const finish = (threadId: string | null) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      resolve(threadId);
    };
    const timeout = setTimeout(() => {
      child.kill();
      finish(null);
    }, LOOKUP_TIMEOUT_MS);

    child.stdout.on("data", (chunk) => {
      stdout += chunk;
      if (stdout.length > OUTPUT_LIMIT) {
        child.kill();
        finish(null);
      }
    });
    child.on("error", () => finish(null));
    child.on("close", (code) => {
      if (code !== 0 || stdout.length > OUTPUT_LIMIT) {
        finish(null);
        return;
      }
      finish(stdout.trim().match(DISCORD_THREAD_URL)?.[1] ?? null);
    });
  });
}

export default sessionAttribution;
