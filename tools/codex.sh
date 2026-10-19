#!/usr/bin/env bash
# tools/codex.sh — OpenAI Codex CLI.
#
# The standalone installer, not npm: it unpacks a musl-static binary under
# ~/.codex/packages/ and links ~/.local/bin/codex at it, so it runs on the
# clusters' older glibc without any runtime to install.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# Under --update, only a copy this script installed is refreshed: one from
# Homebrew or npm stays with its own manager, not shadowed by a second copy.
if have codex && { ! updating || [ "$(command -v codex)" != "$HOME/.local/bin/codex" ]; }; then
    say "ok   codex $(codex --version 2>/dev/null | head -1) ($(command -v codex))"
elif [ "$SRV_DRY_RUN" = 1 ]; then
    say "would install Codex from https://chatgpt.com/codex/install.sh"
elif ! online; then
    warn "offline — skipping Codex"
elif install_script "Codex" https://chatgpt.com/codex/install.sh bash; then
    # The standalone installer always fetches the latest release, so the same
    # step installs and updates.
    say "$(updating && echo updated || echo installed) codex $(codex --version 2>/dev/null | head -1) -> $HOME/.local/bin/codex"
else
    warn "see https://developers.openai.com/codex/cli"
fi

# Seeded, not symlinked: codex appends a [projects."<path>"] trust entry to
# this file as you use it, and those paths are machine-local.
step "Codex configuration"
copy_once config/codex/config.toml .codex/config.toml

# server.json's codex.model and codex.model_reasoning_effort are applied on
# every run: only those two top-level keys are rewritten, so the trust
# entries codex adds stay. Top-level keys sit before the first [table].
. "$SRV_DIR/lib/config.sh"
set_toml_key() {
    local file="$HOME/.codex/config.toml" key="$1" value="$2"
    [ -n "$value" ] || return 0
    if [ "$SRV_DRY_RUN" = 1 ]; then say "would set $key = \"$value\" in ~/.codex/config.toml"; return 0; fi
    [ -f "$file" ] || return 0
    if grep -q "^$key *= *\"$value\"" "$file"; then return 0; fi
    python3 - "$file" "$key" "$value" <<'PY' || warn "could not set $key in ~/.codex/config.toml"
import pathlib, re, sys
path, key, value = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
head, sep, tail = text.partition("\n[")          # top-level keys live before the first table
line = f'{key} = "{value}"'
if re.search(rf"^{re.escape(key)} *=", head, re.M):
    head = re.sub(rf"^{re.escape(key)} *=.*$", line, head, count=1, flags=re.M)
else:
    head = head.rstrip("\n") + "\n" + line + "\n"
path.write_text(head + sep + tail)
PY
    say "set  $key = \"$value\" (~/.codex/config.toml)"
}
set_toml_key model "$(cfg codex.model)"
set_toml_key model_reasoning_effort "$(cfg codex.model_reasoning_effort)"

if [ ! -e "$HOME/.codex/auth.json" ] && [ "$SRV_DRY_RUN" != 1 ]; then
    say "note: run \`codex login\` once to sign in (this machine has no credentials yet)"
fi
