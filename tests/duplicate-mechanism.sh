#!/bin/bash
# One mechanism, one implementation.
#
# WHY THIS EXISTS
#
# The sibling of tests/dead-mechanism.sh. That one catches a mechanism with no
# consumer; this one catches a mechanism with two bodies.
#
# #601 is the worked example. Two sudoers installers existed: one validated a
# temp file before moving it into place, the other wrote to /etc/sudoers.d and
# validated afterwards, where a rejected policy stays on disk and locks every
# user out of sudo. Both passed review. Nobody diffed them, because nobody knew
# there were two.
#
# The same audit found escaping duplicated three ways, and the copies had
# already drifted: two JSON escapers handled backslash, quote and newline; the
# third handled only backslash and quote, so a newline in a value produced
# invalid JSON. That is the pattern. Short helpers feel harmless to re-type,
# they are copied rather than shared, and then one copy gets a fix the others
# never see. The divergence is silent until it is a bug.
#
# WHAT IS COMPARED
#
# Function bodies, with comments and blank lines stripped and each line
# trimmed, so formatting differences do not hide a duplicate and do not invent
# one either. Only exact matches are reported: near-duplicates are a judgement
# call, and a checker that makes judgement calls gets argued with rather than
# fixed.
#
# The four-line floor keeps trivial one-liner accessors out of it. Two
# functions that both say `printf '%s' "$1"` are not a shared mechanism.
#
# Deliberate duplicates go in ALLOWED with the reason. Keep it short: a growing
# allowlist means the rule is being worked around.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

python3 - <<'PY'
import collections, glob, re, sys

PRODUCTION = []
for pattern in ('lib/*.sh', 'bridges/*.sh', 'services/*.sh', 'runtimes/*.sh',
                'guidance/*.sh', 'setup.sh', 'upgrade.sh', 'verify.sh'):
    PRODUCTION += sorted(glob.glob(pattern))

MIN_BODY_LINES = 4

# Groups of functions allowed to share a body, keyed by a frozenset of
# "file:name" entries, with the reason they are not consolidated.
ALLOWED = {
    # frozenset({'a.sh:one', 'b.sh:two'}): 'why',
}

DEF = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{')

bodies = collections.defaultdict(list)
total = 0
for path in PRODUCTION:
    lines = open(path, errors='ignore').read().split('\n')
    index = 0
    while index < len(lines):
        match = DEF.match(lines[index])
        if not match:
            index += 1
            continue
        close = index + 1
        while close < len(lines) and lines[close] != '}':
            close += 1
        body = [line.strip() for line in lines[index + 1:close]]
        body = [line for line in body if line and not line.startswith('#')]
        total += 1
        if len(body) >= MIN_BODY_LINES:
            bodies['\n'.join(body)].append('%s:%s' % (path, match.group(1)))
        index = close + 1

duplicates = []
for body, where in bodies.items():
    if len(where) < 2:
        continue
    if frozenset(where) in ALLOWED:
        continue
    duplicates.append((body, sorted(where)))

print('compared %d production function bodies (>=%d lines) across %d files'
      % (total, MIN_BODY_LINES, len(PRODUCTION)))

if not duplicates:
    print('\nno duplicated mechanisms')
    sys.exit(0)

print('\n%d mechanism(s) implemented more than once:\n' % len(duplicates))
for body, where in duplicates:
    print('  %d identical lines:' % len(body.split('\n')))
    for entry in where:
        print('      %s' % entry)
    print('      %s' % body.split('\n')[0][:72])
    print()
print("""Two bodies for one mechanism is two chances to disagree, and the copies drift
without anyone noticing there was something to compare. Share one
implementation, or record the pair in ALLOWED in tests/duplicate-mechanism.sh
with the reason it must stay separate.""")
sys.exit(1)
PY
