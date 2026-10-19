#!/usr/bin/env bash
# tests/check.sh — the offline checks: syntax, lint, profiles, the module
# loader, every installer's dry run and setup.sh's dry run per profile.
#
#   tests/check.sh
#
# Safe on the machine you work on: everything runs against a scratch copy of
# the bundle (no .git, no server.json, no *.local.sh, no secrets — what a
# fresh clone has) and a scratch $HOME, and every installer runs dry. Runs on
# macOS's bash 3.2 as well as Linux, which is half of what it is checking.
# tests/container.sh is the real install, for a disposable machine.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Through cd/pwd: a TMPDIR ending in / would give a path with // in it.
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/srvcheck.XXXXXX")" && pwd)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0 SECTION_FAILED=0
fail() { printf '  FAIL %s\n' "$*"; FAILED=1; SECTION_FAILED=1; }
section() { printf '\n== %s\n' "$*"; SECTION_FAILED=0; }
# passed <summary> : print the section's summary when nothing in it failed
passed() { (( SECTION_FAILED )) || printf '  ok   %s\n' "$*"; }

# The copy every check below runs against: the tracked files only, plus the
# working-tree edits to them, so an uncommitted change is checked too.
SRV="$WORK/server"
mkdir -p "$SRV"
# Only the bundle's own repo: a zip install under some other repo (a $HOME
# dotfiles repo, say) would answer for that one instead.
if [ "$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" = "$REPO" ]; then
    (cd "$REPO" && git ls-files -z --cached --others --exclude-standard |
        while IFS= read -r -d '' f; do
            [ -e "$f" ] || continue                 # deleted in the working tree
            mkdir -p "$SRV/$(dirname "$f")" && cp -p "$f" "$SRV/$f"
        done)
else
    cp -Rp "$REPO/." "$SRV/"
    rm -rf "$SRV/.git" "$SRV/server.json" "$SRV/.srv-config.sh" "$SRV/.srv-state" \
           "$SRV/secrets/secrets.enc" "$SRV"/hosts/*.local.sh
fi
SANDBOX_HOME="$WORK/home"
mkdir -p "$SANDBOX_HOME"

PROFILES=()
for f in "$SRV"/hosts/*.sh; do
    case "$f" in *.local.sh) continue ;; esac
    PROFILES+=("$(basename "$f" .sh)")
done


section "Syntax"
for f in "$SRV"/setup.sh "$SRV"/install/*.sh "$SRV"/secrets/secrets.sh "$SRV"/tools/*.sh \
         "$SRV"/lib/*.sh "$SRV"/config/git/hooks/pre-push "$SRV"/tests/*.sh; do
    bash -n "$f" 2>/dev/null || fail "bash -n ${f#"$SRV"/}"
done
for f in "$SRV"/shell/zshrc "$SRV"/shell/*.zsh; do
    zsh -n "$f" 2>/dev/null || fail "zsh -n ${f#"$SRV"/}"
done
# env.sh and detect.sh are POSIX sh: dash is the strictest common parser.
if command -v dash >/dev/null 2>&1; then
    for f in "$SRV"/shell/env.sh "$SRV"/lib/detect.sh; do
        dash -n "$f" 2>/dev/null || fail "dash -n ${f#"$SRV"/}"
    done
fi
passed "bash, zsh and POSIX sh parse every script"


section "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
    if (cd "$SRV" && shellcheck -x -S warning setup.sh secrets/secrets.sh install/*.sh tools/*.sh tests/*.sh); then
        passed "no warnings"
    else
        fail "shellcheck reported warnings"
    fi
else
    printf '  skip shellcheck is not installed\n'
fi


section "Version"
v="$(cat "$SRV/VERSION" 2>/dev/null || true)"
printf '%s\n' "$v" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "VERSION is not MAJOR.MINOR.PATCH: '$v'"
[ "$("$SRV/setup.sh" --version 2>&1)" = "OpenServer $v" ] || fail "setup.sh --version does not print VERSION"
passed "VERSION is $v; setup.sh --version prints it"


section "Publishable"
# The repository is public. No tracked file may carry an e-mail address (other
# than the documentation's placeholders), a home-directory path from a real
# machine, or a token-shaped string (docs/releasing.md, "Before every push").
# This file is skipped: it holds the token patterns and a fake token itself.
(cd "$SRV" && grep -rnI -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z.]{2,}' --exclude-dir=.git . |
    grep -v -E '^\./tests/check\.sh:' |
    grep -v -E '(git@github\.com|@example\.com|@users\.noreply\.github\.com)' ) > "$WORK/emails" || true
[ -s "$WORK/emails" ] && fail "e-mail addresses in tracked files: $(head -n 3 "$WORK/emails" | tr '\n' ' ')"
(cd "$SRV" && grep -rnI -E '(/Users/[A-Za-z][A-Za-z0-9._-]*|/home/[a-z][a-z0-9._-]*/)' --exclude-dir=.git . |
    grep -v -E '^\./tests/check\.sh:' ) > "$WORK/paths" || true
