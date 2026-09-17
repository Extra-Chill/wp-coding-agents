#!/bin/bash
# Every mechanism has a live consumer, or it gets deleted.
#
# WHY THIS EXISTS
#
# #601 was not really a bug about sudoers. lib/systems-capabilities.sh had a
# correct, validated grant installer; its only consumer was retired; the
# function stayed with zero call sites. The next component that needed a grant
# did not find it and wrote its own — which installed the file before validating
# it, so a rejected policy could be left in /etc/sudoers.d and lock every user
# out of sudo.
#
# The duplicate was the symptom. The cause was that an orphaned mechanism is
# invisible: it reads as supported infrastructure, it has a docblock describing
# what it does, and nothing tells the next author that it is already dead.
#
# Judgement does not catch this — two implementations of sudoers installation
# survived months of review. A grep does, cheaply, on every push.
#
# WHAT COUNTS AS REACHABLE
#
# Bash dispatches indirectly, so a function can be live without its name ever
# appearing at a call site. Three such dispatchers exist here, each building a
# name from a literal prefix:
#
#   "bridge_${hook}"                             bridges/_dispatch.sh
#   "guidance_${hook}"                           guidance/_dispatch.sh
#   "bridge_service_adapter_apply_${adapter}"    lib/bridge-service-adapters.sh
#
# Rather than hardcode those, this reads the prefixes out of the source, so a
# new dispatcher is understood the moment it is written. Every function whose
# name begins with a discovered prefix is treated as reachable — which is a
# deliberate blind spot: dead code under `bridge_` or `guidance_` will not be
# caught here. Narrow and honest beats broad and wrong, because a checker with
# false positives gets an allowlist, then gets ignored, then gets deleted.
#
# Adding a genuinely-unreferenced function on purpose is possible: name it in
# ALLOWED below, with the reason. That list should stay short. If it grows, the
# rule is being worked around rather than followed.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

python3 - <<'PY'
import glob, os, re, sys

# Functions defined here are production mechanism. Tests define fixtures and
# stubs, which are reachable by definition and are not audited as definitions —
# but tests DO count as callers, because a function used only by its own test
# is still a live consumer worth knowing about.
PRODUCTION = []
for pattern in ('lib/*.sh', 'bridges/*.sh', 'services/*.sh', 'runtimes/*.sh',
                'guidance/*.sh', 'setup.sh', 'upgrade.sh', 'verify.sh'):
    PRODUCTION += sorted(glob.glob(pattern))

# Anything in the repo can be a caller: shell, PHP, Python, JS, workflows, docs.
CALLERS = []
for pattern in ('**/*.sh', '**/*.php', '**/*.py', '**/*.mjs', '**/*.js',
                '**/*.yml', '**/*.yaml', '**/*.md', '**/*.json',
                'operator-entrypoints/*', 'scripts/*'):
    for path in glob.glob(pattern, recursive=True):
        if '/.git/' in path or path.startswith('.git/'):
            continue
        if os.path.isfile(path):
            CALLERS.append(path)

# Functions that are unreferenced on purpose. Keep this empty if you can.
ALLOWED = {
    # 'function_name': 'why it has no caller',
}

def read(path):
    try:
        with open(path, errors='ignore') as handle:
            return handle.read()
    except OSError:
        return ''

sources = {path: read(path) for path in set(CALLERS) | set(PRODUCTION)}

DEF = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{', re.M)
definitions = {}
for path in PRODUCTION:
    for match in DEF.finditer(sources[path]):
        definitions.setdefault(match.group(1), []).append(path)

# Discover indirect-dispatch prefixes: a quoted string that concatenates a
# literal identifier fragment with a shell expansion, e.g. "bridge_${hook}".
PREFIX = re.compile(r'"([A-Za-z_][A-Za-z0-9_]*_)\$\{')
prefixes = set()
for path, text in sources.items():
    if path.startswith('tests/'):
        continue
    prefixes.update(PREFIX.findall(text))

def referenced(name):
    word = re.compile(r'\b' + re.escape(name) + r'\b')
    definition = re.compile(r'^\s*' + re.escape(name) + r'\s*\(\)\s*\{')
    for path, text in sources.items():
        if name not in text:
            continue
        for line in text.splitlines():
            if not word.search(line):
                continue
            if definition.match(line):
                continue          # the definition is not a use of itself
            if line.lstrip().startswith('#'):
                continue          # nor is a mention in a comment
            return True
    return False

dead = []
for name, where in sorted(definitions.items()):
    if name in ALLOWED:
        continue
    if any(name.startswith(prefix) for prefix in prefixes):
        continue
    if not referenced(name):
        dead.append((name, where))

print('audited %d production functions across %d files' % (len(definitions), len(PRODUCTION)))
print('indirect-dispatch prefixes discovered: %s' % ', '.join(sorted(prefixes)))

if not dead:
    print('\nno orphaned mechanisms')
    sys.exit(0)

print('\n%d function(s) defined with no reachable caller:\n' % len(dead))
for name, where in dead:
    print('  %-48s %s' % (name, ', '.join(where)))
print("""
An orphaned mechanism reads as supported infrastructure to the next author,
who will either maintain it for nothing or write a second copy of it. Delete
it, wire it to the consumer it was built for, or name it in ALLOWED in
tests/dead-mechanism.sh with the reason.""")
sys.exit(1)
PY
