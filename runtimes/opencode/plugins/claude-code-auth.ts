// claude-code-auth.ts - OpenCode Anthropic auth via Claude Code OAuth.
//
// Self-contained for direct OpenCode installs. It mirrors Kimaki's proven
// Claude Code OAuth/request-shaping path without loading Kimaki bridge plugins.

import type { Plugin } from "@opencode-ai/plugin";
import { spawn } from "node:child_process";
import { createServer, type Server } from "node:http";
import { homedir } from "node:os";
import path from "node:path";
import * as fs from "node:fs/promises";

type OAuthStored = { type: "oauth"; refresh: string; access: string; expires: number };
type OAuthSuccess = { type: "success"; refresh: string; access: string; expires: number };
type CallbackResult = { code: string; state: string };
type AccountRecord = OAuthStored & { addedAt: number; lastUsed: number };
type AccountStore = { version: number; activeIndex: number; accounts: AccountRecord[] };
type RefreshFailure = { auth: OAuthStored; error: unknown };
type AuthSyncClient = { auth?: { set?: (input: { providerID: string; auth: OAuthStored }) => Promise<unknown> } };

const CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const TOKEN_URL = "https://platform.claude.com/v1/oauth/token";
const CALLBACK_PORT = 53692;
const CALLBACK_PATH = "/callback";
const REDIRECT_URI = `http://localhost:${CALLBACK_PORT}${CALLBACK_PATH}`;
const SCOPES = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload";
const OAUTH_TIMEOUT_MS = 5 * 60 * 1000;
const REFRESH_LOCK_TIMEOUT_MS = 15_000;
const REFRESH_LOCK_STALE_MS = 2 * 60 * 1000;
const CLAUDE_CODE_VERSION = "2.1.259";
const CLAUDE_CODE_IDENTITY = "You are Claude Code, Anthropic's official CLI for Claude.";
const OPENCODE_IDENTITY = "You are OpenCode, the best coding agent on the planet.";
const SUBAGENT_MODEL_IDENTITY = "You are powered by the model named";
const ENV_CLOSE_TAG = "</env>";
const CLAUDE_CODE_BETA = "claude-code-20250219";
const OAUTH_BETA = "oauth-2025-04-20";
const FINE_GRAINED_TOOL_STREAMING_BETA = "fine-grained-tool-streaming-2025-05-14";
const INTERLEAVED_THINKING_BETA = "interleaved-thinking-2025-05-14";

const ANTHROPIC_HOSTS = new Set(["api.anthropic.com", "claude.ai", "console.anthropic.com", "platform.claude.com"]);
const TOOL_NAMES: Record<string, string> = {
  bash: "Bash",
  edit: "Edit",
  glob: "Glob",
  grep: "Grep",
  question: "AskUserQuestion",
  read: "Read",
  skill: "Skill",
  task: "Task",
  todowrite: "TodoWrite",
  webfetch: "WebFetch",
  websearch: "WebSearch",
  write: "Write",
};

function authFilePath() {
  if (process.env.XDG_DATA_HOME) return path.join(process.env.XDG_DATA_HOME, "opencode", "auth.json");
  return path.join(homedir(), ".local", "share", "opencode", "auth.json");
}

function accountsFilePath() {
  if (process.env.XDG_DATA_HOME) return path.join(process.env.XDG_DATA_HOME, "opencode", "anthropic-oauth-accounts.json");
  return path.join(homedir(), ".local", "share", "opencode", "anthropic-oauth-accounts.json");
}

function refreshLockPath() {
  return `${authFilePath()}.anthropic-refresh.lock`;
}

async function readJson<T>(filePath: string, fallback: T): Promise<T> {
  try { return JSON.parse(await fs.readFile(filePath, "utf8")) as T; } catch { return fallback; }
}

async function writeJson(filePath: string, value: unknown) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, JSON.stringify(value, null, 2), "utf8");
  await fs.chmod(filePath, 0o600);
}

async function writeAnthropicAuth(auth: OAuthStored) {
  const file = authFilePath();
  const data = await readJson<Record<string, unknown>>(file, {});
  data.anthropic = auth;
  await writeJson(file, data);
}