[ -s "$WORK/paths" ] && fail "home-directory paths in tracked files: $(head -n 3 "$WORK/paths" | tr '\n' ' ')"
(cd "$SRV" && grep -rnI -E '(gh[pousr]_|github_pat_|hf_|sk-)[A-Za-z0-9_]{20,}' --exclude-dir=.git . |
    grep -v -E '^\./(tests/check\.sh|lib/config\.sh):' ) > "$WORK/tokens" || true
[ -s "$WORK/tokens" ] && fail "token-shaped strings in tracked files: $(cut -d: -f1-2 "$WORK/tokens" | head -n 3 | tr '\n' ' ')"
passed "no e-mail address, home path or token in any tracked file"


# From here on nothing may reach this machine's own state. On macOS a program
# run with a scratch $HOME looks for a Keychain there, finds none, and macOS
# asks about it in a dialog that blocks the program — git's osxkeychain helper
# (named in the system gitconfig) and gh both do. So: no system git config,
# no credential prompts, gh in a scratch config, Homebrew never updating, and
# a PATH of the system's own directories, so the installers' dry runs and
# setup.sh never run this machine's claude, codex, gh, rclone or brew.
TMUX_BIN="$(command -v tmux || true)"
export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never
export GH_CONFIG_DIR="$WORK/gh" HOMEBREW_NO_AUTO_UPDATE=1
# zsh reads its startup files from $ZDOTDIR when that is set, which would be
# this machine's own ~/.zshrc rather than the scratch home's.
unset ZDOTDIR
export PATH=/usr/bin:/bin:/usr/sbin:/sbin


section "Profiles"
# Every profile sets the same SRV_* names in the same order as generic.sh.
names() { grep -oE '^SRV_[A-Z_]+=' "$1" | tr -d '=' | tr '\n' ' '; }
want="$(names "$SRV/hosts/generic.sh")"
for p in "${PROFILES[@]}"; do
    got="$(names "$SRV/hosts/$p.sh")"
    [ "$got" = "$want" ] || fail "hosts/$p.sh sets [$got], generic.sh sets [$want]"
done
# lib/detect.sh resolves to the same values under bash and zsh: every
# profile value by name, exported or not.
show_names="$want SRV_HOST SRV_OS SRV_PROFILE"
# shellcheck disable=SC2016  # expanded by the child shell
SHOW='. "$SRV_DIR/lib/detect.sh"; for n in $NAMES; do eval "v=\${$n-}"; printf "%s=%s\n" "$n" "$v"; done'
for p in "${PROFILES[@]}"; do
    a="$(SRV_HOST=$p SRV_DIR=$SRV HOME=$SANDBOX_HOME NAMES="$show_names" bash -c "$SHOW")" || a="<exit $?>"
    b="$(SRV_HOST=$p SRV_DIR=$SRV HOME=$SANDBOX_HOME NAMES="$show_names" zsh -c "setopt sh_word_split; $SHOW")" || b="<exit $?>"
    [ "$a" = "$b" ] || fail "lib/detect.sh differs between bash and zsh for $p"
    printf '%s\n' "$a" | grep -qx "SRV_HOST=$p" || fail "SRV_HOST=$p did not select hosts/$p.sh"
done
# shell/env.sh is silent and succeeds in both shells, interactive or not.
for p in "${PROFILES[@]}"; do
    for sh in bash zsh; do
        out="$(SRV_HOST=$p SRV_DIR=$SRV HOME=$SANDBOX_HOME $sh -c '. "$SRV_DIR/shell/env.sh"' 2>&1)" ||
            fail "shell/env.sh failed under $sh for $p"
        [ -z "$out" ] || fail "shell/env.sh printed under $sh for $p: $out"
    done
