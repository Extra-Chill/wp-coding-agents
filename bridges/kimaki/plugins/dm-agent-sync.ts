// dm-agent-sync.ts — refresh Data Machine memory for OpenCode chat sessions.
//
// Setup and upgrade synchronize Data Machine's injectable file registry into
// OpenCode's static `instructions` array. This plugin recomposes those files
// before a session's first chat message, when OpenCode has not yet built the
// model prompt. Config-only commands therefore never start WordPress.

import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Plugin } from "@opencode-ai/plugin";

type WpCli = string[];

const DEFAULT_COMPOSE_TIMEOUT_MS = 10_000;
const OUTPUT_LIMIT = 16 * 1024;

type ComposeResult = { exitCode: number; output: string; timedOut: boolean };
type ComposeReceipt = { completedAt: number; operationId: string; result: "refreshed" | "stale_fallback" };
type ComposeOwner = { deadlineAt: number; operationId: string; token: string };
type ComposeLease = { acquired: boolean; deadlineAt: number; operationId: string; path: string; token: string };

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
    const receipt = await waitForComposeReceipt(scope, lease.operationId, lease.deadlineAt);
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
    await finishComposeLease(scope, lease, "stale_fallback");
    return;
  }
  if (result.exitCode !== 0) {
    // eslint-disable-next-line no-console -- intentional operational log to the OpenCode session console
    console.warn(`[dm-agent-sync] memory compose failed (exit ${result.exitCode}) after ${durationMs}ms: ${result.output}`);
    await finishComposeLease(scope, lease, "stale_fallback");
    return;
  }
  // eslint-disable-next-line no-console -- intentional operational log to the OpenCode session console
  console.warn(`[dm-agent-sync] refreshed Data Machine memory in ${durationMs}ms`);
  await finishComposeLease(scope, lease, "refreshed");
}

function composeScope(wpCli: WpCli, sitePath: string, agentSlug: string): string {
  // The command name alone is not enough: relative executables and WP-CLI
  // configuration resolve from the runtime's working directory and identity.
  return createHash("sha256").update(JSON.stringify({
    agentSlug,
    cwd: process.cwd(),
    home: process.env.HOME || "",
    path: process.env.PATH || "",
    sitePath,
    user: process.env.USER || process.env.LOGNAME || "",
    wpCli,
    wpCliCache: process.env.WP_CLI_CACHE_DIR || "",
    wpCliConfig: process.env.WP_CLI_CONFIG_PATH || "",
  })).digest("hex");
}

function composeStatePath(scope: string): string {
  return join(composeStateDirectory(), scope);
}

function composeReceiptPath(scope: string): string {
  return `${composeStatePath(scope)}.receipt`;
}

function composeStateDirectory(): string {
  return process.env.DATAMACHINE_COMPOSE_STATE_DIR || join(tmpdir(), "wp-coding-agents", "dm-compose");
}

async function acquireComposeLease(scope: string, timeoutMs: number): Promise<ComposeLease> {
  const path = composeStatePath(scope);
  const directory = composeStateDirectory();
  try {
    await mkdir(directory, { recursive: true, mode: 0o700 });
  } catch {
    return unavailableLease();
  }

  const created = await createComposeLease(path, timeoutMs);
  if (created) {
    return created;
  }

  const owner = await waitForComposeOwner(path, timeoutMs);
  if (!owner) {
    // An unreadable or partially written lease is never deleted by a waiter.
    // It falls back within one local timeout and a later clean invocation can
    // acquire normally once the path disappears.
    return unavailableLease(timeoutMs);
  }
  if (owner.deadlineAt > Date.now()) {
    return waitingLease(path, owner);
  }

  // Expired owners are never removed or renamed. A separate recovery lease
  // makes recovery safe even when the old process wakes after its deadline.
  const recoveryPath = `${path}.recovery.${owner.operationId}`;
  const recovery = await createComposeLease(recoveryPath, timeoutMs);
  if (recovery) return recovery;
  const recoveryOwner = await waitForComposeOwner(recoveryPath, timeoutMs);
  return recoveryOwner ? waitingLease(recoveryPath, recoveryOwner) : unavailableLease(timeoutMs);
}

async function createComposeLease(path: string, timeoutMs: number): Promise<ComposeLease | undefined> {
  const owner: ComposeOwner = {
    deadlineAt: Date.now() + timeoutMs,
    operationId: randomUUID(),
    token: randomUUID(),
  };
  let created = false;
  try {
    await mkdir(path, { recursive: false, mode: 0o700 });
    created = true;
    await writeFile(join(path, "owner"), JSON.stringify(owner), { mode: 0o600 });
    return { acquired: true, path, ...owner };
  } catch (error: unknown) {
    if (created) {
      await rm(path, { recursive: true, force: true });
    }
    return undefined;
  }
}

function unavailableLease(timeoutMs = getComposeTimeoutMs()): ComposeLease {
  return { acquired: false, deadlineAt: Date.now() + timeoutMs, operationId: "", path: "", token: "" };
}

function waitingLease(path: string, owner: ComposeOwner): ComposeLease {
  return { acquired: false, path, deadlineAt: owner.deadlineAt, operationId: owner.operationId, token: "" };
}

async function waitForComposeReceipt(scope: string, operationId: string, deadlineAt: number): Promise<ComposeReceipt | undefined> {
  while (operationId && Date.now() < deadlineAt) {
    const receipt = await readComposeReceipt(composeReceiptPath(scope));
    if (receipt?.operationId === operationId) {
      return receipt;
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  return undefined;
}

async function finishComposeLease(scope: string, lease: ComposeLease, result: ComposeReceipt["result"]): Promise<void> {
  const path = lease.path;
  try {
    const owner = await readComposeOwner(path);
    if (!owner || owner.token !== lease.token) {
      return;
    }
    // Keep the receipt beside the lock: releasing the lock must not erase the
    // successful result before the other processes that joined it can read it.
    await writeFile(composeReceiptPath(scope), JSON.stringify({ completedAt: Date.now(), operationId: owner.operationId, result }), { mode: 0o600 });
    await rm(path, { recursive: true, force: true });
  } catch {
    // A best-effort lease failure must not prevent a chat message.
  }
}

async function readComposeOwner(path: string): Promise<ComposeOwner | undefined> {
  try {
    const owner: unknown = JSON.parse(await readFile(join(path, "owner"), "utf8"));
    if (
      typeof owner === "object" && owner !== null &&
      typeof (owner as ComposeOwner).deadlineAt === "number" &&
      typeof (owner as ComposeOwner).operationId === "string" &&
      typeof (owner as ComposeOwner).token === "string"
    ) {
      return owner as ComposeOwner;
    }
  } catch {
    // The owner may still be writing or the state directory may be unavailable.
  }
  return undefined;
}

async function waitForComposeOwner(path: string, timeoutMs: number): Promise<ComposeOwner | undefined> {
  const deadline = Date.now() + Math.min(timeoutMs, 100);
  while (Date.now() < deadline) {
    const owner = await readComposeOwner(path);
    if (owner) return owner;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  return readComposeOwner(path);
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
  return process.env.DATAMACHINE_SITE_PATH || process.env.SITE_PATH || process.env.PWD || process.cwd();
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
