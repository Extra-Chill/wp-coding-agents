# AI Provider for Claude Code

`ai-provider-for-claude-code` is a wp-coding-agents-carried WP AI Client provider backed by the locally authenticated Claude Code CLI.

It is not an official Anthropic API provider. It does not use an Anthropic API key and does not implement the Anthropic Messages API. Requests are executed by the `claude` binary available to the WordPress host or Codebox sandbox.

## Provider

- Provider ID: `claude-code`
- Models: `claude-code`, `sonnet`, `opus`, `haiku`
- Auth: existing Claude Code CLI session on the host/sandbox

`claude-code` uses the CLI default model. The named models pass `--model <id>` to Claude Code.

## Configuration

- `AI_PROVIDER_CLAUDE_CODE_BIN`: override the Claude Code binary path/name. Defaults to `claude`.
- `AI_PROVIDER_CLAUDE_CODE_TIMEOUT`: process timeout in seconds. Defaults to `600`.
- `AI_PROVIDER_CLAUDE_CODE_BIN` constant: WordPress constant alternative for the binary path/name.
- `ai_provider_claude_code_bin` filter: override the binary path/name.
- `ai_provider_claude_code_env` filter: return environment variables for the Claude Code process.

Model custom options:

- `cwd`: process working directory.
- `timeout`: per-request process timeout in seconds.
- `args`: additional CLI args appended to the `claude -p` command.