done
mkdir -p "$SRV/hosts/local"
sed 's/^# hosts: .*/# hosts: */' "$SRV/hosts/example-cluster.sh" > "$SRV/hosts/local/mine.sh"
got="$(SRV_DIR=$SRV HOME=$SANDBOX_HOME bash -c '. "$SRV_DIR/lib/detect.sh"; echo "$SRV_HOST ${SRV_PROFILE#"$SRV_DIR"/}"')" || got=""
[ "$got" = "mine hosts/local/mine.sh" ] || fail "a profile of your own in hosts/local/ was not picked: got '$got'"
rm -rf "$SRV/hosts/local"
sed 's/^# os: .*/# hosts: */' "$SRV/hosts/generic.sh" > "$SRV/hosts/generic.local.sh"
got="$(SRV_DIR=$SRV HOME=$SANDBOX_HOME bash -c '. "$SRV_DIR/lib/detect.sh"; echo "$SRV_HOST"')" || got=""
[ "$got" != generic.local ] || fail "a .local.sh override with a profile header was taken for a profile"
rm -f "$SRV/hosts/generic.local.sh"
passed "${#PROFILES[@]} profiles: same names and order, same values in bash and zsh, env.sh silent; hosts/local/ read; .local.sh never a profile"


section "Module loader"
# The block of shell/zshrc that loads modules, run against a fake `module`
# that knows miniconda3 (default) and cuda/12.4 (no default).
loader="$(sed -n '/^typeset -ga SRV_MODULES_MISSING/,/^unset -f _srv_module_load/p' "$SRV/shell/zshrc")"
[ -n "$loader" ] || fail "module loader block not found in shell/zshrc"
got="$(LOADER="$loader" zsh -fc '
    loaded=()
    module() {
        case "$1" in
            load)  case "$2" in miniconda3|cuda/12.4) loaded+=("$2"); return 0 ;; esac; return 1 ;;
            -t)    [[ "$3" == cuda ]] && print -u2 "cuda/12.4"; return 0 ;;
        esac
        return 1
    }
    SRV_MODULES="anaconda3|miniconda3 cudatoolkit|cuda nonexistent"
    eval "$LOADER"
    print -r -- "loaded=${loaded[*]} missing=${SRV_MODULES_MISSING[*]}"')" || got="<exit $?>"
[ "$got" = "loaded=miniconda3 cuda/12.4 missing=nonexistent" ] ||
    fail "alternatives and newest-version fallback: got '$got'"
got="$(LOADER="$loader" zsh -fc 'SRV_MODULES="anaconda3"; eval "$LOADER"; print -r -- "missing=${SRV_MODULES_MISSING[*]}"')" || got="<exit $?>"
[ "$got" = "missing=" ] || fail "with no module command nothing should run: got '$got'"
passed "alternatives, newest-version fallback, missing list, no-module machine"


section "Settings (server.json)"
render() {   # render <json> : exit status of lib/config.sh's render, in the copy
    printf '%s\n' "$1" > "$WORK/server.json"
    SRV_DIR=$SRV SRV_CONFIG=$WORK/server.json bash -c \
        '. "$SRV_DIR/lib/common.sh"; . "$SRV_DIR/lib/config.sh"; srv_config_render' >/dev/null 2>&1
}
if command -v python3 >/dev/null 2>&1; then
    render "$(cat "$SRV/server.example.json")" || fail "server.example.json does not render"
    grep -q "^export SRV_CFG_setup_conda=no$" "$SRV/.srv-config.sh" 2>/dev/null ||
        fail "server.example.json rendered without setup.conda=no"
    render '{"git": {"token": "x"}}' && fail "a credential-named key was accepted"
    render '{"git": {"name": "ghp_abcdefghijklmnopqrstuvwxyz"}}' && fail "a token-shaped value was accepted"
    rm -f "$SRV/.srv-config.sh"
    passed "example renders; credential-shaped keys and values are refused"
else
    printf '  skip python3 is not installed\n'
fi


section "deploy"
got="$(HOME=$SANDBOX_HOME SRV_DIR=$SRV SRV_BACKUP_DIR=$SANDBOX_HOME/.server-backup/t bash -c '
    set -eu; . "$SRV_DIR/lib/common.sh"
    deploy shell/zshrc .zshrc; deploy shell/zshrc .zshrc
    echo mine > "$HOME/.p10k.zsh"; deploy shell/p10k.zsh .p10k.zsh
    deploy no/such/file .nope')" || got="<exit $?>"
printf '%s\n' "$got" | grep -q '^   copy .zshrc$'  || fail "deploy did not copy a new file"
printf '%s\n' "$got" | grep -q '^   ok   .zshrc$'  || fail "deploy re-copied an identical file"
[ "$(cat "$SANDBOX_HOME/.server-backup/t/.p10k.zsh" 2>/dev/null)" = mine ] || fail "deploy did not back up the file it replaced"
cmp -s "$SRV/shell/p10k.zsh" "$SANDBOX_HOME/.p10k.zsh" || fail "deploy did not replace a changed file"
rm -rf "$SANDBOX_HOME" && mkdir -p "$SANDBOX_HOME"
passed "copies, skips identical, backs up what it replaces"


section "Installers, dry run"
# Every installer must exit 0 when it has nothing to do — setup.sh reports
# anything else as a failure. Both plain and --update runs.
for update in 0 1; do
    for t in zsh tmux nvim cli rclone uv claude codex; do
        HOME=$SANDBOX_HOME SRV_DIR=$SRV SRV_DRY_RUN=1 SRV_UPDATE=$update \
            bash "$SRV/tools/$t.sh" >/dev/null 2>&1 || fail "tools/$t.sh exits non-zero (SRV_UPDATE=$update)"
    done
    HOME=$SANDBOX_HOME SRV_DIR=$SRV SRV_DRY_RUN=1 SRV_UPDATE=$update \
        bash "$SRV/tools/conda.sh" condarc >/dev/null 2>&1 || fail "tools/conda.sh condarc exits non-zero (SRV_UPDATE=$update)"
