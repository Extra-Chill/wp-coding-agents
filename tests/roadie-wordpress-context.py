#!/usr/bin/env python3
"""OpenCode instruction repair is not part of Roadie's context provider."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
assert not (root / 'lib/repair-opencode-json.py').exists()
assert not (root / 'runtimes/opencode.sh').exists()
plugin = (root / 'bridges/roadie/roadie-plugins/wordpress-context.mjs').read_text()
assert 'resolve-chat-person' in plugin
print('PASS: Roadie context is native; no OpenCode instruction repair')
