# effective-prompt

Pluggable harness that renders the kimaki opencode system prompt, runs the
`dm-context-filter` plugin over it, snapshots the result, and asserts that
no banned `--agent` override examples leak into the filtered prompt that an
opencode session actually sees. The harness also exercises the plugin's
`chat.message` filter so Kimaki `MEMORY.md` injection stays suppressed.

## Why

`dm-context-filter.ts` is a security-and-context plugin. It strips only the
kimaki-shipped instructions that conflict with Data Machine's memory,
scheduling, site-runtime, and channel-bound agent model. When the filter has a
bug, the leaked content is invisible until you go reading the system prompt by
hand. This harness catches those leaks at test time.

wp-coding-agents starts managed Kimaki services with `--no-critique`, so the
harness disables critique in Kimaki's store before rendering snapshots. Set
`KIMAKI_EFFECTIVE_PROMPT_CRITIQUE=1` to inspect the upstream critique prompt.

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
plugin source. To eyeball what the current filter strips vs what a broken
baseline strips:

```bash
git --no-pager diff --no-index \
  tests/effective-prompt/__snapshots__/default.baseline.txt \
  tests/effective-prompt/__snapshots__/default.filtered.txt
```

That diff is the human-readable evidence of what `dm-context-filter` is
doing. Reviewing it is the right way to evaluate a filter change.

## What's pluggable

Each scenario is a JSON file in `scenarios/`. Override any of:

- **`args`** — passed as-is to `getOpencodeSystemMessage()`. Lets you
  exercise different Discord contexts (multi-agent, no-thread, etc).
- **`filter`** — name from `filters.mjs`. Default `"current"`.
- **`baseline`** — name from `filters.mjs`. Default
  `"broken-stripsection"` (kept as diff evidence for reviewers).
- **`triggers`** — array of `{ name, pattern }`. Pattern is a JS regex
  string; prefix with `(?i)` for case-insensitive. Default: `--agent`, which
  catches generic Kimaki agent override examples.
- **`allowLeakInSection`** — array of section headings (e.g. `"## Minion
  Session Routing"`) where trigger matches are intentional and must not
  count as leaks.

To add a filter, edit `filters.mjs`. To add a scenario, drop a `.json`
file in `scenarios/` overriding any of the keys above.

## Invariants the harness enforces

For every scenario, after running both the current filter and the
baseline filter:

1. **No leaks in current**: `filtered_leaks.length === 0`.
2. **No regression in leak count**: current must not leak more than
   baseline.
3. **Snapshot match**: the rendered raw / baseline / filtered prompts
   match the committed snapshots. Run with `--update` after an
   intentional change.
4. **Memory injection filter**: synthetic Kimaki `MEMORY.md` context and
   stale-memory reminders are removed while unrelated synthetic/user text is
   preserved.

## Files

- `run.mjs` — harness entry point.
- `filters.mjs` — pluggable filter registry. `current` and
  `broken-stripsection` are first-class.
- `scenarios/*.json` — pluggable scenarios.
- `__snapshots__/<name>.{raw,baseline,filtered}.txt` — committed
  snapshots. The `.actual` siblings are written when a snapshot drifts
  so reviewers can `diff` them against the committed ones.
