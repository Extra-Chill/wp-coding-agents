// Session attribution for agent shells: Homeboy's session contract.
//
// Maps the Roadie session an agent shell belongs to onto the bridge-neutral
// HOMEBOY_SESSION_* names that Homeboy notification transports read
// (Extra-Chill/homeboy-extensions#2910). Roadie exports ROADIE_THREAD_ID to
// tool shells itself; when its plugin has not run first, the thread is looked
// up once per session with `roadie session discord-url`. This file is the
// only place the bridge's names meet the generic contract.

import { spawn } from "node:child_process";
import type { Plugin, PluginInput } from "@opencode-ai/plugin";

type SessionAwareHooks = Awaited<ReturnType<Plugin>> & {
  "shell.env": (
    input: { cwd: string; sessionID?: string; callID?: string },
    output: { env: Record<string, string> },
  ) => Promise<void>;
};

const DISCORD_THREAD_URL = /^https:\/\/discord\.com\/channels\/\d{17,20}\/(\d{17,20})\/?$/;
const SNOWFLAKE = /^\d{17,20}$/;
const LOOKUP_TIMEOUT_MS = 5_000;
const OUTPUT_LIMIT = 1_024;

const sessionAttribution = (async (_input: PluginInput): Promise<SessionAwareHooks> => {
  const cache = new Map<string, Promise<string | null>>();

  return {
    "shell.env": async ({ sessionID }, output) => {
      if (!sessionID) {
        return;
      }

      if (output.env.ROADIE_THREAD_ID) {
        exportHomeboySession(output.env, output.env.ROADIE_THREAD_ID);
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

      exportHomeboySession(output.env, threadId);
    },
    event: async ({ event }) => {
      if (event.type === "session.deleted") {
        cache.delete(event.properties.info.id);
      }
    },
  };
}) satisfies Plugin;

/**
 * Describe the invoking session through Homeboy's bridge-neutral contract.
 *
 * - HOMEBOY_SESSION_THREAD_ID: the Discord thread that owns this session.
 * - HOMEBOY_SESSION_SEND_COMMAND: delivers a prompt into that thread as a real
 *   turn (`<command> --thread <id> --prompt <text>`). The bridge drops messages
 *   its own bot posts over REST, so this is how a completion notification
 *   reaches the agent instead of only the human.
 *
 * Values already present (set by the host or the user) win. The bot token is
 * deliberately not exported: agent shells do not need it to deliver to their
 * own session, and every other route posts with the service's own credentials.
 */
function exportHomeboySession(env: Record<string, string>, threadId: string) {
  if (!SNOWFLAKE.test(threadId)) return;
  if (!env.HOMEBOY_SESSION_THREAD_ID) {
    env.HOMEBOY_SESSION_THREAD_ID = threadId;
  }
  if (!env.HOMEBOY_SESSION_SEND_COMMAND && !env.HOMEBOY_SESSION_SEND_URL) {
    const bin = bridgeBin();
    // The command is split on whitespace and run without a shell, so a binary
    // path containing whitespace cannot be expressed; leave it unset and let
    // delivery fall back to REST rather than run the wrong program.
    if (!/\s/.test(bin)) {
      env.HOMEBOY_SESSION_SEND_COMMAND = `${bin} send`;
    }
  }
}

function bridgeBin(): string {
  return process.env.ROADIE_BIN || "roadie";
}

function resolveThreadId(sessionID: string): Promise<string | null> {
  return new Promise((resolve) => {
    const child = spawn(bridgeBin(), ["session", "discord-url", sessionID], {
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