async function setAnthropicAuth(auth: OAuthStored, client?: AuthSyncClient) {
  await writeAnthropicAuth(auth);
  await client?.auth?.set?.({ providerID: "anthropic", auth }).catch(() => undefined);
}

async function readAnthropicAuth() {
  const data = await readJson<Record<string, unknown>>(authFilePath(), {});
  const auth = data.anthropic;
  if (!auth || typeof auth !== "object") return undefined;
  const candidate = auth as Partial<OAuthStored>;
  if (candidate.type !== "oauth" || typeof candidate.refresh !== "string" || typeof candidate.access !== "string" || typeof candidate.expires !== "number") return undefined;
  return candidate as OAuthStored;
}

function normalizeAccountStore(input: Partial<AccountStore> | null | undefined): AccountStore {
  const accounts = Array.isArray(input?.accounts)
    ? input.accounts.filter((account): account is AccountRecord => {
      return !!account && account.type === "oauth" && typeof account.refresh === "string" && typeof account.access === "string" && typeof account.expires === "number" && typeof account.addedAt === "number" && typeof account.lastUsed === "number";
    })
    : [];
  const rawIndex = typeof input?.activeIndex === "number" ? Math.floor(input.activeIndex) : 0;
  const activeIndex = accounts.length === 0 ? 0 : ((rawIndex % accounts.length) + accounts.length) % accounts.length;
  return { version: 1, activeIndex, accounts };
}

async function loadAccountStore() {
  return normalizeAccountStore(await readJson<Partial<AccountStore> | null>(accountsFilePath(), null));
}

async function saveAccountStore(store: AccountStore) {
  await writeJson(accountsFilePath(), normalizeAccountStore(store));
}

