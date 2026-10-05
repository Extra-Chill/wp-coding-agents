# OpenCode agents and explicit portable bundles

OpenCode's native agents, models and operator configuration are independent of
the WordPress agent selected for memory/context. Selecting `--agent-slug` does
not install or refresh a runtime specialist graph.

Ordinary setup/upgrade preserves operator-defined agents and task/skill rules.
Homeboy reconciliation composes guidance without triggering graph projection.
An unchanged `agent.general` value recorded by the older projector is retired
once; operator edits, existing specialist files and unrelated permissions are
preserved. No files are bulk-deleted during this ownership transition.

Install or reconcile a portable specialist graph explicitly:

```sh
./setup.sh <existing setup options> --project-agent-bundle coordinator-slug
./upgrade.sh --wp-path /srv/site --project-agent-bundle coordinator-slug
```

The explicit operation retains the existing bounded graph/artifact reader and
projector, including the external WordPress transport used by hosted bundles.
It materializes declared specialist identities, models, skills, references and
task policies. The operator must request it again to refresh that graph.
Previously managed graph artifacts retain their manifest so explicit refreshes
can reconcile them without adopting unrelated files.

The coordinator's chat model is never projected into OpenCode's native
`general` agent. Configure `agent.general.model` directly; explicit graph
installation preserves it. Each declared specialist can have its own model.

For a hosted North recipe, explicitly request `--project-agent-bundle north`
when installing its declared portable specialist graph. Its package/runtime
pin must include this contract before adopting it.

This replaces the blanket-deletion approach proposed by #650: remove implicit
projection while preserving explicit portable bundles and their meaningful
external-runtime/delegation tests.
