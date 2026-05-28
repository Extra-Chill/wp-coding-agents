# effective-prompt

Pluggable harness that renders the kimaki opencode system prompt, runs the
`dm-context-filter` plugin over it, snapshots the result, and asserts that
Data Machine-owned Kimaki policy sections do not leak into the filtered prompt
that an opencode session actually sees.

## Why

`dm-context-filter.ts` is a security-and-context plugin. It strips
kimaki-shipped instructions that conflict with Data Machine's memory,
scheduling, and managed WordPress runtime policy. When the filter has a bug,
the leaked content is invisible until you go reading the system prompt by
hand. This harness catches those leaks at test time.

The harness models wp-coding-agents' managed Kimaki startup flags. In
particular, services run with `--no-critique`, so critique instructions should
be absent before `dm-context-filter` runs. Kimaki 0.13 also falls back to the
build agent when a requested agent does not exist, so generic `--agent
<current_agent>` guidance is no longer treated as a filter leak.

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
- **`critiqueEnabled`** — boolean passed into Kimaki's prompt store before
  rendering. Defaults to `false` to match the managed `--no-critique` service
  configuration.
- **`triggers`** — array of `{ name, pattern }`. Pattern is a JS regex
  string; prefix with `(?i)` for case-insensitive. Defaults catch the headings
  that Data Machine still intentionally filters: permissions, Kimaki upgrades,
  Kimaki scheduling, dev-server tunnels, and cross-session history.
- **`allowLeakInSection`** — array of section headings (e.g. `"## Minion
  Session Routing"`) where trigger matches are intentional and must not
  count as leaks.

To add a filter, edit `filters.mjs`. To add a scenario, drop a `.json`
file in `scenarios/` overriding any of the keys above.

## Invariants the harness enforces

For every scenario, after running both the current filter and the
baseline filter:

1. **No leaks in current**: `filtered_leaks.length === 0` for configured triggers.
2. **No regression in leak count**: current must not leak more than
   baseline.
3. **Snapshot match**: the rendered raw / baseline / filtered prompts
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