async function sleep(ms: number) {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function withRefreshLock<T>(action: () => Promise<T>): Promise<T> {
  const lockPath = refreshLockPath();
  const started = Date.now();
  while (true) {
    try {
      await fs.mkdir(lockPath, { recursive: false });
      await fs.writeFile(path.join(lockPath, "owner"), `${process.pid}\n${new Date().toISOString()}\n`, "utf8");
      break;
    } catch (error) {
      const code = (error as { code?: string }).code;
      if (code !== "EEXIST") throw error;
      const stat = await fs.stat(lockPath).catch(() => undefined);
      if (stat && Date.now() - stat.mtimeMs > REFRESH_LOCK_STALE_MS) {
        await fs.rm(lockPath, { force: true, recursive: true }).catch(() => undefined);
        continue;
      }
      if (Date.now() - started > REFRESH_LOCK_TIMEOUT_MS) throw new Error("Timed out waiting for Anthropic OAuth refresh lock");
      await sleep(100);
    }
  }

  try {
    return await action();
  } finally {
    await fs.rm(lockPath, { force: true, recursive: true }).catch(() => undefined);
  }
}

function findCurrentAccountIndex(store: AccountStore, auth: OAuthStored) {
  if (!store.accounts.length) return 0;
  const byRefresh = store.accounts.findIndex((account) => account.refresh === auth.refresh);
  if (byRefresh >= 0) return byRefresh;
  const byAccess = store.accounts.findIndex((account) => account.access === auth.access);
  if (byAccess >= 0) return byAccess;
  return store.activeIndex;
}

function sameOAuth(a: OAuthStored | undefined, b: OAuthStored | undefined) {
  return !!a && !!b && a.refresh === b.refresh && a.access === b.access;
}

function usableAccessToken(auth: OAuthStored | undefined) {
  return !!auth?.access && auth.expires > Date.now();
}

function dedupeOAuthCandidates(candidates: Array<OAuthStored | undefined>) {
  const seen = new Set<string>();
  return candidates.filter((candidate): candidate is OAuthStored => {
    if (!candidate) return false;
    const key = `${candidate.refresh}\n${candidate.access}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function upsertAccount(store: AccountStore, auth: OAuthStored, now = Date.now()) {
  const index = store.accounts.findIndex((account) => account.refresh === auth.refresh || account.access === auth.access);
  const nextAccount: AccountRecord = { ...auth, addedAt: now, lastUsed: now };
  if (index < 0) {
    store.accounts.push(nextAccount);
    store.activeIndex = store.accounts.length - 1;
    return;
  }
  const existing = store.accounts[index];
  store.accounts[index] = { ...nextAccount, addedAt: existing?.addedAt ?? now };
  store.activeIndex = index;
}

function replaceAccount(store: AccountStore, previous: OAuthStored, next: OAuthStored, now = Date.now()) {
  const index = store.accounts.findIndex((account) => account.refresh === previous.refresh || account.access === previous.access || account.refresh === next.refresh || account.access === next.access);
  if (index < 0) {
    upsertAccount(store, next, now);
    return;
  }
  const existing = store.accounts[index];
  store.accounts[index] = { ...next, addedAt: existing?.addedAt ?? now, lastUsed: now };
  store.activeIndex = index;
}

async function rememberAnthropicOAuth(auth: OAuthStored) {
  const store = await loadAccountStore();
  upsertAccount(store, auth);
  await saveAccountStore(store);
}

async function rotateAnthropicAccount(auth: OAuthStored, client?: AuthSyncClient) {
  const store = await loadAccountStore();
  if (store.accounts.length < 2) return undefined;

  const currentIndex = findCurrentAccountIndex(store, auth);
  const nextIndex = (currentIndex + 1) % store.accounts.length;
  const nextAccount = store.accounts[nextIndex];
  if (!nextAccount) return undefined;

  nextAccount.lastUsed = Date.now();
  store.activeIndex = nextIndex;
  await saveAccountStore(store);
  const nextAuth: OAuthStored = {
    type: "oauth",
    refresh: nextAccount.refresh,
    access: nextAccount.access,
    expires: nextAccount.expires,
  };
  await setAnthropicAuth(nextAuth, client);
  return nextAuth;
}

function shouldRotateAuth(status: number, bodyText: string) {
  const haystack = bodyText.toLowerCase();
  if (status === 429 || status === 401 || status === 403) return true;
  return haystack.includes("rate_limit") || haystack.includes("rate limit") || haystack.includes("usage limit") || haystack.includes("usage_limit") || haystack.includes("usage_limit_reached") || haystack.includes("usage_not_included") || haystack.includes("invalid api key") || haystack.includes("authentication_error") || haystack.includes("permission_error");
}

function refreshFailureText(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function isInvalidGrantFailure(error: unknown) {
  const haystack = refreshFailureText(error).toLowerCase();
  return haystack.includes("invalid_grant") || haystack.includes("invalid refresh") || haystack.includes("refresh token") || (haystack.includes("http 400") && haystack.includes(TOKEN_URL));
}

function summarizeRefreshFailures(failures: RefreshFailure[]) {
  const last = failures[failures.length - 1];
  const detail = last ? refreshFailureText(last.error).replace(/sk-ant-[A-Za-z0-9_.\-]+/g, "sk-ant-[redacted]").replace(/rt\.1\.[A-Za-z0-9_.\-]+/g, "rt.1.[redacted]") : "unknown error";
  const invalid = failures.some((failure) => isInvalidGrantFailure(failure.error));
  return `Anthropic OAuth refresh failed for ${failures.length} stored credential${failures.length === 1 ? "" : "s"}${invalid ? " (invalid_grant detected)" : ""}. Re-run OpenCode auth if no other account can refresh. Last error: ${detail}`;
}

function base64urlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}

async function generatePKCE() {
  const verifierBytes = new Uint8Array(32);
  crypto.getRandomValues(verifierBytes);
  const verifier = base64urlEncode(verifierBytes);
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return { verifier, challenge: base64urlEncode(new Uint8Array(hash)) };
}

async function requestText(url: string, options: { method: string; headers?: Record<string, string>; body?: string }) {
  return new Promise<string>((resolve, reject) => {
    const payload = JSON.stringify({ url, ...options });
    const child = spawn("node", ["-e", `
const input = JSON.parse(process.argv[1]);
(async () => {
  const response = await fetch(input.url, {
    method: input.method,
    headers: input.headers,
    body: input.body,
  });
  const text = await response.text();
  if (!response.ok) {
    console.error(JSON.stringify({ status: response.status, body: text }));
    process.exit(1);
  }
  process.stdout.write(text);
})().catch((error) => {
  console.error(error instanceof Error ? error.stack ?? error.message : String(error));
  process.exit(1);
});
`.trim(), payload], { stdio: ["ignore", "pipe", "pipe"] });

    let stdout = "";
    let stderr = "";
    const timeout = setTimeout(() => {
      child.kill();
      reject(new Error(`Request timed out. url=${url}`));
    }, 30_000);

    child.stdout.on("data", (chunk) => { stdout += String(chunk); });
    child.stderr.on("data", (chunk) => { stderr += String(chunk); });
    child.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timeout);
      if (code !== 0) {
        try {
          const parsed = JSON.parse(stderr.trim()) as { status?: number; body?: string };
          if (typeof parsed.status === "number") {
            reject(new Error(`HTTP ${parsed.status} from ${url}: ${parsed.body ?? ""}`));
            return;
          }
        } catch {}
        reject(new Error(stderr.trim() || `Node helper exited with code ${code}`));
        return;
      }
      resolve(stdout);
    });
  });
}

async function postJson(url: string, body: Record<string, string | number>) {
  const requestBody = JSON.stringify(body);
  const text = await requestText(url, {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Length": String(Buffer.byteLength(requestBody)),
      "Content-Type": "application/json",
    },
    body: requestBody,
  });
  return JSON.parse(text) as unknown;
}

function parseTokenResponse(json: unknown) {
  const data = json as { access_token?: string; refresh_token?: string; expires_in?: number };
  if (!data.access_token || !data.refresh_token) throw new Error(`Invalid token response: ${JSON.stringify(json)}`);
  return {
    access: data.access_token,
    refresh: data.refresh_token,
    expires: Date.now() + (data.expires_in ?? 3600) * 1000 - 5 * 60 * 1000,
  };
}

async function exchangeAuthorizationCode(code: string, state: string, verifier: string): Promise<OAuthSuccess> {
  const data = parseTokenResponse(await postJson(TOKEN_URL, {
    grant_type: "authorization_code",
    client_id: CLIENT_ID,
    code,
    state,
    redirect_uri: REDIRECT_URI,
    code_verifier: verifier,
  }));
  return { type: "success", ...data };
}

async function refreshAnthropicToken(refreshToken: string): Promise<OAuthStored> {
  const data = parseTokenResponse(await postJson(TOKEN_URL, {
    grant_type: "refresh_token",
    client_id: CLIENT_ID,
    refresh_token: refreshToken,
  }));
  return { type: "oauth", ...data };
}

async function startCallbackServer(expectedState: string) {
  return new Promise<{ server: Server; cancelWait: () => void; waitForCode: () => Promise<CallbackResult | null> }>((resolve, reject) => {
    let settle: ((value: CallbackResult | null) => void) | undefined;
    let settled = false;
    const waitPromise = new Promise<CallbackResult | null>((res) => {
      settle = (value) => { if (!settled) { settled = true; res(value); } };
    });
    const server = createServer((req, res) => {
      try {
        const url = new URL(req.url || "", "http://localhost");
        if (url.pathname !== CALLBACK_PATH) { res.writeHead(404).end("Not found"); return; }
        const code = url.searchParams.get("code");
        const state = url.searchParams.get("state");
        const error = url.searchParams.get("error");
        if (error || !code || !state || state !== expectedState) { res.writeHead(400).end("Authentication failed"); return; }
        res.writeHead(200, { "Content-Type": "text/plain" }).end("Authentication successful. You can close this window.");
        settle?.({ code, state });
      } catch { res.writeHead(500).end("Internal error"); }
    });
    server.once("error", reject);
    server.listen(CALLBACK_PORT, "127.0.0.1", () => resolve({ server, cancelWait: () => settle?.(null), waitForCode: () => waitPromise }));
  });
}

function closeServer(server: Server) {
  return new Promise<void>((resolve) => server.close(() => resolve()));
}

async function beginAuthorizationFlow() {
  const pkce = await generatePKCE();
  const callbackServer = await startCallbackServer(pkce.verifier);
  const authParams = new URLSearchParams({
    code: "true",
    client_id: CLIENT_ID,
    response_type: "code",
    redirect_uri: REDIRECT_URI,
    scope: SCOPES,
    code_challenge: pkce.challenge,
    code_challenge_method: "S256",
    state: pkce.verifier,
  });
  return { url: `https://claude.ai/oauth/authorize?${authParams.toString()}`, verifier: pkce.verifier, callbackServer };
}

function parseManualInput(input: string): CallbackResult {
  try {
    const url = new URL(input);
    const code = url.searchParams.get("code");
    const state = url.searchParams.get("state");
    if (code) return { code, state: state || "" };
  } catch {}
  if (input.includes("#")) {
    const [code = "", state = ""] = input.split("#", 2);
    return { code, state };
  }
  if (input.includes("code=")) {
    const params = new URLSearchParams(input);
    const code = params.get("code");
    if (code) return { code, state: params.get("state") || "" };
  }
  return { code: input, state: "" };
}

async function waitForCallback(callbackServer: Awaited<ReturnType<typeof startCallbackServer>>, manualInput?: string): Promise<CallbackResult> {
  try {
    const quick = await Promise.race([callbackServer.waitForCode(), new Promise<null>((resolve) => setTimeout(() => resolve(null), 50))]);
    if (quick?.code) return quick;
    const trimmed = manualInput?.trim();
    if (trimmed) return parseManualInput(trimmed);
    const result = await Promise.race([callbackServer.waitForCode(), new Promise<null>((resolve) => setTimeout(() => resolve(null), OAUTH_TIMEOUT_MS))]);
    if (!result?.code) throw new Error("Timed out waiting for OAuth callback");
    return result;
  } finally {
    callbackServer.cancelWait();
    await closeServer(callbackServer.server);
  }
}

function buildAuthorizeHandler() {
  return async () => {
    const auth = await beginAuthorizationFlow();
    let pendingAuthResult: Promise<OAuthSuccess | { type: "failed" }> | undefined;
    const isRemote = Boolean(process.env.KIMAKI || process.env.WP_CODING_AGENTS_REMOTE_AUTH);
    const finalize = async (result: CallbackResult) => {
      const creds = await exchangeAuthorizationCode(result.code, result.state || auth.verifier, auth.verifier);
      const oauth: OAuthStored = { type: "oauth", refresh: creds.refresh, access: creds.access, expires: creds.expires };
      await writeAnthropicAuth(oauth);
      await rememberAnthropicOAuth(oauth);
      return creds;
    };
    if (!isRemote) {
      return {
        url: auth.url,
        instructions: "Complete login in your browser. OpenCode will catch the localhost callback automatically.",
        method: "auto" as const,
        callback: async () => {
          pendingAuthResult ??= (async () => { try { return await finalize(await waitForCallback(auth.callbackServer)); } catch { return { type: "failed" as const }; } })();
          return pendingAuthResult;
        },
      };
    }
    return {
      url: auth.url,
      instructions: "Complete login in your browser, then paste the final redirect URL from the address bar here. Pasting just the authorization code also works.",
      method: "code" as const,
      callback: async (input: string) => {
        pendingAuthResult ??= (async () => { try { return await finalize(await waitForCallback(auth.callbackServer, input)); } catch { return { type: "failed" as const }; } })();
        return pendingAuthResult;
      },
    };
  };
}

function replaceBlockWithCompactEnv(text: string, startIdx: number, endIdx: number) {
  const strippedBlock = text.slice(startIdx, endIdx);
  const cwd = strippedBlock.match(/Working directory:\s*(.+)/)?.[1]?.trim() || strippedBlock.match(/<cwd>([^<]+)<\/cwd>/)?.[1] || process.cwd();
  return `${text.slice(0, startIdx)}\n<environment>\n<cwd>${cwd}</cwd>\n</environment>\nRead, write, and edit files under ${cwd}.\n\n${text.slice(endIdx)}`;
}

function sanitizeSystemText(text: string) {
  const startIdx = text.indexOf(OPENCODE_IDENTITY);
  if (startIdx !== -1) {
    const envCloseIdx = text.indexOf(ENV_CLOSE_TAG, startIdx);
    if (envCloseIdx === -1) return text;
    const endIdx = envCloseIdx + ENV_CLOSE_TAG.length;
    return replaceBlockWithCompactEnv(text, startIdx, text[endIdx] === "\n" ? endIdx + 1 : endIdx);
  }
  const subagentIdx = text.indexOf(SUBAGENT_MODEL_IDENTITY);
  if (subagentIdx !== -1) {
    const envCloseIdx = text.indexOf(ENV_CLOSE_TAG, subagentIdx);
    if (envCloseIdx === -1) return text;
    const endIdx = envCloseIdx + ENV_CLOSE_TAG.length;
    return replaceBlockWithCompactEnv(text, subagentIdx, text[endIdx] === "\n" ? endIdx + 1 : endIdx);
  }
  return text;
}

function mapSystemPart(part: unknown): unknown {
  if (typeof part === "string") return { type: "text", text: sanitizeSystemText(part) };
  if (part && typeof part === "object" && "type" in part && part.type === "text" && "text" in part && typeof part.text === "string") {
    return { ...part, text: sanitizeSystemText(part.text) };
  }
  return part;
}

function prependClaudeCodeIdentity(system: unknown) {
  const identityBlock = { type: "text", text: CLAUDE_CODE_IDENTITY };
  if (typeof system === "undefined") return [identityBlock];
  if (typeof system === "string") return [identityBlock, { type: "text", text: sanitizeSystemText(system) }];
  if (!Array.isArray(system)) return [identityBlock, system];
  const sanitized = system.map(mapSystemPart);
  const first = sanitized[0];
  if (first && typeof first === "object" && "type" in first && first.type === "text" && "text" in first && first.text === CLAUDE_CODE_IDENTITY) return sanitized;
  return [identityBlock, ...sanitized];
}

function rewriteRequestPayload(body: string | undefined) {
  if (!body) return { body, modelId: undefined, reverseToolNameMap: new Map<string, string>() };
  try {
    const payload = JSON.parse(body) as Record<string, unknown>;
    const modelId = typeof payload.model === "string" ? payload.model : undefined;
    const reverseToolNameMap = new Map<string, string>();
    if (Array.isArray(payload.tools)) {
      payload.tools = payload.tools.map((tool) => {
        if (!tool || typeof tool !== "object") return tool;
        const name = (tool as { name?: unknown }).name;
        if (typeof name !== "string") return tool;
        const mapped = TOOL_NAMES[name.toLowerCase()] ?? name;
        reverseToolNameMap.set(mapped, name);
        return { ...(tool as Record<string, unknown>), name: mapped };
      });
    }
    payload.system = prependClaudeCodeIdentity(payload.system);

    if (payload.tool_choice && typeof payload.tool_choice === "object" && (payload.tool_choice as { type?: unknown }).type === "tool") {
      const name = (payload.tool_choice as { name?: unknown }).name;
      if (typeof name === "string") {
        payload.tool_choice = { ...(payload.tool_choice as Record<string, unknown>), name: TOOL_NAMES[name.toLowerCase()] ?? name };
      }
    }

    if (Array.isArray(payload.messages)) {
      payload.messages = payload.messages.map((message) => {
        if (!message || typeof message !== "object") return message;
        const content = (message as { content?: unknown }).content;
        if (!Array.isArray(content)) return message;
        return {
          ...(message as Record<string, unknown>),
          content: content.map((block) => {
            if (!block || typeof block !== "object") return block;
            const item = block as { type?: unknown; name?: unknown };
            if (item.type !== "tool_use" || typeof item.name !== "string") return block;
            return { ...(block as Record<string, unknown>), name: TOOL_NAMES[item.name.toLowerCase()] ?? item.name };
          }),
        };
      });
    }

    return { body: JSON.stringify(payload), modelId, reverseToolNameMap };
  } catch { return { body, modelId: undefined, reverseToolNameMap: new Map<string, string>() }; }
}

function wrapResponseStream(response: Response, reverseToolNameMap: Map<string, string>) {
  if (!response.body || reverseToolNameMap.size === 0) return response;

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  let carry = "";
  const transform = (text: string) => text.replace(/"name"\s*:\s*"([^"]+)"/g, (full, name: string) => {
    const original = reverseToolNameMap.get(name);
    return original ? full.replace(`"${name}"`, `"${original}"`) : full;
  });

  const stream = new ReadableStream<Uint8Array>({
    async pull(controller) {
      const { done, value } = await reader.read();
      if (done) {
        const finalText = carry + decoder.decode();
        if (finalText) controller.enqueue(encoder.encode(transform(finalText)));
        controller.close();
        return;
      }
      carry += decoder.decode(value, { stream: true });
      if (carry.length <= 256) return;
      const output = carry.slice(0, -256);
      carry = carry.slice(-256);
      controller.enqueue(encoder.encode(transform(output)));
    },
    async cancel(reason) { await reader.cancel(reason); },
  });

  return new Response(stream, { status: response.status, statusText: response.statusText, headers: response.headers });
}

