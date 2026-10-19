#!/usr/bin/env bash
# tools/claude.sh — Claude Code.
#
# The native installer, not npm: it drops a self-contained binary in
# ~/.local/bin/claude with its versions under ~/.local/share/claude, so no
# node runtime is needed and nothing depends on a cluster module.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

if have claude && updating && [ "$(command -v claude)" = "$HOME/.local/bin/claude" ]; then
    # The native install keeps itself current: `claude update` fetches the
    # latest release into ~/.local/share/claude and repoints the binary.
    if [ "$SRV_DRY_RUN" = 1 ]; then
        say "would run: claude update"
    elif claude update >/dev/null 2>&1; then
        say "updated claude $(claude --version 2>/dev/null | head -1)"
    else
        warn "claude update failed — re-run later, or reinstall from https://claude.ai/install.sh"
    fi
elif have claude; then
    say "ok   claude $(claude --version 2>/dev/null | head -1) ($(command -v claude))"
elif [ "$SRV_DRY_RUN" = 1 ]; then
    say "would install Claude Code from https://claude.ai/install.sh"
elif ! online; then
    warn "offline — skipping Claude Code"
elif install_script "Claude Code" https://claude.ai/install.sh bash; then
    say "installed claude -> $HOME/.local/bin/claude"
else
    warn "see https://docs.claude.com/claude-code"
fi

# settings.json is seeded rather than copied over: Claude Code rewrites it
# itself (enabling a plugin, recording a marketplace), and those edits are
# machine-local. The bundle installs no skills.
step "Claude Code configuration"
copy_once config/claude/settings.json .claude/settings.json

# server.json's claude.settings object is merged over ~/.claude/settings.json
# (top-level keys replaced, the rest kept), so the plugin and marketplace
# entries Claude Code writes itself survive.
. "$SRV_DIR/lib/config.sh"
if [ -n "$(cfg claude.settings)" ]; then
    if [ "$SRV_DRY_RUN" = 1 ]; then
        say "would merge server.json claude.settings into ~/.claude/settings.json"
    elif have python3; then
        SRV_CLAUDE_SETTINGS="$(cfg claude.settings)" python3 - "$HOME/.claude/settings.json" <<'PY'
import json, os, pathlib, sys
dst = pathlib.Path(sys.argv[1])
wanted = json.loads(os.environ["SRV_CLAUDE_SETTINGS"])
current = json.loads(dst.read_text()) if dst.exists() else {}
changed = {k: v for k, v in wanted.items() if current.get(k) != v}
if changed:
    current.update(wanted)
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(json.dumps(current, indent=2) + "\n")
    for k in changed:
        print(f"   set  {k} (~/.claude/settings.json)")
else:
    print("   ok   ~/.claude/settings.json already has server.json's settings")
PY
    else
        warn "python3 is needed to merge claude.settings — skipped"
    fi
fi

if [ ! -s "$HOME/.claude.json" ] && [ "$SRV_DRY_RUN" != 1 ]; then
    say "note: run \`claude\` once to sign in (this machine has no credentials yet)"
fi
