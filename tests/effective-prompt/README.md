# effective-prompt

Pluggable harness that renders the Kimaki OpenCode system prompt, runs the
`dm-context-filter` plugin over it, snapshots the result, and asserts that the
managed prompt contract is what an OpenCode session actually sees.

## Why

`dm-context-filter.ts` is a security-and-context plugin. On managed installs it
replaces Kimaki's generic CLI/orchestration prompt with a small Discord bridge
prompt, while preserving non-Kimaki system blocks such as composed AGENTS.md
guidance. When the transform has a bug, leaked content is invisible until you go
reading the system prompt by hand. This harness catches those leaks at test
time.

The harness models wp-coding-agents' managed Kimaki startup flags. Services run
with `--no-critique`, so critique instructions should be absent before
`dm-context-filter` runs.

## Run it

```bash
node tests/effective-prompt/run.mjs                       # run all scenarios
node tests/effective-prompt/run.mjs --update              # refresh snapshots
node tests/effective-prompt/run.mjs --scenario=default    # one scenario
node tests/effective-prompt/run.mjs --verbose             # show what the baseline missed
```

Exit code is 0 on pass, 1 on any assertion failure.

## See the diff

After a run, the snapshots in `__snapshots__/` are committed alongside the
plugin source. To eyeball what the current managed prompt replacement emits vs
what a broken baseline leaves behind:

```bash
git --no-pager diff --no-index \
  tests/effective-prompt/__snapshots__/default.baseline.txt \
  tests/effective-prompt/__snapshots__/default.filtered.txt
```

That diff is the human-readable evidence of what `dm-context-filter` is doing.
Reviewing it is the right way to evaluate a managed prompt change.

## What's pluggable

Each scenario is a JSON file in `scenarios/`. Override any of:

- **`args`** — passed as-is to `getOpencodeSystemMessage()`. Lets you
  exercise different Discord contexts (multi-agent, no-thread, etc).
- **`filter`** — name from `filters.mjs`. Default `"current"`.
- **`baseline`** — name from `filters.mjs`. Default
  `"broken-stripsection"` (kept as diff evidence for reviewers).
- **`critiqueEnabled`** — boolean passed into Kimaki's prompt store before
  rendering. Defaults to `false` to match the managed `--no-critique` service
  configuration.
- **`triggers`** — array of `{ name, pattern }`. Pattern is a JS regex
  string; prefix with `(?i)` for case-insensitive. Defaults catch Kimaki CLI
  orchestration, tunnel, worktree, cross-project routing, and hardcoded
  component-specific guidance that must not appear in the managed Kimaki prompt.
- **`allowLeakInSection`** — array of section headings (e.g. `"## Minion
  Session Routing"`) where trigger matches are intentional and must not
  count as leaks.

To add a filter, edit `filters.mjs`. To add a scenario, drop a `.json`
file in `scenarios/` overriding any of the keys above.

## Invariants the harness enforces

For every scenario, after running both the current filter and the baseline
filter:

1. **No leaks in current**: `filtered_leaks.length === 0` for configured triggers.
2. **No regression in leak count**: current must not leak more than
   baseline.
3. **Non-Kimaki blocks preserved**: current must leave unrelated system blocks
   untouched so conditional AGENTS guidance can keep composing normally.
4. **Snapshot match**: the rendered raw / baseline / filtered prompts
   match the committed snapshots. Run with `--update` after an
   intentional change.

## Files

- `run.mjs` — harness entry point.
- `filters.mjs` — pluggable filter registry. `current` and
  `broken-stripsection` are first-class.
- `scenarios/*.json` — pluggable scenarios.
- `__snapshots__/<name>.{raw,baseline,filtered}.txt` — committed
  snapshots. The `.actual` siblings are written when a snapshot drifts
  so reviewers can `diff` them against the committed ones.