function getRequiredBetas(modelId: string | undefined) {
  const betas = [CLAUDE_CODE_BETA, OAUTH_BETA, FINE_GRAINED_TOOL_STREAMING_BETA];
  if (!modelId?.includes("opus-4-6") && !modelId?.includes("opus-4.6") && !modelId?.includes("sonnet-4-6") && !modelId?.includes("sonnet-4.6")) betas.push(INTERLEAVED_THINKING_BETA);
  return betas;
}

function mergeBetas(existing: string | null, required: string[]) {
  return [...new Set([...required, ...(existing || "").split(",").map((s) => s.trim()).filter(Boolean)])].join(",");
}

async function getFreshOAuth(getAuth: () => Promise<OAuthStored | { type: string }>, client?: AuthSyncClient) {
  const auth = await getAuth();
  if (auth.type !== "oauth") return undefined;
  const oauth = auth as OAuthStored;
  if (usableAccessToken(oauth)) return oauth;

  return withRefreshLock(async () => {
    const latest = await readAnthropicAuth();
    if (usableAccessToken(latest)) return latest;

    const store = await loadAccountStore();
    const active = store.accounts[store.activeIndex];
    const candidates = dedupeOAuthCandidates([latest, oauth, active, ...store.accounts]);
    const failures: RefreshFailure[] = [];

    for (const candidate of candidates) {
      try {
        const refreshed = await refreshAnthropicToken(candidate.refresh);
        await setAnthropicAuth(refreshed, client);
        replaceAccount(store, candidate, refreshed);
        await saveAccountStore(store);
        return refreshed;
      } catch (error) {
        failures.push({ auth: candidate, error });
        if (!isInvalidGrantFailure(error)) break;
      }
    }

    if (failures.length > 0) {
      throw new Error(summarizeRefreshFailures(failures));
    }

    throw new Error("Anthropic OAuth refresh failed: no stored OAuth credentials were available");
  });
}