done
passed "every installer exits 0, plain and --update"


section "setup.sh, dry run per profile"
for p in "${PROFILES[@]}"; do
    for flags in "" "--update"; do
        # shellcheck disable=SC2086  # $flags is empty or one word
        if ! out="$(HOME=$SANDBOX_HOME SRV_HOST=$p "$SRV/setup.sh" --dry-run --here $flags \
                    --no-conda --no-gdrive --no-github --no-secrets 2>&1)"; then
            fail "setup.sh $flags exits non-zero for $p"
        elif printf '%s\n' "$out" | grep -q 'did not finish cleanly'; then
            fail "setup.sh $flags for $p: $(printf '%s\n' "$out" | grep 'did not finish cleanly' | head -1)"
        fi
    done
done
# What this bundle writes. Other state is not ours: `rclone version`, gh and
# python create their own cache directories just by being asked a question.
for f in .zshrc .bashrc .bash_profile .p10k.zsh .gitconfig .gitconfig.local .config/git \
         .tmux.conf .tmux.conf.local .secrets.env .condarc .server-backup .claude .codex \
         .oh-my-zsh .tmux/plugins .config/nvim software .local/bin .ssh; do
    [ ! -e "$SANDBOX_HOME/$f" ] || fail "a dry run wrote ~/$f"
done
# Pruning keeps this machine's profile and its site's, drops other profiles,
# and never touches a .local.sh or hosts/local/ (yours, git-ignored).
sed 's/^SRV_SITE=""/SRV_SITE="sitex"/' "$SRV/hosts/example-cluster.sh" > "$SRV/hosts/c1.sh"
cp "$SRV/hosts/generic.sh" "$SRV/hosts/sitex.sh"; cp "$SRV/hosts/generic.sh" "$SRV/hosts/other.sh"
printf '# placeholder\n' > "$SRV/hosts/other.local.sh"
out="$(HOME=$SANDBOX_HOME SRV_HOST=c1 "$SRV/setup.sh" --dry-run --here \
       --no-conda --no-gdrive --no-github --no-secrets 2>&1)" || true
printf '%s\n' "$out" | grep -q 'would drop hosts/other.sh' || fail "pruning kept another machine's profile"
printf '%s\n' "$out" | grep -qE 'would drop hosts/(sitex|c1)\.sh' && fail "pruning dropped this machine's or its site's profile"
printf '%s\n' "$out" | grep -q 'would drop hosts/other.local.sh' && fail "pruning would delete a git-ignored .local.sh"
rm -f "$SRV/hosts/c1.sh" "$SRV/hosts/sitex.sh" "$SRV/hosts/other.sh" "$SRV/hosts/other.local.sh"
passed "${#PROFILES[@]} profiles, plain and --update: exit 0, every step clean, nothing written, the right profiles pruned"



section "setup.sh --config-only, for real, in a sandbox"
# The non-dry path end to end with no network: configs land in a scratch
# $HOME, the copy (no remote) is pruned and committed as a fresh zip install
# would be — with no git identity, which a fresh machine does not have yet.
if out="$(cd "$WORK" && HOME=$SANDBOX_HOME GIT_CONFIG_NOSYSTEM=1 SRV_HOST=generic \
          "$SRV/setup.sh" --here --config-only --no-secrets 2>&1)"; then
    for f in .zshrc .bashrc .bash_profile .p10k.zsh .gitconfig .config/git/ignore \
             .tmux.conf .tmux.conf.local .secrets.env; do
        [ -e "$SANDBOX_HOME/$f" ] || fail "--config-only did not write ~/$f"
    done
    git -C "$SRV" log --oneline -1 2>/dev/null | grep -q 'Import bundle' ||
        fail "the bundle was not committed to a local repo: $(printf '%s\n' "$out" | grep -E '!|git' | head -3)"
    [ ! -e "$SRV/hosts/example-cluster.sh" ] || fail "the first run did not prune the other machines' profiles"
    [ -e "$SRV/.srv-state" ] || fail "the first run did not record .srv-state"
    out2="$(cd "$WORK" && HOME=$SANDBOX_HOME GIT_CONFIG_NOSYSTEM=1 SRV_HOST=generic \
            "$SRV/setup.sh" --here --config-only --no-secrets 2>&1)" || fail "the second --config-only run exited non-zero"
    printf '%s\n' "$out2" | grep -qE '^   (copy|back|block|new) ' && fail "the second run replaced files it had just written"
else
    fail "setup.sh --config-only exited non-zero: $(printf '%s\n' "$out" | tail -3)"
fi
passed "configs written, bundle pruned and committed without a git identity, second run a no-op"


