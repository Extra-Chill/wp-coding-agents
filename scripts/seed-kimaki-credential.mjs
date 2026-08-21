#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import path from "node:path";
import { pathToFileURL } from "node:url";

const token = process.env.KIMAKI_BOT_TOKEN ?? "";
if (!token) {
  throw new Error("KIMAKI_BOT_TOKEN is required");
}
if (!process.env.KIMAKI_DATA_DIR) {
  throw new Error("KIMAKI_DATA_DIR is required");
}

let packageRoot = process.env.KIMAKI_PACKAGE_ROOT;
if (!packageRoot) {
  const npmRoot = execFileSync("npm", ["root", "-g"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  }).trim();
  packageRoot = path.join(npmRoot, "kimaki", "dist");
}

const { setDataDir } = await import(
  pathToFileURL(path.join(packageRoot, "config.js"))
);
const { initDatabase, setBotMode, setBotToken } = await import(
  pathToFileURL(path.join(packageRoot, "database.js"))
);

setDataDir(process.env.KIMAKI_DATA_DIR);
await initDatabase();

const separator = token.indexOf(":");
if (separator > 0 && separator < token.length - 1) {
  await setBotMode({
    appId: process.env.KIMAKI_GATEWAY_APP_ID ?? "1477605701202481173",
    clientId: token.slice(0, separator),
    clientSecret: token.slice(separator + 1),
    mode: "gateway",
    proxyUrl:
      process.env.KIMAKI_GATEWAY_PROXY_REST_URL ??
      "https://slack-gateway.kimaki.dev",
  });
} else {
  const [encodedAppId] = token.split(".", 1);
  const appId =
    process.env.KIMAKI_BOT_APP_ID ??
    Buffer.from(encodedAppId, "base64").toString("utf8");
  if (!/^\d{17,20}$/.test(appId)) {
    throw new Error("KIMAKI_BOT_TOKEN does not contain a valid application ID");
  }
  await setBotToken(appId, token);
}
