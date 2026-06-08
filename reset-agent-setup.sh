#!/usr/bin/env bash
# reset-agent-setup.sh — remove only Sleepless Agents' local agent detector hooks/state.
#
# This leaves the user's agent tool configs intact, except for hook commands that point at
# Sleepless' heartbeat helper.
set -uo pipefail

BUNDLE_ID="com.aboudjem.Sleepless"
MARKER=".sleepless/agents/heartbeat.sh"

echo "==> Resetting Sleepless agent detector setup"

if command -v python3 >/dev/null 2>&1; then
  MARKER="$MARKER" python3 <<'PY'
import json
import os
import stat
import sys

marker = os.environ["MARKER"]
home = os.path.expanduser("~")
configs = [
    os.path.join(home, ".claude", "settings.json"),
    os.path.join(home, ".codex", "hooks.json"),
    os.path.join(home, ".cursor", "hooks.json"),
]

def command_matches(value):
    return isinstance(value, str) and marker in value

def prune_entry(entry):
    if not isinstance(entry, dict):
        return entry, False, False

    if command_matches(entry.get("command")):
        return None, True, True

    hooks = entry.get("hooks")
    if not isinstance(hooks, list):
        return entry, False, False

    changed = False
    kept_hooks = []
    for hook in hooks:
        if isinstance(hook, dict) and command_matches(hook.get("command")):
            changed = True
            continue
        kept_hooks.append(hook)

    if not changed:
        return entry, False, False

    if not kept_hooks:
        return None, True, True

    updated = dict(entry)
    updated["hooks"] = kept_hooks
    return updated, False, True

for path in configs:
    if not os.path.exists(path):
        continue
    try:
        with open(path, "r", encoding="utf-8") as handle:
            root = json.load(handle)
    except Exception as exc:
        print(f"    skipped invalid JSON: {path} ({exc})", file=sys.stderr)
        continue

    if not isinstance(root, dict) or not isinstance(root.get("hooks"), dict):
        continue

    hooks = root["hooks"]
    changed = False
    for event in list(hooks.keys()):
        entries = hooks.get(event)
        if not isinstance(entries, list):
            continue

        kept_entries = []
        for entry in entries:
            updated, removed, entry_changed = prune_entry(entry)
            changed = changed or removed or entry_changed
            if updated is not None:
                kept_entries.append(updated)

        if kept_entries:
            hooks[event] = kept_entries
        else:
            del hooks[event]

    if not changed:
        continue

    tmp = f"{path}.sleepless-reset-tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(root, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, path)
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
    print(f"    removed Sleepless hooks from {path}")
PY
else
  echo "    python3 not found; hook JSON cleanup skipped"
fi

rm -rf "$HOME/.sleepless/agents"
rmdir "$HOME/.sleepless" 2>/dev/null || true
/usr/bin/defaults delete "$BUNDLE_ID" agentAutoOffEnabled 2>/dev/null || true