async function refreshOAuthAfterAuthFailure(auth: OAuthStored, client?: AuthSyncClient) {
  return withRefreshLock(async () => {
    const latest = await readAnthropicAuth();
    if (latest && !sameOAuth(latest, auth) && usableAccessToken(latest)) return latest;

    const store = await loadAccountStore();
    const refreshed = await refreshAnthropicToken(auth.refresh);
    await setAnthropicAuth(refreshed, client);
    replaceAccount(store, auth, refreshed);
    await saveAccountStore(store);
    return refreshed;
  });
}

async function rotateAndRefreshAnthropicAccount(auth: OAuthStored, client?: AuthSyncClient) {
  const rotated = await rotateAnthropicAccount(auth, client);
  if (!rotated || sameOAuth(rotated, auth)) return undefined;
  try {
    return await refreshOAuthAfterAuthFailure(rotated, client);
  } catch {
    return undefined;
  }
}

async function getFreshOAuthOrRotate(getAuth: () => Promise<OAuthStored | { type: string }>, client?: AuthSyncClient) {
  try {
    return await getFreshOAuth(getAuth, client);
  } catch (error) {
    const auth = await readAnthropicAuth();
    if (auth) {
      const rotated = await rotateAndRefreshAnthropicAccount(auth, client);
      if (rotated && !sameOAuth(rotated, auth)) return rotated;
    }
    throw error;
  }
}

