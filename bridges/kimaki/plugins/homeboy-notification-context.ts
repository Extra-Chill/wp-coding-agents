// homeboy-notification-context.ts — Invocation-scoped Kimaki -> Homeboy context.
//
// Kimaki's documented attribution variables are inherited by an OpenCode tool
// subprocess. This plugin redirects Homeboy to the managed wrapper in that
// subprocess; the wrapper maps a validated destination without reading or
// writing the shared OpenCode server environment.

import type { Plugin } from "@opencode-ai/plugin";

const HOMEBOY_COMMAND = /(^|[;&|()\s])homeboy(?=\s|$)/g;

const homeboyNotificationContext: Plugin = async () => {
  return {
    "tool.execute.before": async (_input, output: { args?: Record<string, unknown> }) => {
      const command = output.args?.command;
      if (typeof command !== "string" || !/(^|[;&|()\s])homeboy(?=\s|$)/.test(command)) {
        return;
      }

      output.args.command = command.replace(HOMEBOY_COMMAND, "$1wp-coding-agents-homeboy-notification");
    },
  };
};

export default homeboyNotificationContext;
