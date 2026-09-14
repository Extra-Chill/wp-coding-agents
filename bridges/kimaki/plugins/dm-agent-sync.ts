// dm-agent-sync.ts — refresh Data Machine memory for OpenCode chat sessions.
//
// Setup and upgrade synchronize Data Machine's injectable file registry into
// OpenCode's static `instructions` array. This plugin recomposes those files
// before a session's first chat message, when OpenCode has not yet built the
// model prompt. Config-only commands therefore never start WordPress.

import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Plugin } from "@opencode-ai/plugin";

type WpCli = string[];

const DEFAULT_COMPOSE_TIMEOUT_MS = 10_000;
const OUTPUT_LIMIT = 16 * 1024;

type ComposeResult = { exitCode: number; output: string; timedOut: boolean };
type ComposeReceipt = { completedAt: number; result: "refreshed" | "stale_fallback" };

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
  const timeoutMs = getComposeTimeoutMs();
  const scope = composeScope(wpCli, sitePath, agentSlug);
  const lease = await acquireComposeLease(scope, timeoutMs);

  if (!lease.acquired) {
    const receipt = await waitForComposeReceipt(scope, startedAt, timeoutMs);
    const durationMs = Date.now() - startedAt;
    if (receipt?.result === "refreshed") {
      // eslint-disable-next-line no-console -- intentional operational log to the OpenCode session console
      console.warn(`[dm-agent-sync] reused fresh Data Machine memory after ${durationMs}ms`);
    } else {
      // eslint-disable-next-line no-console -- intentional operational log to the OpenCode session console
      console.warn(`[dm-agent-sync] memory compose stale fallback after ${durationMs}ms; using existing memory files`);
    }
    return;
  }

  const result = await runBoundedCommand(datamachineArgv(wpCli, sitePath, agentSlug), timeoutMs);
  const durationMs = Date.now() - startedAt;

  if (result.timedOut) {
    // Existing composed files remain the fallback. A WordPress outage must not
    // prevent OpenCode from accepting a chat message.
    // eslint-disable-next-line no-console -- intentional operational log to the OpenCode session console
    console.warn(`[dm-agent-sync] memory compose timed out after ${durationMs}ms; using existing memory files`);
    await finishComposeLease(scope, lease.token, "stale_fallback");
    return;
  }
  if (result.exitCode !== 0) {
    // eslint-disable-next-line no-console -- intentional operational log to the OpenCode session console
    console.warn(`[dm-agent-sync] memory compose failed (exit ${result.exitCode}) after ${durationMs}ms: ${result.output}`);
    await finishComposeLease(scope, lease.token, "stale_fallback");
    return;
  }
  // eslint-disable-next-line no-console -- intentional operational log to the OpenCode session console
  console.warn(`[dm-agent-sync] refreshed Data Machine memory in ${durationMs}ms`);
  await finishComposeLease(scope, lease.token, "refreshed");
}

function composeScope(wpCli: WpCli, sitePath: string, agentSlug: string): string {
  return createHash("sha256").update(JSON.stringify({ wpCli, sitePath, agentSlug })).digest("hex");
}

function composeStatePath(scope: string): string {
  return join(tmpdir(), "wp-coding-agents", "dm-compose", scope);
}

function composeReceiptPath(scope: string): string {
  return `${composeStatePath(scope)}.receipt`;
}

async function acquireComposeLease(scope: string, timeoutMs: number): Promise<{ acquired: boolean; token: string }> {
  const path = composeStatePath(scope);
  const token = randomUUID();
  try {
    await mkdir(join(tmpdir(), "wp-coding-agents", "dm-compose"), { recursive: true, mode: 0o700 });
    await mkdir(path, { recursive: false, mode: 0o700 });
    await writeFile(join(path, "owner"), token, { mode: 0o600 });
    return { acquired: true, token };
  } catch (error: unknown) {
    if (!isAlreadyExists(error)) {
      return { acquired: false, token: "" };
    }
  }

  // A killed runtime can leave a lease behind. It cannot block the next chat
  // longer than the same bounded compose interval.
  try {
    if (Date.now() - (await stat(path)).mtimeMs > timeoutMs) {
      await rm(path, { recursive: true, force: true });
      return acquireComposeLease(scope, timeoutMs);
    }
  } catch {
    return acquireComposeLease(scope, timeoutMs);
  }
  return { acquired: false, token: "" };
}

async function waitForComposeReceipt(scope: string, startedAt: number, timeoutMs: number): Promise<ComposeReceipt | undefined> {
  const path = composeStatePath(scope);
  const deadline = startedAt + timeoutMs;
  while (Date.now() < deadline) {
    const receipt = await readComposeReceipt(composeReceiptPath(scope));
    if (receipt && receipt.completedAt >= startedAt) {
      return receipt;
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  return undefined;
}

async function finishComposeLease(scope: string, token: string, result: ComposeReceipt["result"]): Promise<void> {
  const path = composeStatePath(scope);
  try {
    if ((await readFile(join(path, "owner"), "utf8")) !== token) {
      return;
    }
    // Keep the receipt beside the lock: releasing the lock must not erase the
    // successful result before the other processes that joined it can read it.
    await writeFile(composeReceiptPath(scope), JSON.stringify({ completedAt: Date.now(), result }), { mode: 0o600 });
    await rm(path, { recursive: true, force: true });
  } catch {
    // A best-effort lease failure must not prevent a chat message.
  }
}

async function readComposeReceipt(path: string): Promise<ComposeReceipt | undefined> {
  try {
    const receipt: unknown = JSON.parse(await readFile(path, "utf8"));
    if (
      typeof receipt === "object" && receipt !== null &&
      typeof (receipt as ComposeReceipt).completedAt === "number" &&
      ((receipt as ComposeReceipt).result === "refreshed" || (receipt as ComposeReceipt).result === "stale_fallback")
    ) {
      return receipt as ComposeReceipt;
    }
  } catch {
    // The owner may still be writing or may have released the lease.
  }
  return undefined;
}

function isAlreadyExists(error: unknown): boolean {
  return typeof error === "object" && error !== null && (error as NodeJS.ErrnoException).code === "EEXIST";
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

function runBoundedCommand(argv: string[], timeoutMs: number): Promise<ComposeResult> {
  const [command, ...args] = argv;
  return new Promise((resolve) => {
    const child = spawn(command, args, { detached: process.platform !== "win32", stdio: ["ignore", "pipe", "pipe"] });
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

function resolveWpCliTransport(): WpCli | undefined {
  const json = process.env.DATAMACHINE_WP_TRANSPORT_JSON;
  if (json) {
    return parseTransportJson(json);
  }
  return parseShippedWpCmd(process.env.DATAMACHINE_WP_CMD || process.env.WP_CMD || "wp");
}

function parseTransportJson(raw: string): WpCli | undefined {
  try {
    const value: unknown = JSON.parse(raw);
    if (!Array.isArray(value) || value.length === 0) {
      return undefined;
    }
    if (value.some((item) => typeof item !== "string" || item.length === 0 || item.includes("\0"))) {
      return undefined;
    }
    return value;
  } catch {
    return undefined;
  }
}

function parseShippedWpCmd(raw: string): WpCli | undefined {
  const parts = raw.trim().split(/[ \t]+/).filter((part) => part.length > 0);
  return parts.length > 0 ? parts : undefined;
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

export default dmAgentSync;
