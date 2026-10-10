#!/usr/bin/env python3
"""Route stored model choices through Roadie credential rotations.

Roadie's shared pool holds the subscription accounts for the OAuth providers below. A
model still addressed directly (anthropic/..., openai/...) would either have no
login under Roadie or refresh a second copy of the same rotating token. Each
such model gets a Roadie rotation of exactly that model, and every choice of
it is pointed at the preset:

  anthropic/claude-opus-5-5  ->  roadie/anthropic-claude-opus-5-5
                                 = ["anthropic/claude-opus-5-5"]

Same model, now rotating across that provider's accounts. No routing policy is
decided here: cross-provider fallbacks are the operator's to add to a rotation.
API-key providers are left alone; keys do not rotate.

  repoint-models.py rotations --db <db> [--opencode-json <path>]
      print the rotations the stored choices need, as JSON (read-only)
  repoint-models.py apply --db <db> [--opencode-json <path>]
      rewrite the choices; counts only on stdout

<db> is the Roadie copy of discord-sessions.db, before Roadie first starts.
Variants are cleared on rewritten rows; variant names are per provider.
"""

import argparse
import json
import os
import shutil
import sqlite3
import time

OAUTH_PROVIDERS = {"anthropic", "openai", "xai", "github-copilot"}
TABLES = {"global_models": "app_id", "channel_models": "channel_id", "session_models": "session_id"}
OPENCODE_KEYS = ("model", "small_model")


def preset_name(model_id):
    """Rotation name for a direct OAuth-provider model, or None to leave it."""
    if not isinstance(model_id, str) or "/" not in model_id:
        return None
    provider, name = model_id.split("/", 1)
    if provider not in OAUTH_PROVIDERS or not name:
        return None
    return f"{provider}-{name}".replace("/", "-")


def stored_models(db):
    connection = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        models = set()
        for table in TABLES:
            if table in tables:
                models.update(row[0] for row in connection.execute(f"SELECT DISTINCT model_id FROM {table}"))
        return models
    finally:
        connection.close()


def opencode_models(path):
    if not path or not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    return {key: data[key] for key in OPENCODE_KEYS if isinstance(data.get(key), str)}


def rotations(args):
    wanted = {}
    for model_id in stored_models(args.db) | set(opencode_models(args.opencode_json).values()):
        name = preset_name(model_id)
        if name:
            wanted[name] = [model_id]
    print(json.dumps(wanted, sort_keys=True))


def apply(args):
    connection = sqlite3.connect(args.db)
    try:
        with connection:
            tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            for table, key in TABLES.items():
                if table not in tables:
                    continue
                changed = 0
                for row_key, model_id in connection.execute(f"SELECT {key}, model_id FROM {table}").fetchall():
                    name = preset_name(model_id)
                    if name:
                        connection.execute(
                            f"UPDATE {table} SET model_id = ?, variant = NULL WHERE {key} = ?",
                            (f"roadie/{name}", row_key),
                        )
                        changed += 1
                print(f"{table}: {changed} model choice(s) routed through Roadie")
    finally:
        connection.close()

    path = args.opencode_json
    if not path or not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    changed = []
    for key in OPENCODE_KEYS:
        name = preset_name(data.get(key))
        if name:
            data[key] = f"roadie/{name}"
            changed.append(key)
    if not changed:
        print("opencode.json: unchanged")
        return
    shutil.copy2(path, f"{path}.before-roadie-{time.strftime('%Y%m%d-%H%M%S')}")
    temp = f"{path}.tmp-{os.getpid()}"
    with open(temp, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
    stat = os.stat(path)
    shutil.copymode(path, temp)
    try:
        os.chown(temp, stat.st_uid, stat.st_gid)
    except PermissionError:
        pass
    os.replace(temp, path)
    print(f"opencode.json: {', '.join(changed)} routed through Roadie")


def main():
    parser = argparse.ArgumentParser()
    # `presets` is the pre-pool spelling of `rotations`, kept for callers of the
    # previous release's bridge.
    parser.add_argument("mode", choices=["rotations", "presets", "apply"])
    parser.add_argument("--db", required=True)
    parser.add_argument("--opencode-json")
    args = parser.parse_args()
    (apply if args.mode == "apply" else rotations)(args)


if __name__ == "__main__":
    main()
