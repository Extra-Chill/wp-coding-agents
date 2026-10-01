# Managed Kimaki context and ownership

Kimaki supplies the Discord bridge. Composed agent guidance owns coding runtime,
workspace, orchestration, and evidence policy. The managed context filter replaces
positively identified Kimaki instructions with the compact bridge contract.

## Request assembly contract

OpenCode retains the system array passed to
`experimental.chat.system.transform`. Its request builder does not necessarily
use a reassigned `output.system` property. The filter mutates the array in place;
otherwise an isolated transform test can pass while the original instructions
are serialized into the provider request (issue #647).

The same replacement handles per-call `message.system`, resumed message metadata,
synthetic instruction parts, compaction context, and provider `options.instructions`.
Ordinary user/assistant text is preserved. Composed instruction prefixes and
unrelated system blocks remain unchanged.

The filter keeps request references through parameter assembly and checks them
again in `chat.headers`, after all parameter hooks. Later reinjection into a
retained system array or provider instructions refuses dispatch with a specific
diagnostic. Errors contain no raw prompt or credential values. This check covers
the supported OpenCode hook boundary; it is not a claim about arbitrary transport
code rewriting the request after those hooks.

## Independent command ownership guard

`tool.execute.before` rejects ordinary Bash launches of Kimaki coding-session
spawning and project/worktree creation. It covers direct and absolute executable
paths, common shell/environment/package-manager wrappers, compound commands, and
command substitution. Shell help, read-only session/project inspection,
notification-only sends, uploads, and archive commands remain available.

Notification sends targeting existing sessions/threads, worktrees, or custom
working directories are rejected: those routes may invoke a coding session.
Quoted command examples printed as data remain intact.

This is an operational ownership guard, **not an arbitrary-code sandbox**. Dynamic
programs can invoke subprocesses outside these recognized CLI launch forms. The
managed runtime's own workspace admission and permission boundaries remain
necessary. Operators change policy through managed configuration; an instruction
in the conversation is not an override.

## Verification

```bash
node tests/kimaki-dispatch-contract.mjs
node tests/kimaki-live-dispatch.mjs
bash tests/kimaki-managed-plugin-rig.sh
```

The dispatch-contract test retains the caller's array and captures serialized
HTTP instructions/system messages. It also exercises lifecycle normalization,
later-hook reinjection, command refusal, and preservation of ordinary data.

The live-dispatch test runs the installed OpenCode executable in an isolated
temporary project with a loopback-only model fixture. It checks actual outgoing
provider payloads for fresh/resumed runs, then returns a forbidden tool call and
verifies refusal before a harmless sentinel executable can run. It uses no model
account and does not restart the running bot. The current live probe exercises
the OpenAI-compatible HTTP path; OAuth option and reinjection behavior are also
covered by the dispatch-contract test, not claimed as a paid live OAuth probe.

The native probe also loads a later fixture plugin that reinjects generic system
or provider-option instructions. Both cases must emit the dispatch diagnostic
with zero requests reaching the model fixture.

The managed rig runs both checks when OpenCode is installed. If it is absent, the
rig explicitly reports the native dispatch proof as unverified instead of
equating offline filter success with live coverage. Raw upstream prompt snapshot
drift is separate from final-dispatch leakage (issue #606).
