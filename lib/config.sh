# lib/config.sh — server.json, your own settings in one file.
#
# Sourced by setup.sh and the tools after lib/common.sh. server.json beside
# setup.sh (see server.example.json) holds what is yours rather than the
# machine's — git identity, the GitHub protocol, the models the agent aliases
# run, the answers to setup.sh's questions — so a fresh machine is configured
# in one run with nothing typed. It is git-ignored: it reaches a new machine
# inside the zip make-bundle.sh builds, or by scp, never through the
# repository. It carries no token: tokens go in ~/.secrets.env and the
# encrypted blob, and a token-shaped value here makes the render refuse.
#
# The file is read once per setup.sh run, by python3 (jq is not a given on a
# cluster, python3 is), and rendered to $SRV_DIR/.srv-config.sh: plain
# `export SRV_CFG_<section>_<key>=value` lines that shell/env.sh sources at
# every shell start without paying for a JSON parse. Lists become
# space-separated strings; nested objects (claude.settings) are kept as JSON
# in one variable for the tool that merges them.
#
#   cfg git.name [default]   -> the value, or the default, or nothing

SRV_CONFIG="${SRV_CONFIG:-$SRV_DIR/server.json}"
SRV_CONFIG_RENDERED="$SRV_DIR/.srv-config.sh"

# srv_config_render : server.json -> .srv-config.sh (or remove a stale one)
srv_config_render() {
    # Forget values from an earlier render, or inherited from the calling
    # shell, before anything else: every return below must leave only what
    # this server.json says, and no server.json means no values.
    local stale
    for stale in $(compgen -v SRV_CFG_ || true); do unset "$stale"; done
    if [ ! -r "$SRV_CONFIG" ]; then
        rm -f "$SRV_CONFIG_RENDERED"
        return 1
    fi
    if ! have python3; then
        rm -f "$SRV_CONFIG_RENDERED"
        warn "python3 is needed to read $(basename "$SRV_CONFIG") — skipping it"
        return 1
    fi
    if ! python3 - "$SRV_CONFIG" > "$SRV_CONFIG_RENDERED.tmp" <<'PY'
import json, re, shlex, sys
path = sys.argv[1]
try:
    cfg = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError) as error:
    sys.exit(f"{path}: {error}")
if not isinstance(cfg, dict):
    sys.exit(f"{path}: the top level must be an object")
secretish = re.compile(r"token|secret|password|passphrase|api_key|apikey", re.I)
lines = ["# rendered from server.json by lib/config.sh; do not edit"]
for section, body in cfg.items():
    if section.startswith("_"):
        continue
    if not isinstance(body, dict):
        sys.exit(f"{path}: {section} must be an object")
    for key, value in body.items():
        name = f"SRV_CFG_{section}_{key}"
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            sys.exit(f"{path}: {section}.{key} is not a usable name")
        # A string under a credential-shaped key, or a token-shaped value under
        # any key, is refused; a boolean such as setup.secrets is an answer.
        if (isinstance(value, str) and secretish.search(key)) or (
                isinstance(value, str) and re.search(r"\b(gh[pousr]_|github_pat_|sk-|hf_)[A-Za-z0-9_]{16,}", value)):
            sys.exit(f"{path}: {section}.{key} looks like a credential; those belong in ~/.secrets.env")
        if isinstance(value, bool):
            rendered = "yes" if value else "no"
        elif isinstance(value, (int, float)):
            rendered = str(value)
        elif isinstance(value, str):
            rendered = value
        elif isinstance(value, list):
            rendered = " ".join(str(item) for item in value)
        elif isinstance(value, dict):
            rendered = json.dumps(value, separators=(",", ":"))
        elif value is None:
            continue
        else:
            sys.exit(f"{path}: {section}.{key} has an unsupported value")
        lines.append(f"export {name}={shlex.quote(rendered)}")
print("\n".join(lines))
PY
    then
        rm -f "$SRV_CONFIG_RENDERED.tmp" "$SRV_CONFIG_RENDERED"
        warn "$(basename "$SRV_CONFIG") was not applied (see above)"
        return 1
    fi
    mv "$SRV_CONFIG_RENDERED.tmp" "$SRV_CONFIG_RENDERED"
    # shellcheck source=/dev/null
    . "$SRV_CONFIG_RENDERED"
    return 0
}

# cfg <section.key> [default] : a value from the rendered config
cfg() {
    local name="SRV_CFG_${1%%.*}_${1#*.}" value
    eval "value=\${$name:-}"
    if [ -n "$value" ]; then
        printf '%s\n' "$value"
    elif [ $# -gt 1 ]; then
        printf '%s\n' "$2"
    fi
}

# The rendered file is already there on a machine that ran setup.sh; load it
# so a tool run on its own (tools/github.sh) sees the same values.
if [ -r "$SRV_CONFIG_RENDERED" ]; then
    # shellcheck source=/dev/null
    . "$SRV_CONFIG_RENDERED"
fi