const claudeCodeAuthPlugin: Plugin = async (input) => {
  const client = input.client as AuthSyncClient | undefined;
  return {
  auth: {
    provider: "anthropic",
    async loader(getAuth: () => Promise<OAuthStored | { type: string }>, provider: { models: Record<string, { cost?: unknown }> }) {
      const auth = await getAuth();
      if (auth.type !== "oauth") return {};
      for (const model of Object.values(provider.models)) model.cost = { input: 0, output: 0, cache: { read: 0, write: 0 } };
      return {
        apiKey: "",
        async fetch(input: Request | string | URL, init?: RequestInit) {
          const url = (() => { try { return new URL(input instanceof Request ? input.url : input.toString()); } catch { return null; } })();
          if (!url || !ANTHROPIC_HOSTS.has(url.hostname)) return fetch(input, init);
          const originalBody = typeof init?.body === "string" ? init.body : input instanceof Request ? await input.clone().text().catch(() => undefined) : undefined;
          const rewritten = rewriteRequestPayload(originalBody);
          const freshAuth = await getFreshOAuthOrRotate(getAuth, client);
          if (!freshAuth) return fetch(input, init);
          const headers = new Headers(init?.headers);
          if (input instanceof Request) input.headers.forEach((value, key) => { if (!headers.has(key)) headers.set(key, value); });
          headers.set("accept", "application/json");
          headers.set("anthropic-beta", mergeBetas(headers.get("anthropic-beta"), getRequiredBetas(rewritten.modelId)));
          headers.set("anthropic-dangerous-direct-browser-access", "true");
          headers.set("authorization", `Bearer ${freshAuth.access}`);
          headers.set("user-agent", process.env.OPENCODE_ANTHROPIC_USER_AGENT || `claude-cli/${CLAUDE_CODE_VERSION}`);
          headers.set("x-app", "cli");
          headers.delete("x-api-key");
          let response = await fetch(input, { ...(init ?? {}), body: rewritten.body, headers });
          if (!response.ok) {
            const bodyText = await response.clone().text().catch(() => "");
            if (shouldRotateAuth(response.status, bodyText)) {
              const refreshed = await refreshOAuthAfterAuthFailure(freshAuth, client).catch(() => undefined);
              if (refreshed) {
                headers.set("authorization", `Bearer ${refreshed.access}`);
                response = await fetch(input, { ...(init ?? {}), body: rewritten.body, headers });
              }
            }
          }
          if (!response.ok) {
            const bodyText = await response.clone().text().catch(() => "");
            if (shouldRotateAuth(response.status, bodyText)) {
              const rotated = await rotateAndRefreshAnthropicAccount(await readAnthropicAuth() ?? freshAuth, client);
              if (rotated) {
                headers.set("authorization", `Bearer ${rotated.access}`);
                response = await fetch(input, { ...(init ?? {}), body: rewritten.body, headers });
              }
            }
          }
          return wrapResponseStream(response, rewritten.reverseToolNameMap);
        },
      };
    },
    methods: [
      { label: "Claude Pro/Max", type: "oauth", authorize: buildAuthorizeHandler() },
      { provider: "anthropic", label: "Manually enter API Key", type: "api" },
    ],
  },
  };
};

export { claudeCodeAuthPlugin };
