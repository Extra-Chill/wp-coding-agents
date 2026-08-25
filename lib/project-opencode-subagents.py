#!/usr/bin/env python3
"""Safely project a Data Machine coordinator graph into OpenCode files."""

import base64
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

SENTINEL = "wp-coding-agents-opencode-subagents-v2"
MANIFEST_NAME = ".wp-coding-agents-subagents.json"
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]*$")
ACTIONS = {"allow", "deny", "ask"}
OPENCODE_ACTIONS = {"read", "edit", "glob", "grep", "bash", "task", "skill", "lsp", "question", "webfetch", "websearch", "external_directory", "doom_loop"}


def fail(message): raise ValueError(message)


def text(value, name, optional=False):
    if value is None and optional: return None
    if not isinstance(value, str) or (not optional and not value): fail(f"{name} must be a non-empty string")
    return value


def rel(value, name):
    if isinstance(value, Path): value = str(value)
    path = Path(text(value, name))
    if path.is_absolute() or ".." in path.parts or str(path) in {"", "."}: fail(f"{name} must be a normalized relative path")
    return path


def regular(path, name, root=None):
    path = Path(path)
    if root is not None:
        try: path.relative_to(root)
        except ValueError: fail(f"{name} is outside its Data Machine agent root")
    for parent in (path, *path.parents):
        if parent.exists() and parent.is_symlink(): fail(f"{name} has a symlink target or parent")
        if root is not None and parent == root: break
    try: mode = path.lstat().st_mode
    except OSError: fail(f"{name} does not exist")
    if not stat.S_ISREG(mode): fail(f"{name} must be a regular non-symlink file")
    return path


def permission(value, name):
    if not isinstance(value, dict): fail(f"{name} must be an OpenCode permission object")
    for key, rule in value.items():
        if not isinstance(key, str) or not key: fail(f"{name} has an invalid key")
        if isinstance(rule, str) and rule in ACTIONS: continue
        if isinstance(rule, dict): permission(rule, f"{name}.{key}"); continue
        fail(f"{name}.{key} must use allow, deny, or ask")
    return value


def translated_policy(value, name):
    if not isinstance(value, dict): fail(f"{name}.tool_policy must be an object")
    # `opencode` is the explicit runtime-policy namespace. Generic capability
    # policy remains Data Machine's authority; only capability IDs that are
    # exact OpenCode permission actions can tighten this deny-default adapter.
    native = value.get("opencode")
    if native is not None:
        if not isinstance(native, dict): fail(f"{name}.tool_policy.opencode must be an object")
        return permission(native.get("permission", native), f"{name}.tool_policy.opencode")
    if value.get("default") == "deny" and isinstance(value.get("allow"), list):
        return {capability: "allow" for capability in value["allow"] if isinstance(capability, str) and capability in OPENCODE_ACTIONS}
    return {}


def map_sources(value, name, root, kind=None):
    if not isinstance(value, dict): fail(f"{name} must be a source map")
    result = {}
    for target, source in value.items():
        target = rel(target, f"{name} key")
        source = regular(text(source, f"{name}.{target}"), f"{name}.{target}", root)
        if kind is not None and source != root / kind / target: fail(f"{name}.{target} is outside the expected {kind}/ root")
        result[target] = source
    return result


def embedded_sources(value, name):
    if not isinstance(value, dict): fail(f"{name} must be a source map")
    result = {}
    for target, content in value.items():
        target = rel(target, f"{name} key")
        if not isinstance(content, str): fail(f"{name}.{target} must be base64 content")
        try: result[target] = base64.b64decode(content, validate=True)
        except ValueError: fail(f"{name}.{target} must be base64 content")
    return result


def source_bytes(source):
    return source if isinstance(source, bytes) else source.read_bytes()


def skill_name(skill_file):
    raw = source_bytes(skill_file)
    if not raw.startswith(b"---\n"): fail(f"{skill_file} must have SKILL.md frontmatter")
    try: frontmatter = raw.split(b"\n---\n", 1)[0].decode("utf-8")
    except UnicodeDecodeError: fail(f"{skill_file} frontmatter must be UTF-8")
    names = [line[5:].strip() for line in frontmatter.splitlines()[1:] if line.startswith("name:")]
    if len(names) != 1 or not SLUG.fullmatch(names[0]): fail(f"{skill_file} frontmatter requires a slug name")
    return names[0]


