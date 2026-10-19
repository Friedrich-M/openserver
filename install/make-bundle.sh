#!/usr/bin/env bash
# make-bundle.sh — build server.zip, the copy-to-a-new-machine artefact.
#
#   install/make-bundle.sh [output.zip] [--no-secrets | --with-secrets]
#
# The zip contains this whole directory except the git history and anything
# secret. Unzipping it in $HOME on a new machine and running ./server/setup.sh
# configures that machine completely.
#
# Build it on a machine whose bundle is still complete: setup.sh prunes the
# profiles a machine does not use, so a bundle rebuilt on a pruned copy will
# not carry the other clusters. `git -C ~/server log` shows whether a prune
# has happened here.

set -euo pipefail

SRV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WITH_SECRETS=1
FORCE_SECRETS=0
args=()
for arg in "$@"; do
    case "$arg" in
        --no-secrets)   WITH_SECRETS=0 ;;
        --with-secrets) FORCE_SECRETS=1 ;;
        *)            args+=("$arg") ;;
    esac
done
set -- "${args[@]+"${args[@]}"}"

OUT_ARG="${1:-$HOME/server.zip}"
OUT="$(cd "$(dirname "$OUT_ARG")" && pwd)/$(basename "$OUT_ARG")"

# ---------------------------------------------------------------------------
# Refuse to ship a credential
# ---------------------------------------------------------------------------
# Nothing matching these should ever be in here — .gitignore blocks them — so
# finding one means something went wrong, and the right response is to stop
# rather than to copy a token onto another machine.
# secrets/secrets.enc is deliberately excluded from this list: it is the
# one credential file meant to travel, and it travels encrypted. Its plaintext
# counterpart is not.
LEAKS=$(cd "$SRV_DIR" && find . -path ./.git -prune -o \( \
    -name '.secrets*' -o -name 'secrets.env' -o -name 'secrets.zsh' -o -name 'rclone.conf' \
    -o -name '.git-credentials' -o -name 'auth.json' -o -name '.claude.json' \
    -o -name 'id_*' -o -name '*.pem' -o -name '*.key' -o -name '.netrc' -o -name '.env' -o -name '.env.*' \
    -o -path './secrets/*.txt' \) -print 2>/dev/null)
if [[ -n "$LEAKS" ]]; then
    echo "refusing to build — secret-looking files in the bundle:" >&2
    echo "$LEAKS" >&2
    exit 1