section "bash keeps your own startup files"
# setup.sh --config-only against three scratch homes. The bundle copy was
# set up above, so these runs do not prune or commit again.
setup_in() {   # setup_in <home> : --config-only with that $HOME; prints its output
    (cd "$WORK" && HOME=$1 GIT_CONFIG_NOSYSTEM=1 SRV_HOST=generic \
        "$SRV/setup.sh" --here --config-only --no-secrets 2>&1)
}
blocks() { grep -c '^# >>> server ' "$1" 2>/dev/null || true; }

envblocks() { grep -c '^# >>> server-env ' "$1" 2>/dev/null || true; }
# The user's own lines: the file with every complete server block taken out.
own_lines() { awk '/^# >>> server/ { skip = 1 } !skip { print } /^# <<< server/ { skip = 0 }' "$1" | grep -v '^$'; }

# An Ubuntu-style home: a ~/.bashrc that returns early when not interactive,
# and a ~/.profile that reads it. These homes have no ~/server: the blocks
# must carry the bundle's real path (this run is --here), so no SRV_DIR is
# passed to the shells below.
H="$WORK/home-ubuntu"; mkdir -p "$H"
printf 'case $- in *i*) ;; *) return;; esac\nexport MINE=1\nmine() { echo mine; }\n' > "$H/.bashrc"
own_lines "$H/.bashrc" > "$WORK/bashrc.own"
printf '# ~/.profile\nif [ -n "$BASH_VERSION" ]; then . "$HOME/.bashrc"; fi\n' > "$H/.profile"
cp "$H/.profile" "$WORK/profile.orig"
setup_in "$H" >/dev/null || fail "setup.sh exited non-zero (existing ~/.bashrc)"
own_lines "$H/.bashrc" | cmp -s - "$WORK/bashrc.own" || fail "your own ~/.bashrc lines changed"
[ "$(envblocks "$H/.bashrc")" = 1 ] && [ "$(head -n 1 "$H/.bashrc")" = "$(printf '%s' '# >>> server-env ')(added by ~/server/setup.sh; delete this block to opt out) >>>" ] ||
    fail "the environment block is not first in ~/.bashrc"
[ "$(blocks "$H/.bashrc")" = 1 ] && [ "$(tail -n 1 "$H/.bashrc")" = '# <<< server <<<' ] || fail "the server block is not last, once, in ~/.bashrc"
grep -qF "export SRV_DIR=\"$SRV\"" "$H/.bashrc" || fail "with the bundle away from ~/server, the blocks do not name its path"
cmp -s "$H/.profile" "$WORK/profile.orig" || fail "\$HOME/.profile changed although it reads .bashrc"
[ ! -e "$H/.bash_profile" ] || fail "a ~/.bash_profile was created, hiding ~/.profile"
# `ssh host cmd`: non-interactive, so this ~/.bashrc returns early — after the top block.
got="$(HOME=$H bash -c '. "$HOME/.bashrc"; echo "${SCRATCH:-}"' </dev/null 2>&1)" || got="<exit $?>"
[ "$got" = "$H" ] || fail "a non-interactive bash (ssh host cmd) did not get the environment: got '$got'"
[ -z "$(HOME=$H bash -c '. "$HOME/.bashrc"' </dev/null 2>&1)" ] || fail "a non-interactive bash printed something (it breaks scp)"
# An interactive bash with no terminal (no hand-over): your lines and the environment.
got="$(HOME=$H bash -ic 'echo "R=$MINE|${SCRATCH:-}|$(type -t mine)"' </dev/null 2>/dev/null | grep '^R=')" || got="<exit $?>"
[ "$got" = "R=1|$H|function" ] || fail "an interactive bash should keep your lines and gain the environment: got '$got'"
out="$(setup_in "$H")" || true
[ "$(printf '%s\n' "$out" | grep -c '^   ok   .bashrc$')" = 2 ] || fail "a second run did not leave both current blocks alone"
# A later `conda init` appends after the block; the next run moves the block back to the end.
printf '# >>> conda initialize >>>\nexport CONDA_MARK=1\n# <<< conda initialize <<<\n' >> "$H/.bashrc"
setup_in "$H" >/dev/null
[ "$(blocks "$H/.bashrc")" = 1 ] && [ "$(tail -n 1 "$H/.bashrc")" = '# <<< server <<<' ] &&
    grep -q '^export CONDA_MARK=1$' "$H/.bashrc" || fail "lines appended after the block were not kept before it"
