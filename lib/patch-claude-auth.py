#!/usr/bin/env python3
"""
Patch opencode-claude-auth to use PascalCase mcp_ tool names.

Anthropic's billing validator rejects lowercase mcp_-prefixed tool names
(e.g. mcp_bash) as non-Claude-Code clients, causing 400 "out of extra usage"
errors. Real Claude Code uses PascalCase (mcp_Bash, mcp_Read).

This patch applies the same convention to the compiled transforms.js.

Ref: https://github.com/griffinmartin/opencode-claude-auth/issues/188
     https://github.com/griffinmartin/opencode-claude-auth/pull/191

Usage:
    python3 patch-claude-auth.py [path/to/transforms.js]

If no path is given, auto-detects from common cache locations.
"""
import sys
import os
import re


def find_transforms():
    """Auto-detect the transforms.js file in common locations."""
    candidates = [
        # Local macOS (nested packages path)
        os.path.expanduser(
            "~/.cache/opencode/packages/opencode-claude-auth@latest/"
            "node_modules/opencode-claude-auth/dist/transforms.js"
        ),
        # VPS service user (nested packages path)
        "/home/opencode/.cache/opencode/packages/opencode-claude-auth@latest/"
        "node_modules/opencode-claude-auth/dist/transforms.js",
        # VPS running as root — flat layout, no packages/ subdir
        os.path.expanduser(
            "~/.cache/opencode/node_modules/"
            "opencode-claude-auth/dist/transforms.js"
        ),
        # Service user — flat layout, no packages/ subdir
        "/home/opencode/.cache/opencode/node_modules/"
        "opencode-claude-auth/dist/transforms.js",
    ]
    for path in candidates:
        if os.path.isfile(path):
            return path
    return None


def patch(content):
    """Apply PascalCase tool name patch to transforms.js content."""
    if "function prefixName" in content:
        print("Already patched — skipping")
        return None

    # 1. Add prefixName/unprefixName helpers after TOOL_PREFIX constant
    helpers = '''
/**
 * PascalCase tool name prefixing to match Claude Code convention.
 * Anthropic flags lowercase mcp_ names as third-party clients.
 */
function prefixName(name) {
    return `${TOOL_PREFIX}${name.charAt(0).toUpperCase()}${name.slice(1)}`;
}
function unprefixName(name) {
    return `${name.charAt(0).toLowerCase()}${name.slice(1)}`;
}
'''
    content = content.replace(
        'const TOOL_PREFIX = "mcp_";',
        'const TOOL_PREFIX = "mcp_";' + helpers,
    )

    # 2. Replace tool definition prefixing: ${TOOL_PREFIX}${tool.name} → prefixName(tool.name)
    content = content.replace(
        "name: tool.name ? `${TOOL_PREFIX}${tool.name}` : tool.name",
        "name: tool.name ? prefixName(tool.name) : tool.name",
    )

    # 3. Replace message block prefixing: ${TOOL_PREFIX}${block.name} → prefixName(block.name)
    content = content.replace(
        "name: `${TOOL_PREFIX}${block.name}`",
        "name: prefixName(block.name)",
    )

    # 4. Update stripToolPrefix to reverse PascalCase
    #    Old: (_match, name) => '"name": "$1"'
    #    New: (_match, name) => `"name": "${unprefixName(name)}"`
    content = content.replace(
        '''return text.replace(/"name"\\s*:\\s*"mcp_([^"]+)"/g, '"name": "$1"')''',
        '''return text.replace(/"name"\\s*:\\s*"mcp_([^"]+)"/g, (_match, name) => `"name": "${unprefixName(name)}"`)''',
    )

    return content


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else find_transforms()

    if not path:
        print("ERROR: transforms.js not found — plugin may not be installed yet")
        sys.exit(1)

    if not os.path.isfile(path):
        print(f"ERROR: File not found: {path}")
        sys.exit(1)

    with open(path, "r") as f:
        content = f.read()

    patched = patch(content)
    if patched is None:
        sys.exit(0)

    with open(path, "w") as f:
        f.write(patched)

    print(f"Patched successfully: {path}")


if __name__ == "__main__":
    main()