def graph(data):
    if not isinstance(data, dict) or data.get("success") is not True: fail("agent graph must be successful")
    coordinator, nodes = text(data.get("coordinator"), "graph.coordinator"), data.get("nodes")
    if not SLUG.fullmatch(coordinator) or not isinstance(nodes, list): fail("graph coordinator or nodes is invalid")
    embedded = data.get("source_mode") == "embedded"
    if data.get("source_mode") not in (None, "embedded"): fail("graph source mode is invalid")
    result, edges_by_node = {}, {}
    for index, node in enumerate(nodes):
        name = f"graph.nodes[{index}]"
        if not isinstance(node, dict): fail(f"{name} must be an object")
        slug = text(node.get("slug"), f"{name}.slug")
        if not SLUG.fullmatch(slug) or slug in result or slug in edges_by_node: fail(f"{name}.slug is invalid or duplicated")
        edges = node.get("subagents")
        if not isinstance(edges, list) or len(edges) != len(set(edges)) or any(not isinstance(edge, str) or not SLUG.fullmatch(edge) for edge in edges): fail(f"{name}.subagents is invalid")
        edges_by_node[slug] = sorted(edges)
        sources = node.get("sources")
        if not isinstance(sources, dict): fail(f"{name}.sources must be an object")
        raw_instructions = sources.get("instructions")
        if not isinstance(raw_instructions, dict): fail(f"{name}.sources.instructions must be a source map")
        raw_skills, raw_references = sources.get("skills"), sources.get("references")
        if not isinstance(raw_skills, dict) or not isinstance(raw_references, dict): fail(f"{name}.sources skills and references must be source maps")
        if embedded:
            instructions = embedded_sources(raw_instructions, f"{name}.sources.instructions")
            skills = embedded_sources(raw_skills, f"{name}.sources.skills")
            references = embedded_sources(raw_references, f"{name}.sources.references")
        else:
            candidates = []
            for kind, raw in (("instructions", raw_instructions), ("skills", raw_skills), ("references", raw_references)):
                for target, source in raw.items():
                    target = rel(target, f"{name}.sources.{kind} key")
                    source = Path(text(source, f"{name}.sources.{kind}.{target}"))
                    candidates.append(source.parent if kind == "instructions" else source.parents[len(target.parts)])
            if not candidates: fail(f"{name}.sources must contain an artifact")
            root = candidates[0]
            if any(candidate != root for candidate in candidates): fail(f"{name}.sources do not share one agent root")
            instructions = map_sources(raw_instructions, f"{name}.sources.instructions", root)
            skills = map_sources(raw_skills, f"{name}.sources.skills", root, "skills")
            references = map_sources(raw_references, f"{name}.sources.references", root, "references")
        if not instructions and not skills and not references: fail(f"{name}.sources must contain an artifact")
        policy = translated_policy(node.get("tool_policy"), name)
        declared = node.get("skill_policy", {}).get("paths") if isinstance(node.get("skill_policy"), dict) else None
        if not isinstance(declared, list) or {rel(path, f"{name}.skill_policy.paths") for path in declared} != set(skills): fail(f"{name}.skill_policy.paths must exactly match sources.skills")
        skill_files = {path: source for path, source in skills.items() if path.name == "SKILL.md"}
        if skills and not skill_files: fail(f"{name}.sources.skills must contain SKILL.md")
        names = {path: skill_name(source) for path, source in skill_files.items()}
        if len(set(names.values())) != len(names): fail(f"{name} has duplicate SKILL.md names")
        result[slug] = {"description": text(node.get("description"), f"{name}.description"), "model": text(node.get("model"), f"{name}.model", True) or None, "instructions": instructions, "skills": skills, "references": references, "skill_names": names, "permission": policy}
    if coordinator not in edges_by_node: fail("graph does not contain its coordinator")
    if "general" in result and coordinator != "general": fail("graph child slug general is reserved for OpenCode's native subagent")
    if any(edge not in result for edges in edges_by_node.values() for edge in edges): fail("graph contains an unresolved child edge")
    return result, edges_by_node, coordinator


def wrapper(instructions):
    ordered = sorted(instructions.items())
    if len(ordered) == 1: return source_bytes(ordered[0][1])
    # Source copies remain byte-identical beside the agent; this wrapper only
    # defines their deterministic composition order for OpenCode's prompt.
    return b"\n\n".join(b"# " + str(path).encode() + b"\n\n" + source_bytes(source) for path, source in ordered)