fi
# server.json ships (it is the point of it) but must hold no credential; the
# check lib/config.sh applies at render time runs here too.
if [[ -r "$SRV_DIR/server.json" ]] && command -v python3 >/dev/null 2>&1; then
    SRV_DIR="$SRV_DIR" bash -c '. "$SRV_DIR/lib/common.sh"; . "$SRV_DIR/lib/config.sh"; srv_config_render' >/dev/null || {
        echo "refusing to build — server.json was rejected (see above)" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# Warn if this copy has been pruned
# ---------------------------------------------------------------------------
# setup.sh records a prune in .srv-state, and the git history it keeps names
# exactly which files went. Neither is a list of machines kept here.
if [[ -f "$SRV_DIR/.srv-state" ]] && grep -q '^pruned=yes' "$SRV_DIR/.srv-state"; then
    echo "warning: this copy was pruned by setup.sh — the bundle will only know" >&2
    echo "         the machines whose profiles are still here." >&2
    if command -v git >/dev/null 2>&1 && [[ -d "$SRV_DIR/.git" ]]; then
        gone="$(git -C "$SRV_DIR" log --diff-filter=D --name-only --format= -- hosts 2>/dev/null | sort -u)"
        [[ -n "$gone" ]] && printf '         dropped here:\n%s\n' "$(printf '%s\n' "$gone" | sed 's/^/           /')" >&2
    fi
fi

# ---------------------------------------------------------------------------
# Say plainly what is about to be shipped
# ---------------------------------------------------------------------------
# A blob locked with a passphrase its own check called weak does not go into
# a zip that is going on the web. That decision was already made and recorded
# at lock time; this just honours it, rather than asking again at the one
# moment it is easiest to click through.
if (( WITH_SECRETS )) && [[ -r "$SRV_DIR/secrets/secrets.enc" ]] &&
   grep -q '^# strength: weak' "$SRV_DIR/secrets/secrets.enc" && (( ! FORCE_SECRETS )); then
    WITH_SECRETS=0
    cat >&2 <<'WEAK'
note: secrets/secrets.enc is locked with a passphrase marked weak, so it is
  being left OUT of this bundle. That is the right call if the zip goes on a
  public URL — a weak passphrase there is worth about an hour of rented GPUs.

  Copy it to a new machine by hand instead:
    scp ~/server/secrets/secrets.enc <host>:~/server/secrets/

  Include it anyway with:  install/make-bundle.sh --with-secrets

WEAK
fi

if (( WITH_SECRETS )) && [[ -r "$SRV_DIR/secrets/secrets.enc" ]]; then
    cat >&2 <<'WARN'
note: this bundle contains secrets/secrets.enc — your credentials.

  They are encrypted, but the ciphertext is only as strong as the passphrase:
  anyone who can fetch the zip can attack it offline, forever, on any hardware
  they like. Publishing it at a public URL is fine with a generated or 5-word
  passphrase, and not fine with a memorable one.

  Leave it out of a published bundle with:  install/make-bundle.sh --no-secrets

WARN
fi

rm -f "$OUT"
# .srv-state records that setup already ran *on this machine*. It is
# gitignored, but this builds the zip from the directory rather than from the
# git index, so it has to be named here too — shipping it would make a
# genuinely fresh machine skip its first prune.
EXCLUDES=('*/.git/*' '*/.git' '*.zip' '*/.DS_Store' '*/.srv-state' '*/.server-backup/*')
# secrets/ is an allowlist, not a blocklist: zip walks the working tree, not
# the git index, so a gitignored scratch file there (a passphrase note, say)
# would otherwise ride along. Only README.md and — when wanted — the encrypted
# blob itself and the env template are shipped; every other name found under
# secrets/ is excluded.
for f in "$SRV_DIR"/secrets/* "$SRV_DIR"/secrets/.[!.]* "$SRV_DIR"/secrets/..?*; do
    [[ -e "$f" ]] || continue
    case "$(basename "$f")" in
        README.md|secrets.env.example|secrets.sh) ;;
        secrets.enc) (( WITH_SECRETS )) || EXCLUDES+=('*/secrets/secrets.enc') ;;
        *)           EXCLUDES+=("*/secrets/$(basename "$f")" "*/secrets/$(basename "$f")/*")
                     echo "note: leaving secrets/$(basename "$f") out of the bundle" >&2 ;;
    esac
done

# The zip's top folder is server/ whatever this checkout is called (an
# openserver clone, say): install.sh and the README run server/setup.sh, and
# setup.sh installs the bundle at ~/server.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/srvbundle.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ln -s "$SRV_DIR" "$STAGE/server"
(cd "$STAGE" && zip -qr "$OUT" server -x "${EXCLUDES[@]}")

# The web bootstrap goes next to the zip, so the whole install is one command
# rather than three. $SRV_SITE_URL bakes in the real address; without it the
# placeholder stays and the script still works via $SERVER_ZIP_URL.
INSTALLER="$(dirname "$OUT")/install.sh"
URL_BASE="${SRV_SITE_URL:-https://example.com}"
URL_BASE="${URL_BASE%/}"
sed "s|__URL_BASE__|$URL_BASE|g" "$SRV_DIR/install/install.sh.template" > "$INSTALLER"
chmod +x "$INSTALLER"

# BSD du has no --apparent-size; try it, then fall back.
# BSD du also right-justifies the size with leading spaces, so cut on the
# tab and strip blanks rather than splitting on whitespace.
SIZE="$( (du -h --apparent-size "$OUT" 2>/dev/null || du -h "$OUT") | cut -f1 | tr -d ' ')"
printf 'built %s (%s)\n' "$OUT" "$SIZE"
printf 'built %s\n' "$INSTALLER"

if [[ "$URL_BASE" == "https://example.com" ]]; then
    cat <<'NEXT'

Set your site once so the installer carries the real address:

  export SRV_SITE_URL=https://your-site/path      # add it to ~/.zshrc.local
  install/make-bundle.sh

NEXT
fi

cat <<NEXT
Upload BOTH files to $URL_BASE/, then on a new machine:

  curl -fsSL $URL_BASE/install.sh | bash

Or without the website:

  scp $(basename "$OUT") <host>:~/
  ssh <host> -t 'unzip -q server.zip && ./server/setup.sh'
NEXT