ls "$H"/.server-backup/*/.bashrc >/dev/null 2>&1 || fail "\$HOME/.bashrc was not backed up before the block was rewritten"
# Only a complete block is replaced: a lone begin marker and what follows stay.
printf '%s\nexport AFTER_LONE=1\n' "$(printf '%s' '# >>> server ')(added by ~/server/setup.sh; delete this block to opt out) >>>" >> "$H/.bashrc"
setup_in "$H" >/dev/null
grep -qx 'export AFTER_LONE=1' "$H/.bashrc" || fail "lines after a lone begin marker were dropped"

# A machine set up by the old bundle, which replaced both files: your own
# come back, and a line added to the old copy survives in a backup.
H="$WORK/home-old"; mkdir -p "$H/.server-backup/20200101-000000"
printf '# shell/bashrc — bash configuration, identical on every server.\nexec zsh\nexport APPENDED=1\n' > "$H/.bashrc"
printf '# shell/bash_profile — login bash.\n. ~/.bashrc\n' > "$H/.bash_profile"
printf 'export ORIGINAL=1\n' > "$H/.server-backup/20200101-000000/.bashrc"
printf '# mine\n[ -f ~/.bashrc ] && . ~/.bashrc\n' > "$H/.server-backup/20200101-000000/.bash_profile"
setup_in "$H" >/dev/null || fail "setup.sh exited non-zero (old bundle copies)"
[ "$(own_lines "$H/.bashrc")" = 'export ORIGINAL=1' ] && [ "$(blocks "$H/.bashrc")" = 1 ] ||
    fail "the original ~/.bashrc was not restored between the blocks"
grep -rqx 'export APPENDED=1' "$H/.server-backup" || fail "a line added to the old copy was lost (its backup was overwritten)"
cmp -s "$H/.bash_profile" "$H/.server-backup/20200101-000000/.bash_profile" || fail "the original ~/.bash_profile was not restored as it was"

# A bare home: both files are made, the login file reading ~/.bashrc.
H="$WORK/home-bare"; mkdir -p "$H"
setup_in "$H" >/dev/null || fail "setup.sh exited non-zero (bare home)"
grep -q '/etc/bashrc' "$H/.bashrc" && [ "$(blocks "$H/.bashrc")" = 1 ] || fail "a new ~/.bashrc lacks /etc/bashrc or the block"
[ "$(blocks "$H/.bash_profile")" = 1 ] || fail "no ~/.bash_profile reading ~/.bashrc was made"
got="$(HOME=$H bash -lc 'echo "${SCRATCH:-}"' </dev/null 2>&1 | tail -n 1)" || got="<exit $?>"
[ "$got" = "$H" ] || fail "a login bash in a bare home did not get the environment: got '$got'"
passed "your lines kept between two blocks, ssh-style shells get the environment, upgrades lose nothing, bare home works"


section "zsh and tmux keep your own files"
# Your ~/.zshrc with plain lines: kept, the block last, the environment added.
H="$WORK/home-zsh"; mkdir -p "$H"
printf 'export ZMINE=1\n' > "$H/.zshrc"
printf '# my prompt\n' > "$H/.p10k.zsh"
setup_in "$H" >/dev/null || fail "setup.sh exited non-zero (existing ~/.zshrc)"
[ "$(head -n 1 "$H/.zshrc")" = 'export ZMINE=1' ] && [ "$(blocks "$H/.zshrc")" = 1 ] &&
    [ "$(tail -n 1 "$H/.zshrc")" = '# <<< server <<<' ] || fail "your ~/.zshrc lines were not kept under one last block"
[ "$(cat "$H/.p10k.zsh")" = '# my prompt' ] || fail "your ~/.p10k.zsh was replaced"
got="$(HOME=$H zsh -ic 'print -r -- "$ZMINE|$SCRATCH|$HISTSIZE"' </dev/null 2>/dev/null | tail -n 1)" || got="<exit $?>"
[ "$got" = "1|$H|50000" ] || fail "an interactive zsh did not keep your lines and gain the bundle's: got '$got'"
# Your own oh-my-zsh setup above the block: prompt, plugins and history stay yours.
printf 'omz() { :; }\nHISTSIZE=123\n' > "$H/.zshrc"
setup_in "$H" >/dev/null
err="$(HOME=$H zsh -ic 'print -r -- "HIST=$HISTSIZE SCRATCH=$SCRATCH"' </dev/null 2>&1)" || true
printf '%s\n' "$err" | grep -q "HIST=123 SCRATCH=$H" || fail "with your own setup, the bundle changed history or missed the environment: $(printf '%s' "$err" | tail -n 1)"
printf '%s\n' "$err" | grep -q 'oh-my-zsh is not installed' && fail "with your own setup, the bundle still tried to load oh-my-zsh"
# Starship (or prezto, zinit, antidote, zim, pure) counts as a setup too.
printf 'starship_precmd() { :; }\nHISTSIZE=77\n' > "$H/.zshrc"
setup_in "$H" >/dev/null
got="$(HOME=$H zsh -ic 'print -r -- "HIST=$HISTSIZE"' </dev/null 2>/dev/null | tail -n 1)" || got=""
[ "$got" = "HIST=77" ] || fail "with a starship setup of your own, the bundle still loaded its prompt and history: got '$got'"
# A ~/.zshrc the old bundle copied in: set aside, the block alone remains.
printf '# shell/zshrc — interactive zsh, identical on every server.\nexport OLD=1\n' > "$H/.zshrc"
setup_in "$H" >/dev/null
[ "$(head -n 1 "$H/.zshrc")" = "$(printf '%s' '# >>> server ')"'(added by ~/server/setup.sh; delete this block to opt out) >>>' ] ||
    fail "the old bundle copy of ~/.zshrc was not replaced by the block alone"

# gpakosz/.tmux: your ~/.tmux.conf.local kept, the bundle's settings last and winning.
H="$WORK/home-tmuxcfg"; mkdir -p "$H"
printf 'set -g mouse off\n' > "$H/.tmux.conf.local"
setup_in "$H" >/dev/null || fail "setup.sh exited non-zero (existing ~/.tmux.conf.local)"
grep -q gpakosz "$H/.tmux.conf" 2>/dev/null || fail "gpakosz/.tmux was not installed as ~/.tmux.conf"
[ "$(head -n 1 "$H/.tmux.conf.local")" = 'set -g mouse off' ] && [ "$(blocks "$H/.tmux.conf.local")" = 1 ] ||
    fail "your ~/.tmux.conf.local lines were not kept under one block"
cp "$H/.tmux.conf.local" "$WORK/tmuxcfg-local"
# A ~/.tmux.conf of your own (not gpakosz/.tmux): both files left alone.
H="$WORK/home-owntmux"; mkdir -p "$H"
printf 'set -g prefix C-a\n' > "$H/.tmux.conf"
setup_in "$H" >/dev/null
[ "$(cat "$H/.tmux.conf")" = 'set -g prefix C-a' ] && [ ! -e "$H/.tmux.conf.local" ] ||
    fail "your own (non-gpakosz) ~/.tmux.conf was touched"
passed "your ~/.zshrc and its setup kept, old copies set aside, your ~/.p10k.zsh and tmux files kept"


section "Core and optional tools"
dry() { HOME=$SANDBOX_HOME SRV_HOST=generic "$SRV/setup.sh" --dry-run --here --no-conda --no-gdrive --no-github --no-secrets "$@" 2>&1; }
out="$(dry)" || true
printf '%s\n' "$out" | grep -q '^== cli$' || fail "a core tool (cli) did not run by default"
printf '%s\n' "$out" | grep -qE '^== (claude|codex|uv|rclone)$' && fail "an optional tool ran without being asked for"
printf '%s\n' "$out" | grep -q 'not installed: rclone uv claude codex' || fail "the skipped optional tools were not named"
out="$(dry --with=uv,claude)" || true
printf '%s\n' "$out" | grep -q '^== uv$' && printf '%s\n' "$out" | grep -q '^== claude$' &&
    printf '%s\n' "$out" | grep -q 'not installed: rclone codex' || fail "--with=uv,claude did not run exactly those two"
# server.json lists arrive space-separated: setup.tools and setup.with both work.
printf '{"setup": {"tools": ["zsh", "nvim"]}}\n' > "$SRV/server.json"
out="$(dry)" || true
printf '%s\n' "$out" | grep -q '^== nvim$' && ! printf '%s\n' "$out" | grep -q '^== cli$' ||
    fail "setup.tools from server.json did not run exactly its list"
printf '{"setup": {"with": ["codex"]}}\n' > "$SRV/server.json"
out="$(dry)" || true
printf '%s\n' "$out" | grep -q '^== codex$' || fail "setup.with from server.json did not add its tool"
rm -f "$SRV/server.json" "$SRV/.srv-config.sh"
out="$(SRV_CFG_setup_with=codex dry)" || true
printf '%s\n' "$out" | grep -q '^== codex$' && fail "a setup.with value inherited from the shell was used without a server.json"
out="$(HOME=$SANDBOX_HOME SRV_HOST=generic "$SRV/setup.sh" --dry-run --here --tools=nvim --github --no-secrets 2>&1)" || true
printf '%s\n' "$out" | sed -n '/^== GitHub$/,/^== /p' | grep -q 'skipped (--tools)' && fail "--tools=nvim --github skipped GitHub"
printf '%s\n' "$out" | sed -n '/^== conda$/,/^== /p' | grep -q 'skipped (--tools)' || fail "--tools=nvim still asked about conda"
passed "core by default, optional ones by --with or setup.with, setup.tools lists honoured, --tools keeps an explicit --github, no stale settings"

section "git, conda and command names"
# ~/.gitconfig keeps its lines; the bundle's settings come first, by include,
# and yours below them win.
H="$WORK/home-git"; mkdir -p "$H"
printf '[alias]\n\tst = status\n[user]\n\tname = Mine\n' > "$H/.gitconfig"
setup_in "$H" >/dev/null || fail "setup.sh exited non-zero (existing ~/.gitconfig)"
[ "$(head -n 1 "$H/.gitconfig")" = "$(printf '%s' '# >>> server ')(added by ~/server/setup.sh; delete this block to opt out) >>>" ] ||
    fail "the bundle's git include is not at the top of ~/.gitconfig"
got="$(HOME=$H GIT_CONFIG_NOSYSTEM=1 git config --includes --global alias.st)|$(HOME=$H GIT_CONFIG_NOSYSTEM=1 git config --includes --global alias.lg)|$(HOME=$H GIT_CONFIG_NOSYSTEM=1 git config --includes --global user.name)" || true
[ "$got" = "status|log --oneline --graph --decorate -20|Mine" ] || fail "git: yours should win and the bundle's fill in: got '$got'"
HOME=$H GIT_CONFIG_NOSYSTEM=1 git config --includes --global --get credential.helper >/dev/null && fail "the bundle sets a credential helper"
# A ~/.condarc of your own stays.
printf 'channels: [mine]\n' > "$H/.condarc"
HOME=$H SRV_DIR=$SRV SCRATCH=$H bash "$SRV/tools/conda.sh" condarc >/dev/null 2>&1 || true
[ "$(cat "$H/.condarc")" = 'channels: [mine]' ] || fail "tools/conda.sh replaced your own ~/.condarc"
# No alias or function takes a system command's name.
got="$(zsh -fc 'source "$1/shell/aliases.zsh"; for c in cc ld sg; do whence -w $c; done' _ "$SRV" 2>/dev/null | grep -E ': (alias|function)$')" || true
[ -z "$got" ] || fail "commands shadowed by the bundle: $got"
passed "your .gitconfig kept under the bundle's include, no credential helper, your .condarc kept, no shadowed commands"


section "tmux"
# The vendored config plus ours, in a private tmux server under a scratch $HOME.
if [ -n "$TMUX_BIN" ]; then
    H="$WORK/home-tmux"; mkdir -p "$H"
    # Without its @plugin lines: with them, the vendored config clones TPM
    # and every plugin from GitHub in the background as soon as tmux starts.
    cp "$SRV/config/tmux/tmux.conf" "$H/.tmux.conf"
    # The ~/.tmux.conf.local setup.sh wrote above: a "mouse off" of yours,
    # then the bundle's block, which must win.
    grep -v '@plugin' "$WORK/tmuxcfg-local" > "$H/.tmux.conf.local"
    T="srvcheck$$"
    # The pane prints a known line and waits, so what is on screen does not
    # depend on how fast a shell starts.
    if HOME=$H TMUX='' "$TMUX_BIN" -L "$T" -f "$H/.tmux.conf" new-session -d -s t -x 100 -y 20 \
            "printf 'copy-check-ok\\n'; sleep 60" 2>/dev/null; then
        sleep 2   # the vendored config applies part of itself in the background
        tm() { HOME=$H TMUX='' "$TMUX_BIN" -L "$T" "$@"; }
        [ "$(tm show -gv mouse)" = on ] || fail "mouse is not on (wheel scrolling, drag to copy)"
        [ "$(tm show -sv set-clipboard)" = on ] || fail "set-clipboard is not on (copy over ssh)"
        tm show -s terminal-overrides | grep -q 'Ms=' || fail "no Ms override: OSC 52 copy needs it on many terminals"
        tm list-keys -T root | grep -q 'WheelUpPane.*copy-mode' || fail "the wheel does not enter copy mode"
        tm list-keys -T copy-mode-vi | grep -q 'MouseDragEnd1Pane.*copy-' || fail "a mouse drag does not copy"
        # A real copy through copy mode — the first line, start to end —
        # read back from tmux's buffer.
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            tm capture-pane -p -t t | grep -q copy-check-ok && break
            sleep 0.5
        done
        tm copy-mode -t t
        tm send-keys -t t -X top-line
        tm send-keys -t t -X start-of-line
        tm send-keys -t t -X begin-selection
        tm send-keys -t t -X end-of-line
        tm send-keys -t t -X copy-selection-and-cancel
        sleep 0.3
        got="$(tm show-buffer 2>&1 | head -n 1)" || got=""
        case "$got" in
            copy-check-ok*) ;;
            *) fail "copy mode did not copy: buffer '$got'; pane: $(tm capture-pane -p -t t | head -n 2 | tr '\n' '|')" ;;
        esac
        tm kill-server 2>/dev/null || true
    else
        fail "tmux did not start with the bundle's config"
    fi
    passed "mouse on, wheel scrolls, drag copies, OSC 52 clipboard, a real copy round-trips"
else
    printf '  skip tmux is not installed\n'
fi

echo
if (( FAILED )); then
    echo "FAILED"; exit 1
fi
echo "all checks passed"