def agent_bytes(child, task_edges):
    body = wrapper(child["instructions"])
    permission_map = {"*": "deny", **child["permission"], "task": {"*": "deny", **{edge: "allow" for edge in task_edges}}, "skill": {name: "allow" for name in sorted(child["skill_names"].values())}}
    front = ["---", f"description: {json.dumps(child['description'])}", "mode: subagent"]
    if child["model"]: front.append(f"model: {json.dumps(child['model'])}")
    front.append(f"permission: {json.dumps(permission_map, separators=(',', ':'))}")
    return "\n".join(front).encode() + b"\n---\n\n" + body + b"\n\n<!-- " + SENTINEL.encode() + b" -->\n"


def safe_target(root, relative, namespace):
    relative = rel(relative, "managed manifest entry")
    if not relative.parts or relative.parts[0] != namespace: fail(f"managed manifest entry is outside {namespace}/")
    path = root / relative
    for parent in (root, *path.parents):
        if parent.exists() and parent.is_symlink(): fail(f"managed target has a symlink parent: {path}")
        if parent == root: break
    return path


def atomic_write(path, contents, root):
    path.parent.mkdir(parents=True, exist_ok=True)
    for parent in path.parents:
        if parent.is_symlink(): fail(f"managed target has a symlink parent: {path}")
        if parent == root: break
    if path.exists() and path.is_symlink(): fail(f"managed target is a symlink: {path}")
    fd, temporary = tempfile.mkstemp(prefix=".wp-coding-agents-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle: handle.write(contents); handle.flush(); os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


def manifest(path, root):
    if not path.exists(): return {"agents": [], "artifacts": [], "task_permission": None, "skill_permission": {}}
    regular(path, "managed manifest", root)
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or data.get("sentinel") != SENTINEL: fail("managed manifest is unrecognized")
    for key in ("agents", "artifacts"):
        if not isinstance(data.get(key), list): fail(f"managed manifest {key} is invalid")
    for value in data["agents"]: safe_target(root, value, "agents")
    for value in data["artifacts"]:
        value = rel(value, "managed manifest entry")
        if value.parts[0] not in {"agents", "skills"}: fail("managed artifact is outside agents/ or skills/")
        safe_target(root, value, value.parts[0])
    if data.get("task_permission") is not None: permission({"task": data["task_permission"]}, "managed manifest task permission")
    if not isinstance(data.get("skill_permission", {}), dict): fail("managed manifest skill permission is invalid")
    permission({"skill": data.get("skill_permission", {})}, "managed manifest skill permission")
    return data


def main():
    if len(sys.argv) != 3: raise SystemExit("usage: project-opencode-subagents.py GRAPH_JSON|--stdin PROJECT_ROOT")
    try:
        raw = sys.stdin.read() if sys.argv[1] == "--stdin" else Path(sys.argv[1]).read_text(encoding="utf-8")
        nodes, edges, coordinator = graph(json.loads(raw))
        project, root = Path(sys.argv[2]), Path(sys.argv[2]) / ".opencode"
        config_path, manifest_path = project / "opencode.json", root / MANIFEST_NAME
        if not config_path.is_file() or config_path.is_symlink(): fail("opencode.json must be a regular file")
        previous = manifest(manifest_path, root)
        config = json.loads(config_path.read_text(encoding="utf-8"))
        if not isinstance(config, dict) or not isinstance(config.get("permission", {}), dict): fail("OpenCode config permission must be an object")
        config.setdefault("permission", {})
        children = {slug: node for slug, node in nodes.items() if slug != coordinator}
        all_skill_names = [name for node in nodes.values() for name in node["skill_names"].values()]
        if len(set(all_skill_names)) != len(all_skill_names): fail("graph has duplicate SKILL.md frontmatter names")
        desired, agents, artifacts = {}, [], []
        for slug, child in nodes.items():
            if slug == coordinator:
                continue
            agent = Path("agents") / f"{slug}.md"
            desired[root / agent] = agent_bytes(child, edges[slug])
            agents.append(str(agent))
            for relative, source in child["instructions"].items():
                target = Path("agents") / f"{slug}.instructions" / relative
                desired[root / target] = source_bytes(source); artifacts.append(str(target))
            skill_roots = {path.parent: name for path, name in child["skill_names"].items()}
            for relative, source in child["skills"].items():
                matching = [base for base in skill_roots if relative.is_relative_to(base)]
                if not matching: fail(f"skill support file is not below a SKILL.md: {relative}")
                base = max(matching, key=lambda value: len(value.parts))
                target = Path("skills") / skill_roots[base] / relative.relative_to(base)
                desired[root / target] = source_bytes(source); artifacts.append(str(target))
            for relative, source in child["references"].items():
                matching = [base for base in skill_roots if relative.is_relative_to(base)]
                if len(matching) != 1: fail(f"reference must belong to exactly one skill: {relative}")
                base = matching[0]
                target = Path("skills") / skill_roots[base] / "references" / relative.relative_to(base)
                desired[root / target] = source_bytes(source); artifacts.append(str(target))
        coordinator_skill_names = sorted(nodes[coordinator]["skill_names"].values())
        coordinator_artifacts = nodes[coordinator]
        skill_roots = {path.parent: name for path, name in coordinator_artifacts["skill_names"].items()}
        for relative, source in coordinator_artifacts["skills"].items():
            matching = [base for base in skill_roots if relative.is_relative_to(base)]
            if not matching: fail(f"skill support file is not below a SKILL.md: {relative}")
            base = max(matching, key=lambda value: len(value.parts))
            target = Path("skills") / skill_roots[base] / relative.relative_to(base)
            desired[root / target] = source_bytes(source); artifacts.append(str(target))
        for relative, source in coordinator_artifacts["references"].items():
            matching = [base for base in skill_roots if relative.is_relative_to(base)]
            if len(matching) != 1: fail(f"reference must belong to exactly one skill: {relative}")
            base = matching[0]
            target = Path("skills") / skill_roots[base] / "references" / relative.relative_to(base)
            desired[root / target] = source_bytes(source); artifacts.append(str(target))
        # Only the coordinator's own task configuration belongs in opencode.json.
        task = {"*": "deny", "general": "allow", **{edge: "allow" for edge in edges[coordinator]}}
        current = config["permission"].get("task")
        if current not in (None, previous["task_permission"]): fail("refusing to overwrite user-owned OpenCode permission.task")
        current_skill = config["permission"].get("skill", {})
        if not isinstance(current_skill, dict): fail("refusing to overwrite non-map OpenCode permission.skill")
        previous_skill = previous["skill_permission"]
        if any(current_skill.get(name) != action for name, action in previous_skill.items()): fail("refusing to overwrite user-owned OpenCode permission.skill")
        coordinator_skill_permission = {name: "allow" for name in coordinator_skill_names}
        old = {safe_target(root, item, "agents") for item in previous["agents"]}
        old |= {safe_target(root, item, rel(item, "managed manifest entry").parts[0]) for item in previous["artifacts"]}
        old_agents = {safe_target(root, item, "agents") for item in previous["agents"]}
        for path in desired:
            if path.exists() and path not in old: fail(f"refusing to overwrite user-owned OpenCode file: {path}")
            if path.exists() and path.is_symlink(): fail(f"managed target is a symlink: {path}")
            if path in old_agents and path.exists() and SENTINEL.encode() not in path.read_bytes(): fail(f"refusing to overwrite user-modified OpenCode agent: {path}")
        for path, contents in desired.items():
            if not path.is_file() or path.read_bytes() != contents: atomic_write(path, contents, root)
        for path in old - set(desired):
            if path.exists():
                if path.is_symlink() or not path.is_file(): fail(f"managed stale target is unsafe: {path}")
                path.unlink()
        if current != task:
            config["permission"]["task"] = task
        if coordinator_skill_permission:
            config["permission"]["skill"] = {**current_skill, **coordinator_skill_permission}
        elif previous_skill:
            config["permission"]["skill"] = {key: value for key, value in current_skill.items() if key not in previous_skill}
        if config["permission"].get("task") != current or config["permission"].get("skill", {}) != current_skill:
            atomic_write(config_path, (json.dumps(config, indent=2) + "\n").encode(), project)
        data = {"sentinel": SENTINEL, "agents": sorted(agents), "artifacts": sorted(artifacts), "task_permission": task, "skill_permission": coordinator_skill_permission}
        serialized = (json.dumps(data, indent=2, sort_keys=True) + "\n").encode()
        if not manifest_path.is_file() or manifest_path.read_bytes() != serialized: atomic_write(manifest_path, serialized, root)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"OpenCode subagent projection failed: {error}", file=sys.stderr); return 1
    return 0


if __name__ == "__main__": raise SystemExit(main())
