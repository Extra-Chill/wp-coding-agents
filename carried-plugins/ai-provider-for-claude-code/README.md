# AI Provider for Claude Code

`ai-provider-for-claude-code` is a wp-coding-agents-carried WP AI Client provider backed by Claude Code OAuth credentials.

It is not an official Anthropic API-key provider. It sends Anthropic Messages API requests with Claude Code OAuth headers and does not execute the `claude` binary.

## Provider

- Provider ID: `claude-code`
- Models: `claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5`
- Auth: Claude Code OAuth refresh/access token credentials

## Configuration

- `AI_PROVIDER_CLAUDE_CODE_REFRESH_TOKEN`: Claude Code OAuth refresh token.
- `AI_PROVIDER_CLAUDE_CODE_ACCESS_TOKEN`: optional cached access token.
- `AI_PROVIDER_CLAUDE_CODE_EXPIRES_AT`: optional Unix timestamp for the cached access token expiry.
- `AI_PROVIDER_CLAUDE_CODE_USER_AGENT`: optional Claude CLI user agent override.
- WordPress constants with the same names are also supported.
- `ai_provider_claude_code_oauth_tokens` filter: override token data at runtime.
