# shell/aliases.zsh — aliases available on every server.

# ---------------------------------------------------------------------------
# Files and navigation
# ---------------------------------------------------------------------------
# eza where it is installed (tools/cli.sh), plain ls where it is not — these
# machines are not all set up to the same level and the alias has to work on
# the ones that are not.
if command -v eza >/dev/null 2>&1; then
  alias ll='eza -lh --git --group-directories-first'
  alias la='eza -lah --git --group-directories-first'
  alias lt='eza --tree --level=2'
else
  alias ll='ls -lh'
  alias la='ls -lAh'
fi

command -v bat >/dev/null 2>&1 && alias cat='bat --paging=never --style=plain'
alias ..='cd ..'
alias ...='cd ../..'

# Directory sizes here, largest last.
alias duh='du -sh -- * .[!.]* 2>/dev/null | sort -h'


# ---------------------------------------------------------------------------
# Editor
# ---------------------------------------------------------------------------
# Fall back to the system vim on machines where nvim is not installed.
if command -v nvim >/dev/null 2>&1; then
  alias vim='nvim'
  alias vi='nvim'
fi


# ---------------------------------------------------------------------------
# Machine
# ---------------------------------------------------------------------------
alias srv='cd "$SRV_DIR"'
alias scratch='cd "$SCRATCH"'
alias gpus='nvidia-smi 2>/dev/null || echo "no GPU on $(hostname -s)"'

# The site's own report where there is one (checkquota on many clusters),
# then the system quota(1) with your arguments, then plain disk usage.
quota() {
  if command -v checkquota >/dev/null 2>&1; then checkquota "$@"
  elif [[ -x /usr/bin/quota ]]; then /usr/bin/quota "$@"
  else df -h "$HOME" "$SCRATCH"
  fi
}


# ---------------------------------------------------------------------------
# Coding agents
# ---------------------------------------------------------------------------
# `ca` and `cxa` run the newest model and skip every permission prompt —
# the agent then runs any command and edits any file with your user's rights
# and every token in your environment, unasked. `cx` is plain Codex; for
# Claude with its prompts, run `claude`. Nothing here takes a system
# command's name (`cc` would be the C compiler). The model names are read
# when the alias runs, so ~/.zshrc.local can move either one forward.
: ${SRV_CLAUDE_MODEL:=claude-fable-5-1}
: ${SRV_CODEX_MODEL:=gpt-6-astra}
alias ca='claude --model "$SRV_CLAUDE_MODEL" --dangerously-skip-permissions'
alias cx='codex'
alias cxa='codex --model "$SRV_CODEX_MODEL" --dangerously-bypass-approvals-and-sandbox'


# ---------------------------------------------------------------------------
# Blender (only where it is actually installed)
# ---------------------------------------------------------------------------
if [[ -n "$BPY" && -x "$BPY" ]]; then
  alias bpy='"$BPY"'
fi
