#!/usr/bin/env bash
# Claude Code Smart Bootstrap V4.9.0 PUBLIC
# Goal: one-command, idempotent, self-healing setup for Claude CLI + Claude Desktop Code local sessions across selected Linux users.
# Smart/offline-first repair: healthy components are skipped with no package/network work; --update explicitly refreshes packages/remotes.
# Configures: Auto Memory, earlier auto-compaction, deferred MCP tool loading, persistent context policy, cache-stable mobile pixel-clone subagents, content-addressed visual dedup, compact issue/decision recall, bounded Opus escalation, and usage-limit guardrails based on Anthropic best practices.
# Automatically wires Graft per Git repo and keeps Graphify outputs out of Claude prompt-cache inputs.
# Safe to re-run. Default = SMART-REPAIR (offline-first); use --update for intentional refreshes or --verify-only for read-only validation.

set -Eeuo pipefail

BOOTSTRAP_VERSION="4.9.0-public"
USERS=()
USER_SPEC="${CLAUDE_BOOTSTRAP_USERS:-}"
AUTO_COMPACT_WINDOW="350000"
MIN_NODE_VERSION="22.12.0"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/var/log/claude-global-bootstrap-${STAMP}.log"
VERIFY_ONLY=0
UPDATE=0
SHOW_TARGETS=0

usage() {
  cat <<'EOF'
Claude Code Smart Bootstrap

Usage:
  sudo ./claude-smart-bootstrap.sh [options]

Target users:
  --users USER1,USER2,...   Configure exactly these existing Linux users.
                            Example: --users root,alice,bob
  --show-targets            Print resolved target users and exit.

Modes:
  --verify-only             Read-only deep health verification.
  --update                  Intentionally refresh packages/plugins/vendor sources.
  --version                 Print version and exit.
  -h, --help                Show this help.

Environment:
  CLAUDE_BOOTSTRAP_USERS     Comma-separated user list. --users takes precedence.

Default target selection:
  If --users is omitted, target root plus SUDO_USER when available.

Examples:
  sudo ./claude-smart-bootstrap.sh --users root,alice
  sudo ./claude-smart-bootstrap.sh --users root,alice,bob --verify-only
  sudo env CLAUDE_BOOTSTRAP_USERS="root,alice" ./claude-smart-bootstrap.sh
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-only) VERIFY_ONLY=1 ;;
    --update) UPDATE=1 ;;
    --users)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --users requires a comma-separated value" >&2; exit 2; }
      USER_SPEC="$1"
      ;;
    --users=*) USER_SPEC="${1#*=}" ;;
    --show-targets) SHOW_TARGETS=1 ;;
    --version) echo "claude-smart-bootstrap v${BOOTSTRAP_VERSION}"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$VERIFY_ONLY" -eq 1 && "$UPDATE" -eq 1 ]]; then
  echo "ERROR: --verify-only and --update are mutually exclusive" >&2
  exit 2
fi

resolve_target_users() {
  local spec="$USER_SPEC" raw u trimmed
  local -A seen=()

  if [[ -z "${spec//[[:space:]]/}" ]]; then
    spec="root"
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
      spec+=",${SUDO_USER}"
    fi
  fi

  IFS=',' read -r -a raw <<<"$spec"
  for u in "${raw[@]}"; do
    trimmed="${u#"${u%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -n "$trimmed" ]] || continue

    if [[ ! "$trimmed" =~ ^[A-Za-z_][A-Za-z0-9_.-]*\$?$ ]]; then
      echo "ERROR: invalid Linux username in --users: '$trimmed'" >&2
      exit 2
    fi
    if ! getent passwd "$trimmed" >/dev/null 2>&1; then
      echo "ERROR: target user does not exist: '$trimmed'" >&2
      exit 2
    fi
    if [[ -z "${seen[$trimmed]+x}" ]]; then
      USERS+=("$trimmed")
      seen["$trimmed"]=1
    fi
  done

  [[ "${#USERS[@]}" -gt 0 ]] || { echo "ERROR: no target users resolved" >&2; exit 2; }
}

resolve_target_users
USERS_CSV="$(IFS=,; echo "${USERS[*]}")"
if [[ "$SHOW_TARGETS" -eq 1 ]]; then
  printf 'TARGET_USERS=%s\n' "$USERS_CSV"
  exit 0
fi

exec > >(tee -a "$LOG_FILE") 2>&1
printf '\n============================================================\n'
printf ' CLAUDE GLOBAL BOOTSTRAP V%s\n' "$BOOTSTRAP_VERSION"
printf '============================================================\n'
printf 'Script: %s\n' "$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
if [[ "$VERIFY_ONLY" -eq 1 ]]; then
  RUN_MODE="VERIFY-ONLY"
elif [[ "$UPDATE" -eq 1 ]]; then
  RUN_MODE="UPDATE+REPAIR"
else
  RUN_MODE="SMART-REPAIR (offline-first; healthy components are skipped)"
fi
printf 'Mode:   %s\n' "$RUN_MODE"
printf 'Users:  %s\n' "$USERS_CSV"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32mOK: %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
err()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; }
skip() { printf '\033[1;36mSKIP: %s\033[0m\n' "$*"; }

step_run() {
  local user="$1" n="$2" total="$3" label="$4"; shift 4
  local started elapsed rc
  # Bash SECONDS is monotonic for our purpose; wall-clock/NTP changes cannot
  # produce bogus negative stage durations.
  started="$SECONDS"
  printf '\n\033[1;35m▶ [%s %02d/%02d] %s\033[0m\n' "$user" "$n" "$total" "$label"

  # IMPORTANT: callers invoke step_run as a plain command (not via "||" / "if").
  # That keeps errexit active inside nested stage functions. step_run records a
  # failure in the global FAIL flag and itself returns 0 so later diagnostics run.
  set +e
  ( set -Eeuo pipefail; "$@" )
  rc=$?
  set -e

  elapsed=$((SECONDS-started))
  if [[ "$rc" -eq 0 ]]; then
    printf '\033[1;32m✓ [%s %02d/%02d] DONE: %s (%ss)\033[0m\n' "$user" "$n" "$total" "$label" "$elapsed"
    return 0
  fi

  FAIL=1
  printf '\033[1;31m✗ [%s %02d/%02d] FAILED: %s (%ss, rc=%s)\033[0m\n' "$user" "$n" "$total" "$label" "$elapsed" "$rc" >&2
  return 0
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  err "Run as root, e.g. sudo $0 --users root,alice"
  exit 1
fi

for c in getent python3 curl git runuser flock sha256sum timeout; do
  command -v "$c" >/dev/null 2>&1 || { err "Missing required command: $c"; exit 1; }
done

self_check_embedded_python() {
  python3 - "$0" <<'PYSELF'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1])
lines=p.read_text(errors="strict").splitlines()
checked=0
errors=[]
for i,line in enumerate(lines):
    m=re.search(r"<<'([A-Za-z0-9_]+)'", line)
    if not m or "python3" not in line:
        continue
    tag=m.group(1)
    buf=[]
    j=i+1
    while j < len(lines) and lines[j] != tag:
        buf.append(lines[j]); j+=1
    if j >= len(lines):
        errors.append(f"line {i+1}: missing heredoc terminator {tag}")
        continue
    checked += 1
    try:
        compile("\n".join(buf)+"\n", f"{p.name}:{i+1}:{tag}", "exec")
    except SyntaxError as e:
        errors.append(f"line {i+1} ({tag}): {e.msg} at embedded line {e.lineno}")
if errors:
    print("Embedded Python self-check FAILED:", file=sys.stderr)
    for e in errors:
        print("  - "+e, file=sys.stderr)
    raise SystemExit(1)
print(f"OK: embedded Python self-check ({checked} blocks)")
PYSELF
}

self_check_embedded_python || { err "Bootstrap self-check failed; refusing partial repair."; exit 1; }

version_ge() {
  python3 - "$1" "$2" <<'PY'
import re, sys

def p(v):
    nums=[int(x) for x in re.findall(r'\d+', v)[:3]]
    return tuple((nums+[0,0,0])[:3])
raise SystemExit(0 if p(sys.argv[1]) >= p(sys.argv[2]) else 1)
PY
}

home_of() { getent passwd "$1" | cut -d: -f6; }
group_of() { id -gn "$1"; }

# Important: use bash -c, NOT bash -lc. A login shell can replace PATH and hide ~/.local/bin.
run_u() {
  local user="$1" home="$2"; shift 2
  local path="$home/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
  if [[ "$user" == "root" ]]; then
    env HOME="$home" USER="$user" LOGNAME="$user" PATH="$path" bash -c "$*"
  else
    runuser -u "$user" -- env HOME="$home" USER="$user" LOGNAME="$user" PATH="$path" bash -c "$*"
  fi
}

backup_file() {
  local user="$1" file="$2"
  [[ -f "$file" ]] || return 0
  local b="${file}.backup-${STAMP}"
  cp -a "$file" "$b"
  chown "$user":"$(group_of "$user")" "$b" 2>/dev/null || true
}

append_path_block() {
  local user="$1" home="$2" file
  for file in "$home/.profile" "$home/.bashrc"; do
    if [[ -f "$file" ]] &&
       grep -Fq '# BEGIN CLAUDE-GLOBAL-PATH' "$file" &&
       grep -Fq 'export PATH="$HOME/.local/bin:$PATH"' "$file" &&
       grep -Fq '# END CLAUDE-GLOBAL-PATH' "$file"; then
      continue
    fi
    touch "$file"
    python3 - "$file" <<'PY' || return 1
import pathlib,re,sys
p=pathlib.Path(sys.argv[1])
s=p.read_text(errors='ignore') if p.exists() else ''
s=re.sub(r'\n?# BEGIN CLAUDE-GLOBAL-PATH\n.*?# END CLAUDE-GLOBAL-PATH\n?', '\n', s, flags=re.S)
block='\n\n# BEGIN CLAUDE-GLOBAL-PATH\nexport PATH="$HOME/.local/bin:$PATH"\n# END CLAUDE-GLOBAL-PATH\n'
p.write_text(s.rstrip()+block)
PY
    chown "$user":"$(group_of "$user")" "$file" 2>/dev/null || true
  done
}

ensure_node22() {
  log "System Node.js runtime"
  local current=""
  current="$(node --version 2>/dev/null | sed 's/^v//' || true)"
  if [[ -n "$current" ]] && version_ge "$current" "$MIN_NODE_VERSION"; then
    ok "Node v$current satisfies >= $MIN_NODE_VERSION"
    return 0
  fi

  [[ "$VERIFY_ONLY" -eq 0 ]] || { err "Node ${current:-MISSING} < $MIN_NODE_VERSION"; return 1; }

  if ! command -v apt-get >/dev/null 2>&1; then
    err "Automatic Node 22 bootstrap currently expects Debian/Ubuntu/WSL (apt-get)."
    return 1
  fi

  log "Installing Node.js 22 system-wide (required by current Graft dependencies)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg >/dev/null
  # Official NodeSource setup for Node 22; idempotent on rerun.
  curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource_setup_22.sh
  bash /tmp/nodesource_setup_22.sh >/dev/null
  apt-get install -y -qq nodejs >/dev/null
  rm -f /tmp/nodesource_setup_22.sh

  current="$(node --version 2>/dev/null | sed 's/^v//' || true)"
  if [[ -z "$current" ]] || ! version_ge "$current" "$MIN_NODE_VERSION"; then
    err "Node upgrade failed; got ${current:-MISSING}, need >= $MIN_NODE_VERSION"
    return 1
  fi
  ok "Node upgraded to v$current"
}


ensure_managed_model_defaults() {
  # Machine-wide startup defaults for BOTH CLI and Desktop Code local sessions.
  # Do not rewrite/backup a healthy file on every bootstrap run.
  local dir="/etc/claude-code/managed-settings.d"
  local f="$dir/90-vibecoding-defaults.json"

  if [[ -f "$f" ]] && python3 - "$f" <<'PY' >/dev/null 2>&1
import json, pathlib, sys
c=json.loads(pathlib.Path(sys.argv[1]).read_text())
raise SystemExit(0 if c.get("model")=="sonnet" and c.get("effortLevel")=="medium" else 1)
PY
  then
    skip "machine managed Sonnet/medium defaults already healthy"
    return 0
  fi

  [[ "$VERIFY_ONLY" -eq 0 ]] || { err "managed defaults missing/incorrect: $f"; return 1; }

  mkdir -p "$dir"
  if [[ -f "$f" ]]; then
    cp -a "$f" "${f}.backup-${STAMP}"
  fi
  cat > "$f" <<'JSON'
{
  "model": "sonnet",
  "effortLevel": "medium"
}
JSON
  chmod 0644 "$f"

  python3 - "$f" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1])
c=json.loads(p.read_text())
bad=[]
if c.get("model")!="sonnet": bad.append("model=sonnet")
if c.get("effortLevel")!="medium": bad.append("effortLevel=medium")
if bad: raise SystemExit("managed defaults invalid: "+", ".join(bad))
print(f"OK: machine managed startup defaults: model={c['model']} effort={c['effortLevel']}")
PY
}

install_claude_latest() {
  local user="$1" home="$2"
  log "[$user] Claude Code native"

  if run_u "$user" "$home" 'test -x "$HOME/.local/bin/claude" && "$HOME/.local/bin/claude" --version >/dev/null 2>&1'; then
    if [[ "$VERIFY_ONLY" -eq 1 ]]; then
      run_u "$user" "$home" '"$HOME/.local/bin/claude" --version'
      return 0
    fi
    if [[ "$UPDATE" -eq 0 ]]; then
      local cv
      cv="$(run_u "$user" "$home" '"$HOME/.local/bin/claude" --version 2>/dev/null | head -1' || true)"
      skip "[$user] Claude Code already healthy (${cv:-installed}); no installer/network call"
      return 0
    fi
    ok "[$user] --update requested; refreshing Claude Code intentionally"
  elif [[ "$VERIFY_ONLY" -eq 1 ]]; then
    err "[$user] Claude Code missing/broken"
    return 1
  else
    warn "[$user] Claude Code missing/broken; repair requires installer/network"
  fi

  local clog="/tmp/claude-install-${user}.log"
  rm -f "$clog"
  if ! run_u "$user" "$home" "set -o pipefail; curl --connect-timeout 20 --max-time 180 -fsSL https://claude.ai/install.sh | bash -s latest 2>&1 | tee '$clog'"; then
    warn "[$user] Claude installer failed; last output follows:"
    tail -80 "$clog" 2>/dev/null || true
    return 1
  fi
  rm -f "$clog"
  run_u "$user" "$home" 'test -x "$HOME/.local/bin/claude" && "$HOME/.local/bin/claude" --version' || return 1
}

install_graphify() {
  local user="$1" home="$2"
  log "[$user] Graphify"

  local cli_ok=0 skill_ok=0
  run_u "$user" "$home" 'graphify --version >/dev/null 2>&1' && cli_ok=1 || true
  [[ -f "$home/.claude/skills/graphify/SKILL.md" ]] && skill_ok=1 || true

  if [[ "$VERIFY_ONLY" -eq 1 ]]; then
    [[ "$cli_ok" -eq 1 && "$skill_ok" -eq 1 ]] || return 1
    run_u "$user" "$home" 'graphify --version'
    return 0
  fi

  if [[ "$cli_ok" -eq 1 && "$skill_ok" -eq 1 && "$UPDATE" -eq 0 ]]; then
    local gv
    gv="$(run_u "$user" "$home" 'graphify --version 2>/dev/null | head -1' || true)"
    skip "[$user] Graphify already healthy (${gv:-installed}); no uv/package/network action"
    return 0
  fi

  # uv is needed only when Graphify itself must be installed/upgraded.
  if [[ "$cli_ok" -eq 0 || "$UPDATE" -eq 1 ]]; then
    if ! run_u "$user" "$home" 'command -v uv >/dev/null 2>&1'; then
      warn "[$user] uv missing; installing only because Graphify needs repair/update"
      run_u "$user" "$home" 'set -o pipefail; curl -LsSf https://astral.sh/uv/install.sh | sh >/tmp/uv-install.log 2>&1' || {
        run_u "$user" "$home" 'tail -80 /tmp/uv-install.log 2>/dev/null || true'; return 1;
      }
    fi
    if [[ "$cli_ok" -eq 1 && "$UPDATE" -eq 1 ]]; then
      run_u "$user" "$home" 'uv tool upgrade graphifyy >/dev/null'
    elif [[ "$cli_ok" -eq 0 ]]; then
      run_u "$user" "$home" 'uv tool install graphifyy >/dev/null'
    fi
  fi

  # Local integration repair only when missing, or refresh after explicit update.
  if [[ "$skill_ok" -eq 0 || "$UPDATE" -eq 1 ]]; then
    if ! run_u "$user" "$home" 'graphify install >/tmp/graphify-install.log 2>&1'; then
      warn "[$user] graphify install failed; output follows:"
      run_u "$user" "$home" 'tail -100 /tmp/graphify-install.log 2>/dev/null || true'
      return 1
    fi
    run_u "$user" "$home" 'rm -f /tmp/graphify-install.log'
  fi

  run_u "$user" "$home" 'graphify --version && test -f "$HOME/.claude/skills/graphify/SKILL.md"' || return 1
  ok "[$user] Graphify healthy; no manual /graphify command is required"
}

install_graft() {
  local user="$1" home="$2"
  log "[$user] Graft"
  local min_graft="0.16.0"
  local gv=""

  gv="$(run_u "$user" "$home" 'graft --version 2>/dev/null | head -1' || true)"
  local healthy=0
  if [[ -n "$gv" ]] && version_ge "$gv" "$min_graft"; then healthy=1; fi

  if [[ "$VERIFY_ONLY" -eq 1 ]]; then
    [[ "$healthy" -eq 1 ]] || return 1
    printf '%s
' "$gv"
    return 0
  fi

  if [[ "$healthy" -eq 1 && "$UPDATE" -eq 0 ]]; then
    skip "[$user] Graft already healthy ($gv); no npm registry/install action"
    return 0
  fi

  if [[ "$healthy" -eq 0 ]]; then
    warn "[$user] Graft missing/broken/older than $min_graft; repairing"
  else
    ok "[$user] --update requested; refreshing Graft intentionally"
  fi

  if ! run_u "$user" "$home" 'mkdir -p "$HOME/.local"; NPM_CONFIG_ENGINE_STRICT=true npm install -g --prefix "$HOME/.local" --legacy-peer-deps --loglevel=warn @nanonets/graft@latest >/tmp/graft-install.log 2>&1'; then
    warn "[$user] Graft npm install failed; output follows:"
    run_u "$user" "$home" 'tail -160 /tmp/graft-install.log 2>/dev/null || true'
    return 1
  fi
  if run_u "$user" "$home" 'grep -Eq "EBADENGINE|ERESOLVE overriding peer dependency|Could not resolve dependency" /tmp/graft-install.log 2>/dev/null'; then
    warn "[$user] Graft install emitted an engine/peer-resolution warning; refusing to treat it as healthy."
    run_u "$user" "$home" 'cat /tmp/graft-install.log 2>/dev/null || true'
    return 1
  fi
  run_u "$user" "$home" 'rm -f /tmp/graft-install.log; node --version; graft --version'
}

sync_managed_repo() {
  local user="$1" home="$2" url="$3" dest="$4"
  if [[ -d "$dest/.git" ]]; then
    if [[ "$UPDATE" -eq 1 ]]; then
      run_u "$user" "$home" "git -C '$dest' fetch --depth=1 origin main >/dev/null 2>&1 && git -C '$dest' reset --hard origin/main >/dev/null"
    else
      skip "[$user] vendor $(basename "$dest") already present; no git fetch"
    fi
  else
    warn "[$user] vendor $(basename "$dest") missing; cloning once"
    run_u "$user" "$home" "rm -rf '$dest'; mkdir -p '$(dirname "$dest")'; git clone --depth 1 '$url' '$dest' >/dev/null 2>&1"
  fi
}

mobile_stack_healthy() {
  local user="$1" home="$2"
  test -f "$home/.claude/skills/mobile-pixel-clone/SKILL.md" || return 1
  test -f "$home/.claude/agents/mobile-ui-implementer.md" || return 1
  test -f "$home/.claude/agents/mobile-ui-qa-opus.md" || return 1
  test -x "$home/.local/bin/claude-android" || return 1
  test -x "$home/.local/bin/claude-mobile-visual" || return 1
  test -x "$home/.local/bin/claude-project-state" || return 1
  test -f "$home/.claude/skills/google-android-testing-setup/SKILL.md" || return 1
  test -f "$home/.claude/skills/google-android-edge-to-edge/SKILL.md" || return 1
  grep -Fq 'payload.get("reason")' "$home/.claude/tools/project_state.py" || return 1
  grep -Fq 'payload.get("why")' "$home/.claude/tools/project_state.py" || return 1
  run_u "$user" "$home" 'claude-mobile-visual --help >/dev/null 2>&1 && claude-project-state --help >/dev/null 2>&1' || return 1
  return 0
}

install_mobile_design_stack() {
  local user="$1" home="$2"
  log "[$user] Mobile pixel-clone design stack"

  if [[ "$VERIFY_ONLY" -eq 1 ]]; then
    test -f "$home/.claude/skills/mobile-pixel-clone/SKILL.md" || return 1
    test -f "$home/.claude/agents/mobile-ui-implementer.md" || return 1
    test -f "$home/.claude/agents/mobile-ui-qa-opus.md" || return 1
    test -x "$home/.local/bin/claude-android" || return 1
    test -x "$home/.local/bin/claude-mobile-visual" || return 1
    test -x "$home/.local/bin/claude-project-state" || return 1
    test -f "$home/.claude/skills/google-android-testing-setup/SKILL.md" || return 1
    test -f "$home/.claude/skills/google-android-edge-to-edge/SKILL.md" || return 1
    run_u "$user" "$home" 'claude-mobile-visual --help >/dev/null && claude-project-state --help >/dev/null' || return 1
    return 0
  fi

  if mobile_stack_healthy "$user" "$home" && [[ "$UPDATE" -eq 0 ]]; then
    skip "[$user] mobile design stack already healthy; no git fetch, pip install, or file rewrite"
    return 0
  fi

  local vendor="$home/.claude/vendor"
  mkdir -p "$vendor" "$home/.claude/skills/mobile-pixel-clone/scripts" "$home/.claude/agents" "$home/.claude/tools" "$home/.local/bin"
  chown -R "$user":"$(group_of "$user")" "$vendor" "$home/.claude/skills/mobile-pixel-clone" "$home/.claude/agents" "$home/.claude/tools" "$home/.local/bin" 2>/dev/null || true

  # Selected external capabilities only: no broad Android/design plugin bundle.
  # This keeps startup skill descriptions small and avoids another MCP server.
  sync_managed_repo "$user" "$home" "https://github.com/android/skills.git" "$vendor/google-android-skills"
  sync_managed_repo "$user" "$home" "https://github.com/amit-nayar/android-adb-skill.git" "$vendor/android-adb-skill"

  # Link only the two Google skills relevant to screenshot-faithful Android UI work.
  # Their full bodies remain progressively loaded only when Claude invokes them.
  rm -rf "$home/.claude/skills/google-android-testing-setup" "$home/.claude/skills/google-android-edge-to-edge"
  cp -a "$vendor/google-android-skills/testing/testing-setup" "$home/.claude/skills/google-android-testing-setup"
  cp -a "$vendor/google-android-skills/system/edge-to-edge" "$home/.claude/skills/google-android-edge-to-edge"
  ln -sfnT "$vendor/android-adb-skill/tools/android" "$home/.local/bin/claude-android"
  chmod +x "$vendor/android-adb-skill/tools/android" 2>/dev/null || true

  # Dedicated tiny venv for deterministic local image comparisons. No model/API calls.
  # Install uv only when this stack actually needs repair and uv is missing.
  if ! run_u "$user" "$home" 'command -v uv >/dev/null 2>&1'; then
    warn "[$user] uv missing; installing only because mobile visual tooling needs repair"
    run_u "$user" "$home" 'set -o pipefail; curl -LsSf https://astral.sh/uv/install.sh | sh >/tmp/uv-install.log 2>&1' || {
      run_u "$user" "$home" 'tail -80 /tmp/uv-install.log 2>/dev/null || true'; return 1;
    }
  fi
  if [[ ! -x "$vendor/mobile-visual-venv/bin/python" ]]; then
    run_u "$user" "$home" "uv venv '$vendor/mobile-visual-venv' >/dev/null"
  fi
  if run_u "$user" "$home" "'$vendor/mobile-visual-venv/bin/python' -c 'import PIL,numpy' >/dev/null 2>&1"; then
    if [[ "$UPDATE" -eq 1 ]]; then
      run_u "$user" "$home" "uv pip install --quiet --upgrade --python '$vendor/mobile-visual-venv/bin/python' 'pillow>=10' 'numpy>=2'"
    else
      skip "[$user] Pillow/numpy visual runtime already healthy; no pip/network action"
    fi
  else
    warn "[$user] visual Python dependencies missing/broken; repairing"
    run_u "$user" "$home" "uv pip install --quiet --python '$vendor/mobile-visual-venv/bin/python' 'pillow>=10' 'numpy>=2'"
  fi

  cat > "$home/.claude/tools/mobile_visual.py" <<'PYVIS'
#!/usr/bin/env python3
import argparse, json, math, pathlib, sys
from PIL import Image, ImageChops, ImageEnhance, ImageOps
import numpy as np

def load(path):
    return ImageOps.exif_transpose(Image.open(path)).convert("RGB")

def emit(obj, code=0):
    print(json.dumps(obj, separators=(",", ":"), ensure_ascii=False))
    raise SystemExit(code)

def cmd_info(a):
    im=load(a.image)
    emit({"path":str(pathlib.Path(a.image)),"width":im.width,"height":im.height,"mode":"RGB"})

def cmd_crop(a):
    im=load(a.image)
    x,y,w,h=a.x,a.y,a.width,a.height
    if min(x,y,w,h)<0 or w<1 or h<1 or x+w>im.width or y+h>im.height:
        emit({"error":"crop_out_of_bounds","image_size":[im.width,im.height],"crop":[x,y,w,h]},2)
    out=pathlib.Path(a.output); out.parent.mkdir(parents=True,exist_ok=True)
    im.crop((x,y,x+w,y+h)).save(out)
    emit({"output":str(out),"width":w,"height":h})

def cmd_diff(a):
    ref=load(a.reference); act=load(a.actual)
    base={"reference_size":[ref.width,ref.height],"actual_size":[act.width,act.height],"size_match":ref.size==act.size}
    if ref.size!=act.size:
        emit(base|{"error":"size_mismatch"},2)
    r=np.asarray(ref,dtype=np.int16); b=np.asarray(act,dtype=np.int16)
    d=np.abs(r-b)
    per_pixel=d.max(axis=2)
    changed=per_pixel>a.threshold
    mae=float(d.mean())
    rmse=float(np.sqrt(np.mean(np.square(d,dtype=np.float64))))
    ratio=float(changed.mean())
    bbox=None
    if changed.any():
        ys,xs=np.where(changed); bbox=[int(xs.min()),int(ys.min()),int(xs.max()+1),int(ys.max()+1)]
    psnr=None if rmse==0 else float(20*math.log10(255.0/rmse))
    if a.diff_out:
        out=pathlib.Path(a.diff_out); out.parent.mkdir(parents=True,exist_ok=True)
        raw=ImageChops.difference(ref,act)
        ImageEnhance.Contrast(raw).enhance(3.0).save(out)
    emit(base|{"threshold":a.threshold,"mae":round(mae,4),"rmse":round(rmse,4),"changed_pixel_ratio":round(ratio,6),"psnr_db":None if psnr is None else round(psnr,3),"diff_bbox":bbox,"diff_out":a.diff_out})

def main():
    p=argparse.ArgumentParser(prog="claude-mobile-visual",description="Local token-efficient mobile reference image utilities")
    sp=p.add_subparsers(dest="cmd",required=True)
    q=sp.add_parser("info"); q.add_argument("image"); q.set_defaults(fn=cmd_info)
    q=sp.add_parser("crop"); q.add_argument("image"); q.add_argument("output"); q.add_argument("x",type=int); q.add_argument("y",type=int); q.add_argument("width",type=int); q.add_argument("height",type=int); q.set_defaults(fn=cmd_crop)
    q=sp.add_parser("diff"); q.add_argument("reference"); q.add_argument("actual"); q.add_argument("--threshold",type=int,default=8); q.add_argument("--diff-out"); q.set_defaults(fn=cmd_diff)
    a=p.parse_args(); a.fn(a)
if __name__=="__main__": main()
PYVIS
  chmod 0755 "$home/.claude/tools/mobile_visual.py"

  cat > "$home/.local/bin/claude-mobile-visual" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
exec "$HOME/.claude/vendor/mobile-visual-venv/bin/python" "$HOME/.claude/tools/mobile_visual.py" "$@"
WRAP
  chmod 0755 "$home/.local/bin/claude-mobile-visual"

  # Persistent per-project recall outside the repository. This avoids prompt-cache churn and
  # accidental git commits while still allowing every future Claude session for the same repo
  # to recover solved issues, durable decisions, and visual references on demand.
  cat > "$home/.claude/tools/project_state.py" <<'PYSTATE'
#!/usr/bin/env python3
import argparse, hashlib, json, os, pathlib, re, shutil, subprocess, sys, time
from PIL import Image, ImageOps

HOME=pathlib.Path.home()

def emit(obj, code=0):
    print(json.dumps(obj, separators=(",",":"), ensure_ascii=False))
    raise SystemExit(code)

def git(cmd, cwd):
    try:
        return subprocess.check_output(["git","-C",str(cwd),*cmd], stderr=subprocess.DEVNULL, text=True).strip()
    except Exception:
        return ""

def resolve_repo(arg=None):
    cwd=pathlib.Path(arg or os.getcwd()).resolve()
    root=git(["rev-parse","--show-toplevel"], cwd)
    if not root:
        emit({"error":"not_git_repo","cwd":str(cwd)},2)
    rootp=pathlib.Path(root).resolve()
    remote=git(["config","--get","remote.origin.url"], rootp)
    identity=(remote or str(rootp))+"|"+rootp.name
    key=hashlib.sha256(identity.encode()).hexdigest()[:24]
    base=HOME/".claude"/"project-state"/key
    (base/"visual"/"assets").mkdir(parents=True,exist_ok=True)
    (base/"visual"/"specs").mkdir(parents=True,exist_ok=True)
    meta=base/"meta.json"
    old={}
    if meta.exists():
        try: old=json.loads(meta.read_text())
        except Exception: old={}
    now=int(time.time())
    data={"key":key,"repo_root":str(rootp),"remote":remote or None,"created_at":old.get("created_at",now),"updated_at":now}
    meta.write_text(json.dumps(data,indent=2,ensure_ascii=False)+"\n")
    return rootp,base,data

def norm(s):
    return re.sub(r"\s+"," ",(s or "").strip()).lower()

def read_jsonl(path):
    out=[]
    if not path.exists(): return out
    for line in path.read_text(errors="ignore").splitlines():
        if not line.strip(): continue
        try: out.append(json.loads(line))
        except Exception: continue
    return out

def write_jsonl(path, rows):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text("".join(json.dumps(x,separators=(",",":"),ensure_ascii=False)+"\n" for x in rows))

def load_payload(a):
    if getattr(a,"file",None):
        return json.loads(pathlib.Path(a.file).read_text())
    raw=sys.stdin.read().strip()
    if not raw: emit({"error":"json_payload_required"},2)
    return json.loads(raw)

def compact_list(v):
    if v is None: return []
    if isinstance(v,list): return [str(x).strip() for x in v if str(x).strip()]
    if isinstance(v,str): return [x.strip() for x in v.split(",") if x.strip()]
    return [str(v)]

def upsert(kind, payload, base):
    now=int(time.time())
    title=str(payload.get("title","")).strip()
    if not title: emit({"error":"title_required"},2)
    if kind=="issue":
        discriminator=norm(str(payload.get("cause","") or payload.get("symptom","")))
        path=base/"issues.jsonl"
        fields=("title","symptom","cause","fix","status")
    else:
        # Accept natural aliases used by Claude/user prompts, but persist one
        # canonical field so cross-session recall never loses the "why".
        rationale=payload.get("rationale")
        if rationale in (None,""):
            rationale=payload.get("reason")
        if rationale in (None,""):
            rationale=payload.get("why")
        if rationale not in (None,""):
            payload=dict(payload)
            payload["rationale"]=rationale
        discriminator=norm(str(payload.get("decision","") or payload.get("rationale","")))
        path=base/"decisions.jsonl"
        fields=("title","decision","rationale","status")
    eid=hashlib.sha256((norm(title)+"|"+discriminator).encode()).hexdigest()[:16]
    rows=read_jsonl(path); found=None
    for r in rows:
        if r.get("id")==eid:
            found=r; break
    if found is None:
        found={"id":eid,"kind":kind,"created_at":now,"occurrences":0}
        rows.append(found)
    for f in fields:
        if payload.get(f) not in (None,""): found[f]=payload.get(f)
    found["files"]=compact_list(payload.get("files",found.get("files",[])))
    found["tags"]=compact_list(payload.get("tags",found.get("tags",[])))
    found["updated_at"]=now
    found["occurrences"]=int(found.get("occurrences",0))+1
    write_jsonl(path,rows)
    emit({"ok":True,"kind":kind,"id":eid,"path":str(path),"occurrences":found["occurrences"]})

def score_row(qtokens, q, r):
    text=" ".join(str(r.get(k,"")) for k in ("title","symptom","cause","fix","decision","rationale","status","files","tags","label"))
    nt=norm(text)
    toks=set(re.findall(r"[a-z0-9_./-]+",nt))
    overlap=len(qtokens & toks)
    phrase=4 if q and q in nt else 0
    title=2 if q and q in norm(str(r.get("title",r.get("label","")))) else 0
    return overlap+phrase+title

def cmd_search(a):
    _,base,_=resolve_repo(a.repo)
    q=norm(a.query); qtokens=set(re.findall(r"[a-z0-9_./-]+",q))
    rows=[]
    for p in (base/"issues.jsonl",base/"decisions.jsonl"):
        rows.extend(read_jsonl(p))
    manifest=base/"visual"/"manifest.json"
    if manifest.exists():
        try:
            m=json.loads(manifest.read_text())
            rows.extend(dict(v,kind="visual") for v in m.get("items",{}).values())
        except Exception: pass
    ranked=[]
    for r in rows:
        sc=score_row(qtokens,q,r)
        if sc>0: ranked.append((sc,int(r.get("updated_at",0)),r))
    ranked.sort(key=lambda x:(x[0],x[1]),reverse=True)
    slim=[]
    for sc,_,r in ranked[:a.limit]:
        keep={k:r.get(k) for k in ("id","kind","title","label","symptom","cause","fix","decision","rationale","status","files","tags","spec_path","asset_path","updated_at") if r.get(k) not in (None,"",[])}
        keep["score"]=sc; slim.append(keep)
    emit({"query":a.query,"count":len(slim),"results":slim})

def sha_file(path):
    h=hashlib.sha256()
    with open(path,"rb") as f:
        for b in iter(lambda:f.read(1024*1024),b""): h.update(b)
    return h.hexdigest()

def dhash(path):
    im=ImageOps.exif_transpose(Image.open(path)).convert("L").resize((9,8))
    px=list(im.get_flattened_data()); bits=0
    for y in range(8):
        for x in range(8):
            bits=(bits<<1) | (1 if px[y*9+x] > px[y*9+x+1] else 0)
    return f"{bits:016x}"

def ham(a,b):
    try: return (int(a,16)^int(b,16)).bit_count()
    except Exception: return 999

def load_manifest(base):
    p=base/"visual"/"manifest.json"
    if p.exists():
        try: m=json.loads(p.read_text())
        except Exception: m={}
    else: m={}
    if not isinstance(m.get("items"),dict): m["items"]={}
    return p,m

def visual_probe(base,image):
    p=pathlib.Path(image).resolve()
    if not p.is_file(): emit({"error":"image_not_found","path":str(p)},2)
    sha=sha_file(p); dh=dhash(p)
    with Image.open(p) as im: size=list(ImageOps.exif_transpose(im).size)
    mp,m=load_manifest(base)
    exact=m["items"].get(sha)
    nearest=None
    for r in m["items"].values():
        if r.get("size")!=size: continue
        d=ham(dh,r.get("dhash",""))
        if nearest is None or d<nearest[0]: nearest=(d,r)
    return p,sha,dh,size,mp,m,exact,nearest

def cmd_visual_lookup(a):
    _,base,_=resolve_repo(a.repo)
    p,sha,dh,size,mp,m,exact,nearest=visual_probe(base,a.image)
    n=None
    if nearest and exact is None:
        d,r=nearest
        if d<=a.near_threshold:
            n={"distance":d,"id":r.get("id"),"label":r.get("label"),"asset_path":r.get("asset_path"),"spec_path":r.get("spec_path")}
    emit({"sha256":sha,"size":size,"exact":exact,"near":n})

def cmd_visual_register(a):
    _,base,_=resolve_repo(a.repo)
    p,sha,dh,size,mp,m,exact,nearest=visual_probe(base,a.image)
    now=int(time.time())
    if exact:
        exact["last_seen_at"]=now; exact["occurrences"]=int(exact.get("occurrences",1))+1
        if a.label: exact["label"]=a.label
        mp.write_text(json.dumps(m,indent=2,ensure_ascii=False)+"\n")
        emit({"status":"exact","item":exact})
    ext=p.suffix.lower() if p.suffix else ".png"
    asset=base/"visual"/"assets"/(sha+ext)
    if not asset.exists(): shutil.copy2(p,asset)
    spec=base/"visual"/"specs"/(sha+".json")
    item={"id":sha,"kind":"visual","label":a.label or p.stem,"sha256":sha,"dhash":dh,"size":size,"asset_path":str(asset),"spec_path":str(spec),"source_name":p.name,"created_at":now,"last_seen_at":now,"occurrences":1}
    m["items"][sha]=item
    mp.write_text(json.dumps(m,indent=2,ensure_ascii=False)+"\n")
    near=None
    if nearest and nearest[0]<=a.near_threshold:
        near={"distance":nearest[0],"id":nearest[1].get("id"),"label":nearest[1].get("label"),"spec_path":nearest[1].get("spec_path")}
    emit({"status":"new","item":item,"near":near})

def cmd_visual_set_spec(a):
    _,base,_=resolve_repo(a.repo)
    mp,m=load_manifest(base)
    item=m["items"].get(a.id)
    if not item: emit({"error":"unknown_visual_id","id":a.id},2)
    src=pathlib.Path(a.file).resolve()
    if not src.is_file(): emit({"error":"spec_not_found","path":str(src)},2)
    # Validate JSON and rewrite compactly.
    data=json.loads(src.read_text())
    dst=pathlib.Path(item["spec_path"]); dst.parent.mkdir(parents=True,exist_ok=True)
    dst.write_text(json.dumps(data,indent=2,ensure_ascii=False)+"\n")
    item["updated_at"]=int(time.time())
    mp.write_text(json.dumps(m,indent=2,ensure_ascii=False)+"\n")
    emit({"ok":True,"id":a.id,"spec_path":str(dst)})

def cmd_visual_get(a):
    _,base,_=resolve_repo(a.repo)
    mp,m=load_manifest(base); item=m["items"].get(a.id)
    if not item: emit({"error":"unknown_visual_id","id":a.id},2)
    out=dict(item)
    sp=pathlib.Path(item.get("spec_path",""))
    if a.include_spec and sp.is_file():
        try: out["spec"]=json.loads(sp.read_text())
        except Exception: pass
    emit(out)

def cmd_status(a):
    root,base,meta=resolve_repo(a.repo)
    issues=read_jsonl(base/"issues.jsonl"); decisions=read_jsonl(base/"decisions.jsonl")
    mp,m=load_manifest(base)
    emit({"repo":str(root),"state_dir":str(base),"issues":len(issues),"decisions":len(decisions),"visuals":len(m.get("items",{}))})

def main():
    p=argparse.ArgumentParser(prog="claude-project-state",description="Compact persistent per-project issue/decision/visual recall outside the repo")
    p.add_argument("--repo",help="repo path; defaults to current Git repo")
    sp=p.add_subparsers(dest="cmd",required=True)
    q=sp.add_parser("status"); q.set_defaults(fn=cmd_status)
    q=sp.add_parser("search"); q.add_argument("query"); q.add_argument("--limit",type=int,default=6); q.set_defaults(fn=cmd_search)
    q=sp.add_parser("record-issue"); q.add_argument("--file"); q.set_defaults(fn=lambda a: upsert("issue",load_payload(a),resolve_repo(a.repo)[1]))
    q=sp.add_parser("record-decision"); q.add_argument("--file"); q.set_defaults(fn=lambda a: upsert("decision",load_payload(a),resolve_repo(a.repo)[1]))
    q=sp.add_parser("visual-lookup"); q.add_argument("image"); q.add_argument("--near-threshold",type=int,default=4); q.set_defaults(fn=cmd_visual_lookup)
    q=sp.add_parser("visual-register"); q.add_argument("image"); q.add_argument("--label"); q.add_argument("--near-threshold",type=int,default=4); q.set_defaults(fn=cmd_visual_register)
    q=sp.add_parser("visual-set-spec"); q.add_argument("id"); q.add_argument("--file",required=True); q.set_defaults(fn=cmd_visual_set_spec)
    q=sp.add_parser("visual-get"); q.add_argument("id"); q.add_argument("--include-spec",action="store_true"); q.set_defaults(fn=cmd_visual_get)
    a=p.parse_args(); a.fn(a)
if __name__=="__main__": main()
PYSTATE
  chmod 0755 "$home/.claude/tools/project_state.py"

  cat > "$home/.local/bin/claude-project-state" <<'WRAPSTATE'
#!/usr/bin/env bash
set -euo pipefail
exec "$HOME/.claude/vendor/mobile-visual-venv/bin/python" "$HOME/.claude/tools/project_state.py" "$@"
WRAPSTATE
  chmod 0755 "$home/.local/bin/claude-project-state"

  cat > "$home/.claude/skills/mobile-pixel-clone/SKILL.md" <<'SKILL'
---
name: mobile-pixel-clone
description: Token-efficient pixel-faithful Android/mobile UI recreation from screenshots, image sheets, mockups, or reference images. Use automatically for clone, recreate, match, reproduce, pixel-perfect, visually-identical, or repeated mobile reference-image requests.
---

# Mobile pixel clone orchestrator

Do not switch the main conversation model or effort for this workflow. Keep the main session on its existing model/cache.

1. Treat the supplied visual as source of truth. Preserve the project's existing architecture, theme, navigation, libraries, and reusable components.
2. If the reference is available as a local filesystem image, run `claude-project-state visual-lookup <path>` BEFORE doing visual analysis.
   - Exact match with an existing spec: reuse the stored compact spec and asset; do not re-analyze the full image unless the user explicitly asks to reconsider it.
   - Near perceptual match: treat the prior spec only as a hint; verify changed regions because tiny UI changes can matter.
   - New image: run `claude-project-state visual-register <path> --label <screen/state>`, analyze the full reference only once, write a compact JSON spec to a temp file, then attach it with `claude-project-state visual-set-spec <id> --file <spec.json>`.
3. If the reference exists only as a chat attachment with no usable local path, do not pretend raw-pixel dedup is possible. Search prior project state/Context Mode for an existing screen label/spec first, analyze only what is missing, and persist the compact spec for future turns.
4. For image sheets, crop and cache each needed screen/state once. Never repeatedly feed the full sheet through vision when a stored spec/crop is sufficient. Prefer a stable local reference path over repeated chat re-uploads whenever one is available.
5. If the same local reference or a previously cached screen is supplied again, reuse its exact stored spec/asset before any new full-image reasoning. Never ask the user to re-upload a known reference when persistent state already has it.
6. Batch all clearly related visual work for the requested screen into one bounded implementation pass (layout, typography, colors, components, buttons, icons, system bars, spacing) instead of forcing component-by-component user round trips.
7. Before asking a clarification question, resolve what you can from the reference/spec, project files, Context Mode, Auto Memory, project-state, and Graft. Ask only when a real ambiguity would materially change product behavior or fidelity.
8. Before broad source exploration, use Graft to locate the exact screen/components. Use Graphify only if broader code+docs/config knowledge is genuinely needed.
9. Delegate the implementation/render/diff loop to `mobile-ui-implementer`. Pass only the task, stored compact spec path/content, reference asset/crop path, target state, and relevant source paths. Do not forward the full conversation or verbose logs.
10. The implementer owns build/install/ADB screenshot/local pixel-diff iterations and may invoke `mobile-ui-qa-opus` once only when measured progress stalls. Do not change the main model to Opus.
11. Return only the implementer's concise result to the main conversation. Do not duplicate its logs or re-run the same visual analysis in the parent.

Use `testing-setup` only when persistent screenshot regression tests are useful. Use `edge-to-edge` only for real system-bar/inset issues. Do not load broad web/3D skills for a normal Android screenshot clone.
SKILL

  cat > "$home/.claude/agents/mobile-ui-implementer.md" <<'AGENT'
---
name: mobile-ui-implementer
description: Use proactively for Android/mobile screenshot or image-sheet recreation. Implements and measures pixel parity in an isolated context so render/build/diff loops do not pollute the main conversation.
model: sonnet
effort: high
maxTurns: 20
---

You are the primary mobile visual implementation worker. Work in the existing checkout and preserve architecture.

- Consume only the compact task/reference evidence supplied by the parent. Prefer specs/assets returned by `claude-project-state`; never re-analyze an exact-known reference image just because it was attached again.
- Use Graft before broad source reads. Prefer exact files/ranges and existing project assets/components.
- Use `claude-android` for Android build/install/navigation/screenshot when appropriate and `claude-mobile-visual` for local image info/crop/diff. Keep verbose build/UI-tree output out of your report.
- Fix in order: viewport/insets and geometry, typography, colors/assets/components, then micro-spacing.
- Run at most four measured visual correction passes. Record compact metrics per pass (`mae`, `changed_pixel_ratio`, size match).
- After two measured passes, call `mobile-ui-qa-opus` at most once only if progress is stalled: relative improvement in both MAE and changed-pixel ratio is under 10%, or changed-pixel ratio remains above 0.08 and the remaining cause is ambiguous. Also allow one QA call for an explicit maximum-fidelity final check when a stubborn mismatch remains.
- When invoking QA, pass only: reference crop path, latest actual screenshot path, compact spec, latest/previous metrics, relevant source file paths, and a short list of attempted fixes. Never send the full parent conversation or full build logs.
- Apply the QA's targeted recommendations yourself, then run one final measured pass. Do not invoke Opus repeatedly.
- Do not change the parent/main session model or effort.

Return a compact final report: `VISUAL_STATUS` (`pass`, `improved`, `blocked`), changed files, final metrics, build/test status, and only genuinely unresolved font/asset/device-state uncertainty.
AGENT

  cat > "$home/.claude/agents/mobile-ui-qa-opus.md" <<'AGENT'
---
name: mobile-ui-qa-opus
description: Expensive mobile visual QA specialist. Use only after the Sonnet mobile implementer stalls on measured pixel parity or for one explicit maximum-fidelity final diagnosis; never for routine coding.
model: opus
effort: high
maxTurns: 6
tools: Read, Grep, Glob, Bash
disallowedTools: Agent
---

You are a narrow visual-difference diagnostician, not the primary implementer.

Use only the compact evidence and file paths provided. Do not explore the whole repository, do not rerun long builds unless strictly necessary, and do not request the full conversation.

Compare the reference crop, latest screenshot, diff metrics/image, compact design spec, and relevant source files. Identify the smallest high-confidence corrections that explain the remaining mismatch. Prioritize geometry/insets, typography/font metrics, colors/assets, component shape, and micro-spacing in that order.

Return at most five ranked fixes with exact file/symbol references and concrete values/deltas where defensible. State `QA_CONFIDENCE: high|medium|low`. Do not edit files and do not spawn another agent.
AGENT

  chown -R "$user":"$(group_of "$user")" "$home/.claude/vendor" "$home/.claude/skills/mobile-pixel-clone" "$home/.claude/skills/google-android-testing-setup" "$home/.claude/skills/google-android-edge-to-edge" "$home/.claude/agents/mobile-ui-implementer.md" "$home/.claude/agents/mobile-ui-qa-opus.md" "$home/.claude/tools/mobile_visual.py" "$home/.claude/tools/project_state.py" "$home/.local/bin/claude-android" "$home/.local/bin/claude-mobile-visual" "$home/.local/bin/claude-project-state" 2>/dev/null || true

  test -f "$home/.claude/skills/mobile-pixel-clone/SKILL.md"
  test -f "$home/.claude/skills/google-android-testing-setup/SKILL.md"
  test -f "$home/.claude/skills/google-android-edge-to-edge/SKILL.md"
  test -f "$home/.claude/agents/mobile-ui-implementer.md"
  test -f "$home/.claude/agents/mobile-ui-qa-opus.md"
  run_u "$user" "$home" 'claude-mobile-visual --help >/dev/null && claude-project-state --help >/dev/null'
  ok "[$user] mobile pixel-clone + visual dedup + project recall + Android ADB + local diff ready"
}

cleanup_legacy_mcp_json() {
  local user="$1" home="$2" f="$home/.claude.json"
  [[ -f "$f" ]] || return 0
  [[ "$VERIFY_ONLY" -eq 0 ]] || return 0
  log "[$user] Remove legacy duplicate Context Mode / Caveman MCP entries"
  python3 - "$f" "$STAMP" <<'PY' || return 1
import json,pathlib,sys,shutil,os
p=pathlib.Path(sys.argv[1]); stamp=sys.argv[2]
try:
    raw=p.read_text()
    cfg=json.loads(raw)
except Exception as e:
    raise SystemExit(f"Invalid JSON in {p}: {e}")
remove={"context-mode","caveman","caveman-shrink","caveman-proxy"}
changed=False
servers=cfg.get("mcpServers")
if isinstance(servers,dict):
    for k in list(servers):
        if k in remove:
            servers.pop(k,None); changed=True
projects=cfg.get("projects")
if isinstance(projects,dict):
    for pdata in projects.values():
        if not isinstance(pdata,dict): continue
        m=pdata.get("mcpServers")
        if isinstance(m,dict):
            for k in list(m):
                if k in remove:
                    m.pop(k,None); changed=True
if not changed:
    print("UNCHANGED: no legacy Context Mode/Caveman MCP entries")
else:
    b=pathlib.Path(str(p)+f".backup-{stamp}")
    shutil.copy2(p,b)
    try:
        st=p.stat(); os.chown(b,st.st_uid,st.st_gid)
    except Exception:
        pass
    p.write_text(json.dumps(cfg,indent=2,ensure_ascii=False)+"\n")
    print("CHANGED: legacy duplicate MCP entries removed")
PY
  chown "$user":"$(group_of "$user")" "$f" 2>/dev/null || true
}

write_repo_bootstrap_hook() {
  local user="$1" home="$2" f="$home/.claude/hooks/ensure-project-context.sh"
  if [[ -f "$f" ]] && grep -Fq 'CLAUDE-SMART-HOOK-SCHEMA=4.9.0-1' "$f"; then
    skip "[$user] SessionStart hook already current; no rewrite"
    return 0
  fi
  [[ "$VERIFY_ONLY" -eq 0 ]] || return 1
  mkdir -p "$home/.claude/hooks" "$home/.claude/logs"
  cat > "$f" <<'HOOK'
#!/usr/bin/env bash
# User-global SessionStart hook. Silent by design: zero context noise.
# CLAUDE-SMART-HOOK-SCHEMA=4.9.0-1
set -u
INPUT="$(cat 2>/dev/null || true)"
CWD="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("cwd", ""))' <<<"$INPUT" 2>/dev/null || true)"
[[ -n "$CWD" && -d "$CWD" ]] || exit 0
REPO="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO" && -d "$REPO" ]] || exit 0
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
LOG_DIR="$HOME/.claude/logs"; mkdir -p "$LOG_DIR"
KEY="$(printf '%s' "$REPO" | sha256sum | awk '{print $1}')"
LOCK="$LOG_DIR/project-bootstrap-${KEY}.lock"
LOG="$LOG_DIR/project-bootstrap.log"
exec 9>"$LOCK"; flock -n 9 || exit 0

# Graphify writes generated graphs into the workspace. Its own docs recommend keeping
# these paths out of Claude's watched input set to avoid prompt-cache invalidation.
IGNORE="$REPO/.claudeignore"
if ! grep -Fq '# BEGIN CLAUDE-GRAPH-CACHE-IGNORE' "$IGNORE" 2>/dev/null; then
  python3 - "$IGNORE" <<'PY'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1]); s=p.read_text(errors='ignore') if p.exists() else ''
s=re.sub(r'\n?# BEGIN CLAUDE-GRAPH-CACHE-IGNORE\n.*?# END CLAUDE-GRAPH-CACHE-IGNORE\n?', '\n', s, flags=re.S)
s=s.rstrip()+'''\n\n# BEGIN CLAUDE-GRAPH-CACHE-IGNORE
graph.json
graphify-out/
graft/
.claude/mobile-visual-cache/
# END CLAUDE-GRAPH-CACHE-IGNORE
'''
p.write_text(s)
PY
fi

# Keep Graphify's post-commit hook, but install it only when missing.
if command -v graphify >/dev/null 2>&1; then
  GH="$(git -C "$REPO" rev-parse --git-path hooks/post-commit 2>/dev/null || true)"
  if [[ -z "$GH" || ! -f "$GH" ]] || ! grep -qi 'graphify' "$GH" 2>/dev/null; then
    (cd "$REPO" && graphify hook install >/dev/null 2>&1) || true
  fi
fi

# Graft is per-repo data but globally installed. Init is idempotent.
# Current upstream may ignore --no-mcp for Claude Code, so after init we remove any
# project-local Graft MCP and keep the canonical user-scoped MCP only.
if command -v graft >/dev/null 2>&1; then
  GV="$(graft --version 2>/dev/null | head -1 | tr -d '\r\n' || true)"
  MARK="$REPO/graft/.claude-bootstrap-graft-version"
  NEED=0
  [[ -f "$REPO/.claude/skills/graft/SKILL.md" ]] || NEED=1
  [[ -d "$REPO/graft" ]] || NEED=1
  [[ -f "$MARK" ]] || NEED=1
  [[ -f "$MARK" && "$(cat "$MARK" 2>/dev/null || true)" == "$GV" ]] || NEED=1

  if [[ "$NEED" -eq 1 ]]; then
    {
      printf '\n[%s] graft repair/init %s (version=%s)\n' "$(date -Is)" "$REPO" "$GV"
      timeout 600 graft init "$REPO" --agents claude --no-global || true

      python3 - "$REPO/.mcp.json" <<'PYMCP'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
if p.exists():
    try: c=json.loads(p.read_text())
    except Exception: c=None
    if isinstance(c,dict):
        m=c.get('mcpServers')
        if isinstance(m,dict) and 'graft' in m:
            m.pop('graft',None)
            p.write_text(json.dumps(c,indent=2,ensure_ascii=False)+'\n')
PYMCP

      timeout 60 graft ask "__claude_bootstrap_healthcheck__" "$REPO" --json >/dev/null 2>&1
      RC=$?
      if [[ "$RC" -ne 0 ]]; then
        printf '[%s] graft ask unhealthy rc=%s; rebuilding regenerable cache\n' "$(date -Is)" "$RC"
        rm -rf -- "$REPO/graft"
        timeout 600 graft build "$REPO"
        timeout 60 graft ask "__claude_bootstrap_healthcheck__" "$REPO" --json >/dev/null 2>&1
      fi
      mkdir -p "$REPO/graft"
      printf '%s' "$GV" > "$MARK"
    } >>"$LOG" 2>&1 || true
  fi
fi
exit 0
HOOK
  chmod 0755 "$f"
  chown -R "$user":"$(group_of "$user")" "$home/.claude/hooks" "$home/.claude/logs" 2>/dev/null || true
}

merge_settings() {
  local user="$1" home="$2" f="$home/.claude/settings.json"
  [[ "$VERIFY_ONLY" -eq 0 ]] || return 0
  log "[$user] Merge ~/.claude/settings.json"
  mkdir -p "$home/.claude"
  python3 - "$f" "$home" "$AUTO_COMPACT_WINDOW" "$STAMP" <<'PY'
import json,pathlib,sys,shutil,os
p=pathlib.Path(sys.argv[1]); home=sys.argv[2]; window=sys.argv[3]; stamp=sys.argv[4]
try:
    raw=p.read_text() if p.exists() else ''
    cfg=json.loads(raw) if raw.strip() else {}
except Exception as e: raise SystemExit(f"Invalid JSON in {p}: {e}")

cfg.setdefault("$schema","https://json.schemastore.org/claude-code-settings.json")
cfg["autoMemoryEnabled"]=True
cfg["autoUpdatesChannel"]="latest"
# Quota-aware global default: Sonnet handles the large majority of coding efficiently.
# High-effort visual work runs in dedicated subagents; the main conversation stays cache-stable.
cfg["model"]="sonnet"
cfg["effortLevel"]="medium"

# Claude Code >=2.1.251 saves interactive effort choices per model. Normalize the
# canonical Sonnet 5 entry so an old Desktop/CLI "Sonnet High" preference does
# not silently outrank the generic medium default on a fresh session.
model_settings=cfg.setdefault("modelSettings",{})
sonnet_settings=model_settings.setdefault("claude-sonnet-5",{})
sonnet_settings["effortLevel"]="medium"
# Clean only obsolete alias entries that can preserve the old Sonnet effort.
for alias in ("sonnet", "sonnet[1m]"):
    entry=model_settings.get(alias)
    if isinstance(entry,dict):
        entry.pop("effortLevel",None)
        if not entry:
            model_settings.pop(alias,None)

env=cfg.setdefault("env",{})
env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"]=window
env["ENABLE_TOOL_SEARCH"]="true"
env["CLAUDE_CODE_GLOB_NO_IGNORE"]="false"
# Permit exactly the mobile implementer -> Opus QA nesting pattern while preventing deep/runaway agent trees.
env["CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH"]="2"
env["CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS"]="2"
# Never disable auto updater in our managed block.
env.pop("DISABLE_AUTOUPDATER",None)
env.pop("DISABLE_UPDATES",None)

# Register third-party marketplaces globally and enable startup auto-update.
mk=cfg.setdefault("extraKnownMarketplaces",{})
mk["context-mode"]={"source":{"source":"github","repo":"mksglu/context-mode"},"autoUpdate":True}
mk["caveman"]={"source":{"source":"github","repo":"JuliusBrussee/caveman"},"autoUpdate":True}
plugins=cfg.setdefault("enabledPlugins",{})
plugins["context-mode@context-mode"]=True
plugins["caveman@caveman"]=True

# Replace only this bootstrap's SessionStart hook; preserve all unrelated hooks.
hooks=cfg.setdefault("hooks",{})
groups=hooks.get("SessionStart",[])
clean=[]
for g in groups:
    if not isinstance(g,dict):
        clean.append(g); continue
    hs=g.get("hooks",[])
    hs2=[h for h in hs if not (isinstance(h,dict) and "ensure-project-context.sh" in str(h.get("command",""))) and not (isinstance(h,dict) and "ensure-graft-project.sh" in str(h.get("command","")))]
    if hs2:
        ng=dict(g); ng["hooks"]=hs2; clean.append(ng)
hooks["SessionStart"]=clean
hooks["SessionStart"].append({
    "matcher":"startup|resume|clear|compact",
    "hooks":[{"type":"command","command":f"{home}/.claude/hooks/ensure-project-context.sh","timeout":600}]
})

new=json.dumps(cfg,indent=2,ensure_ascii=False)+"\n"
if new == raw:
    print("UNCHANGED: settings already match production policy")
else:
    if p.exists():
        b=pathlib.Path(str(p)+f".backup-{stamp}")
        shutil.copy2(p,b)
        try:
            st=p.stat(); os.chown(b,st.st_uid,st.st_gid)
        except Exception:
            pass
    p.write_text(new)
    print("CHANGED: settings repaired")
PY
  chown "$user":"$(group_of "$user")" "$f" 2>/dev/null || true
}

merge_global_claude_md() {
  local user="$1" home="$2" f="$home/.claude/CLAUDE.md"
  [[ "$VERIFY_ONLY" -eq 0 ]] || return 0
  log "[$user] Merge ~/.claude/CLAUDE.md"
  mkdir -p "$home/.claude"; touch "$f"
  python3 - "$f" "$STAMP" <<'PY'
import pathlib,re,sys,shutil,os
p=pathlib.Path(sys.argv[1]); stamp=sys.argv[2]; original=p.read_text(errors='ignore'); s=original
for tag in ("CLAUDE-BOOTSTRAP-GLOBAL","CLAUDE-CONTEXT-GLOBAL"):
    s=re.sub(rf'\n?<!-- BEGIN {tag} -->.*?<!-- END {tag} -->\n?', '\n', s, flags=re.S)
block=r'''<!-- BEGIN CLAUDE-CONTEXT-GLOBAL -->
## Global continuity + token discipline

- Never ask the user to repeat prior project context before checking persistent sources.
- For repeated bugs, prior decisions, or wording such as "again", "same as before", "already discussed", or a familiar symptom, first run a cheap local `claude-project-state search "<compact query>"`. If that is insufficient, search Context Mode for conversation nuance. Do not perform this recall search on every trivial prompt.
- After a bug/root cause is confirmed and the fix is verified, record one compact issue entry with `claude-project-state record-issue` (title, symptom, cause, verified fix, relevant files, status/tags). After a durable architecture/design decision is accepted, record one compact decision entry including its rationale/reason. `claude-project-state` canonicalizes `reason`/`why` to `rationale`. Update/deduplicate existing entries instead of creating verbose duplicates.
- Project recall state lives under `~/.claude/project-state/` outside repositories so it survives conversations without changing repo files or invalidating prompt cache. It is retrieval memory, not a transcript; keep entries concise.
- On new/resumed/compacted sessions, recover objective, decisions, constraints, rejected approaches, modified files, errors/tests, and next step from Context Mode and Auto Memory first. If nothing exists, proceed as a fresh task.
- Keep active context small. Large logs, command output, web/docs, and old conversation history belong in Context Mode; retrieve only relevant fragments.
- Durable project facts and recurring corrections belong in Auto Memory. Never store secrets or credentials there.
- Do not reread unchanged files. Prefer exact symbols, file ranges, dependency/caller queries, and targeted retrieval.
- For unfamiliar code, architecture, callers, dependencies, or blast radius: use Graft before broad grep/read exploration. Graft is automatically initialized per Git repository; never ask the user to run graft init.
- If a Graft MCP call returns CONNECTION_CLOSED, crashes, or is unavailable: do not retry the same MCP call in a loop. Try the local `graft` CLI once. If that also fails, continue with targeted repository reads/searches and let the bootstrap repair Graft on the next session. Never burn tokens repeatedly retrying a dead Graft server.
- Use Graphify only for broader code+docs/config/schema or cross-domain knowledge. If Graphify is useful but no project graph exists, create/update it yourself with Graphify CLI/skill; never ask the user to type /graphify. Do not run Graphify and Graft redundantly for every task.
- Generated graph caches (graphify-out, graph.json, graft/) are local retrieval artifacts, not conversation context.
- Prefer existing project libraries/tools; avoid adding equivalent dependencies unnecessarily.
- For mobile UI recreation from screenshots/image sheets/reference images, automatically use the `mobile-pixel-clone` workflow and delegate the render/diff loop to `mobile-ui-implementer` (Sonnet/high). The supplied visual is the source of truth.
- Never switch the main session model/effort for visual work. Keep the parent cache stable; use the dedicated subagent model overrides instead.
- `mobile-ui-implementer` may invoke `mobile-ui-qa-opus` once only after measured visual progress stalls or for one explicit stubborn maximum-fidelity QA. Opus receives only compact reference/diff/source evidence, never the full conversation.
- For screenshot-driven mobile work, hash/lookup a local reference with `claude-project-state` before vision. Exact-known images reuse their stored spec/asset; new images are registered once and get a compact visual spec. Then work one screen/state at a time and prefer local render/screenshot + numeric diff over repeated full-image reads.
- Prefer the local `claude-android` command for Android screenshots/UI inspection instead of adding an Android MCP server. Use `claude-mobile-visual` for local image info/crop/diff; keep its output compact JSON.
- On Android/Compose tasks, generic web/3D design skills are secondary. Activate at most two design skills; `mobile-pixel-clone` takes priority for reference-image parity.
- Default the main session to Sonnet/medium for quota efficiency. High effort and Opus are isolated inside the visual subagents; avoid main-session model/effort switches because they can invalidate prompt cache.
- Keep responses concise; do not recap visible information. Preserve technical correctness, code, commands, exact errors, and safety details.
- Never tell the user to manually /compact or remind you of context during normal work; automatic compaction + persistent retrieval should handle continuity.

### Usage-limit best practices (automatic)
- Treat current conversation length, attachment size, tool usage, model choice, and effort as scarce resources. Optimize them without asking the user to manage the optimization.
- Never ask the user to repeat text, re-upload an image, or restate project background before searching `claude-project-state`, Context Mode, Auto Memory, existing local files, and cached design references.
- Prefer stable local file paths for reference images/documents that will be reused. When a local design sheet exists, register it once, crop/cache the needed screens once, and reuse those crops/specs instead of repeatedly processing the full attachment.
- If an exact visual reference is already cached, reuse its stored asset/spec and inspect only the changed or ambiguous region. A near match is a hint only and must be verified.
- Batch closely related requests into one bounded implementation pass whenever the intent is clear. For a mobile screen, handle the visible layout, typography, colors, buttons, components, icons, spacing, system bars, and related fixes together instead of forcing unnecessary back-and-forth messages.
- Do not split a clear task into multiple user confirmations. Ask a clarification question only when files, reference images/specs, project state, memory, or code cannot resolve an ambiguity that would materially change the result.
- Prefer existing project knowledge and local deterministic tools over web/research calls. Do not repeat a web search, repository search, build, image analysis, or tool call when a trustworthy result is already available and still applicable.
- Keep large build logs, UI trees, screenshots, and research output out of the parent conversation. Summarize or index them and return only the evidence needed for the next decision.
- Avoid unnecessary agent fan-out. Use the smallest number of subagents needed for the task and keep expensive Opus work narrow, isolated, and evidence-driven.
- When the user provides several related requirements in one message, preserve them as one coherent task and complete/validate them together rather than answering one item per turn.
<!-- END CLAUDE-CONTEXT-GLOBAL -->'''
new=s.rstrip()+"\n\n"+block+"\n"
if new == original:
    print("UNCHANGED: CLAUDE.md managed policy already current")
else:
    if p.exists() and original:
        b=pathlib.Path(str(p)+f".backup-{stamp}")
        shutil.copy2(p,b)
        try:
            st=p.stat(); os.chown(b,st.st_uid,st.st_gid)
        except Exception:
            pass
    p.write_text(new)
    print("CHANGED: CLAUDE.md managed policy repaired")
PY
  chown "$user":"$(group_of "$user")" "$f" 2>/dev/null || true
}


local_plugin_payload_present() {
  local home="$1" slug="$2"
  local root="$home/.claude/plugins"
  [[ -d "$root" ]] || return 1
  # Pure filesystem check; no Claude/plugin runtime startup.
  find "$root" -maxdepth 7 \( -type f -o -type d \) -iname "*${slug}*" -print -quit 2>/dev/null | grep -q .
}

local_plugins_configured() {
  local home="$1"
  python3 - "$home/.claude/settings.json" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
try: c=json.loads(p.read_text())
except Exception: raise SystemExit(1)
pl=c.get("enabledPlugins") or {}
mk=c.get("extraKnownMarketplaces") or {}
ok=(
    pl.get("context-mode@context-mode") is True and
    pl.get("caveman@caveman") is True and
    isinstance(mk.get("context-mode"),dict) and
    isinstance(mk.get("caveman"),dict)
)
raise SystemExit(0 if ok else 1)
PY
}

local_graft_mcp_ok() {
  local home="$1"
  python3 - "$home/.claude.json" "$home/.local/bin/graft" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); want=sys.argv[2]
if not p.exists(): raise SystemExit(1)
try: c=json.loads(p.read_text())
except Exception: raise SystemExit(1)
m=(c.get("mcpServers") or {}).get("graft")
if not isinstance(m,dict): raise SystemExit(1)
cmd=str(m.get("command",""))
args=m.get("args") or []
flat=" ".join([cmd]+[str(x) for x in args])
raise SystemExit(0 if want in flat and "mcp" in flat else 1)
PY
}

plugin_pair_fast_healthy() {
  local home="$1"
  local_plugins_configured "$home" || return 1
  local_plugin_payload_present "$home" "context-mode" || return 1
  local_plugin_payload_present "$home" "caveman" || return 1
  return 0
}

repo_scan_marker_path() {
  local home="$1"
  printf '%s\n' "$home/.claude/state/bootstrap-repos-v4.9.0.ok"
}

repo_scan_marker_valid() {
  local user="$1" home="$2"
  local f gv saved
  f="$(repo_scan_marker_path "$home")"
  [[ -f "$f" ]] || return 1
  gv="$(run_u "$user" "$home" 'graft --version 2>/dev/null | head -1' || true)"
  saved="$(cat "$f" 2>/dev/null || true)"
  [[ -n "$gv" && "$saved" == "$gv" ]]
}

write_repo_scan_marker() {
  local user="$1" home="$2"
  local f gv
  f="$(repo_scan_marker_path "$home")"
  gv="$(run_u "$user" "$home" 'graft --version 2>/dev/null | head -1' || true)"
  [[ -n "$gv" ]] || return 1
  mkdir -p "$(dirname "$f")"
  printf '%s' "$gv" > "$f"
  chown "$user":"$(group_of "$user")" "$f" 2>/dev/null || true
}

ensure_plugin() {
  local user="$1" home="$2" plugin="$3" marketplace_repo="$4"
  local installed=0
  run_u "$user" "$home" "\"\$HOME/.local/bin/claude\" plugin list 2>/dev/null | grep -Fq '$plugin'" && installed=1 || true

  if [[ "$installed" -eq 1 && "$UPDATE" -eq 0 ]]; then
    skip "[$user] plugin $plugin already installed/enabled by settings; no marketplace/update call"
    return 0
  fi

  if [[ "$installed" -eq 1 && "$UPDATE" -eq 1 ]]; then
    run_u "$user" "$home" "\"\$HOME/.local/bin/claude\" plugin update '$plugin' --scope user >/dev/null 2>&1 || true"
    run_u "$user" "$home" "\"\$HOME/.local/bin/claude\" plugin enable '$plugin' --scope user >/dev/null 2>&1 || true"
    return 0
  fi

  # Only touch marketplace/network when the plugin is actually missing.
  run_u "$user" "$home" "\"\$HOME/.local/bin/claude\" plugin marketplace add '$marketplace_repo' >/dev/null 2>&1 || true"
  run_u "$user" "$home" "\"\$HOME/.local/bin/claude\" plugin install '$plugin' --scope user >/dev/null"
  run_u "$user" "$home" "\"\$HOME/.local/bin/claude\" plugin enable '$plugin' --scope user >/dev/null 2>&1 || true"
}

repair_plugin_settings_after_cli() {
  local user="$1" home="$2" f="$home/.claude/settings.json"
  [[ "$VERIFY_ONLY" -eq 0 ]] || return 0
  python3 - "$f" <<'PYSET'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
try:
    c=json.loads(p.read_text())
except Exception as e:
    raise SystemExit(f"Invalid JSON in {p}: {e}")
mk=c.setdefault("extraKnownMarketplaces",{})
mk["context-mode"]={"source":{"source":"github","repo":"mksglu/context-mode"},"autoUpdate":True}
mk["caveman"]={"source":{"source":"github","repo":"JuliusBrussee/caveman"},"autoUpdate":True}
pl=c.setdefault("enabledPlugins",{})
pl["context-mode@context-mode"]=True
pl["caveman@caveman"]=True
new=json.dumps(c,indent=2,ensure_ascii=False)+"\n"
old=p.read_text() if p.exists() else ""
if old != new:
    p.write_text(new)
PYSET
  chown "$user":"$(group_of "$user")" "$f" 2>/dev/null || true
}

install_plugins_and_graft_mcp() {
  local user="$1" home="$2"
  log "[$user] Context Mode + Caveman plugins + Graft MCP"
  [[ -x "$home/.local/bin/claude" ]] || { err "[$user] Claude binary missing"; return 1; }

  if [[ "$VERIFY_ONLY" -eq 1 ]]; then
    # Deep verification is handled in verify_user(); do not mutate here.
    return 0
  fi

  local plugins_fast=0 mcp_fast=0
  plugin_pair_fast_healthy "$home" && plugins_fast=1 || true
  local_graft_mcp_ok "$home" && mcp_fast=1 || true

  if [[ "$UPDATE" -eq 0 && "$plugins_fast" -eq 1 ]]; then
    skip "[$user] Context Mode + Caveman locally healthy/configured; no Claude plugin runtime call"
  else
    # One plugin-list startup for both plugins, only if local proof is absent
    # (or update was explicitly requested).
    local plist=""
    plist="$(run_u "$user" "$home" '"$HOME/.local/bin/claude" plugin list 2>/dev/null' || true)"

    if [[ "$UPDATE" -eq 1 ]]; then
      if grep -Fq 'context-mode@context-mode' <<<"$plist"; then
        run_u "$user" "$home" '"$HOME/.local/bin/claude" plugin update "context-mode@context-mode" --scope user >/dev/null 2>&1 || true'
        run_u "$user" "$home" '"$HOME/.local/bin/claude" plugin enable "context-mode@context-mode" --scope user >/dev/null 2>&1 || true'
      else
        run_u "$user" "$home" '"$HOME/.local/bin/claude" plugin marketplace add "mksglu/context-mode" >/dev/null 2>&1 || true'
        run_u "$user" "$home" '"$HOME/.local/bin/claude" plugin install "context-mode@context-mode" --scope user >/dev/null'
      fi
      if grep -Fq 'caveman@caveman' <<<"$plist"; then
        run_u "$user" "$home" '"$HOME/.local/bin/claude" plugin update "caveman@caveman" --scope user >/dev/null 2>&1 || true'
        run_u "$user" "$home" '"$HOME/.local/bin/claude" plugin enable "caveman@caveman" --scope user >/dev/null 2>&1 || true'
      else
        run_u "$user" "$home" '"$HOME/.local/bin/claude" plugin marketplace add "JuliusBrussee/caveman" >/dev/null 2>&1 || true'
        run_u "$user" "$home" '"$HOME/.local/bin/claude" plugin install "caveman@caveman" --scope user >/dev/null'
      fi
    else
      if grep -Fq 'context-mode@context-mode' <<<"$plist"; then
        skip "[$user] context-mode confirmed by one fallback plugin-list call"
      else
        run_u "$user" "$home" '"$HOME/.local/bin/claude" plugin marketplace add "mksglu/context-mode" >/dev/null 2>&1 || true'
        run_u "$user" "$home" '"$HOME/.local/bin/claude" plugin install "context-mode@context-mode" --scope user >/dev/null'
      fi
      if grep -Fq 'caveman@caveman' <<<"$plist"; then
        skip "[$user] caveman confirmed by same fallback plugin-list call"
      else
        run_u "$user" "$home" '"$HOME/.local/bin/claude" plugin marketplace add "JuliusBrussee/caveman" >/dev/null 2>&1 || true'
        run_u "$user" "$home" '"$HOME/.local/bin/claude" plugin install "caveman@caveman" --scope user >/dev/null'
      fi
    fi
  fi

  if [[ "$UPDATE" -eq 0 && "$mcp_fast" -eq 1 ]]; then
    skip "[$user] Graft user MCP locally healthy; no Claude MCP runtime call"
  else
    # Only one mcp-get process when local proof is absent.
    local mout=""
    mout="$(run_u "$user" "$home" '"$HOME/.local/bin/claude" mcp get graft 2>/dev/null' || true)"
    if grep -Fq "$home/.local/bin/graft" <<<"$mout" && grep -Fq 'mcp' <<<"$mout"; then
      skip "[$user] Graft MCP confirmed by one fallback mcp-get call"
    else
      run_u "$user" "$home" '"$HOME/.local/bin/claude" mcp remove graft >/dev/null 2>&1 || true'
      run_u "$user" "$home" '"$HOME/.local/bin/claude" mcp add --scope user graft -- "$HOME/.local/bin/graft" mcp >/dev/null'
    fi
  fi

  # Reassert canonical settings after any fallback/update path, then local cleanup.
  repair_plugin_settings_after_cli "$user" "$home"
  cleanup_legacy_mcp_json "$user" "$home"

  # Final cheap local proof. If local proof still fails, surface a real failure
  # instead of paying another runtime startup loop.
  plugin_pair_fast_healthy "$home" || { err "[$user] plugin payload/config local verification failed"; return 1; }
  local_graft_mcp_ok "$home" || { err "[$user] Graft MCP local verification failed"; return 1; }
}

ensure_graph_cache_ignore() {
  local repo="$1" user="$2"
  local f="$repo/.claudeignore"
  local block_ok=0
  if [[ -f "$f" ]] &&
     grep -Fq '# BEGIN CLAUDE-GRAPH-CACHE-IGNORE' "$f" &&
     grep -Fxq 'graph.json' "$f" &&
     grep -Fxq 'graphify-out/' "$f" &&
     grep -Fxq 'graft/' "$f" &&
     grep -Fxq '.claude/mobile-visual-cache/' "$f"; then
    block_ok=1
  fi
  if [[ "$block_ok" -eq 1 ]]; then return 0; fi
  [[ "$VERIFY_ONLY" -eq 0 ]] || return 1
  python3 - "$f" <<'PY' || return 1
import pathlib,re,sys
p=pathlib.Path(sys.argv[1])
s=p.read_text(errors='ignore') if p.exists() else ''
s=re.sub(r'\n?# BEGIN CLAUDE-GRAPH-CACHE-IGNORE\n.*?# END CLAUDE-GRAPH-CACHE-IGNORE\n?', '\n', s, flags=re.S)
block='\n\n# BEGIN CLAUDE-GRAPH-CACHE-IGNORE\ngraph.json\ngraphify-out/\ngraft/\n.claude/mobile-visual-cache/\n# END CLAUDE-GRAPH-CACHE-IGNORE\n'
p.write_text(s.rstrip()+block)
PY
  chown "$user":"$(group_of "$user")" "$f" 2>/dev/null || true
}

cleanup_project_graft_mcp() {
  local repo="$1" user="$2" f="$repo/.mcp.json"
  [[ -f "$f" ]] || return 0
  [[ "$VERIFY_ONLY" -eq 0 ]] || return 0
  python3 - "$f" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
try: c=json.loads(p.read_text())
except Exception as e: raise SystemExit(f"Invalid JSON in {p}: {e}")
m=c.get("mcpServers")
if isinstance(m,dict) and "graft" in m:
    m.pop("graft",None)
    p.write_text(json.dumps(c,indent=2,ensure_ascii=False)+"\n")
PY
  chown "$user":"$(group_of "$user")" "$f" 2>/dev/null || true
}

graft_repo_smoke() {
  local user="$1" home="$2" repo="$3"
  run_u "$user" "$home" "timeout 60 graft ask '__claude_bootstrap_healthcheck__' '$repo' --json >/tmp/graft-smoke.log 2>&1"
}

init_repo() {
  local user="$1" home="$2" repo="$3" gv_cached="${4:-}"
  [[ -d "$repo/.git" || -f "$repo/.git" ]] || return 0
  ensure_graph_cache_ignore "$repo" "$user"
  [[ "$VERIFY_ONLY" -eq 0 ]] || return 0

  # Graphify hook: install only when absent.
  local gh
  gh="$(git -C "$repo" rev-parse --git-path hooks/post-commit 2>/dev/null || true)"
  if [[ -z "$gh" || ! -f "$gh" ]] || ! grep -qi 'graphify' "$gh" 2>/dev/null; then
    run_u "$user" "$home" "cd '$repo' && graphify hook install >/dev/null 2>&1" || true
  fi

  # Fast path: healthy/current Graft repos are not re-initialized or smoke-tested.
  local gv="$gv_cached" mark="$repo/graft/.claude-bootstrap-graft-version"
  if [[ -z "$gv" ]]; then
    gv="$(run_u "$user" "$home" 'graft --version 2>/dev/null | head -1' || true)"
  fi
  local project_mcp=0
  if [[ -f "$repo/.mcp.json" ]] && python3 - "$repo/.mcp.json" <<'PYM' >/dev/null 2>&1
import json, pathlib, sys
c=json.loads(pathlib.Path(sys.argv[1]).read_text())
raise SystemExit(0 if isinstance(c.get("mcpServers"),dict) and "graft" in c["mcpServers"] else 1)
PYM
  then project_mcp=1; fi

  if [[ -n "$gv" && -d "$repo/graft" && -f "$repo/.claude/skills/graft/SKILL.md" && -f "$mark" &&
        "$(cat "$mark" 2>/dev/null || true)" == "$gv" && "$project_mcp" -eq 0 ]]; then
    skip "[$user] repo already wired/current: $repo"
    return 0
  fi

  # Repair Graft-owned hooks/skill only when the repo is missing/stale. Upstream currently
  # has an open bug where --no-mcp can be ignored for Claude Code, so we remove the
  # project-local Graft MCP afterwards and retain one canonical user-scoped MCP.
  run_u "$user" "$home" "timeout 600 graft init '$repo' --agents claude --no-global >/tmp/graft-init.log 2>&1" || \
    warn "[$user] Graft init returned nonzero for $repo; continuing to functional repair"
  cleanup_project_graft_mcp "$repo" "$user" || return 1

  # Exercise the exact local parser/query path used by graft_ask. This catches segfaults
  # that `graft --version` cannot detect. Old graft/ is safe to delete: upstream documents
  # it as a local regenerable cache.
  if ! graft_repo_smoke "$user" "$home" "$repo"; then
    warn "[$user] Graft ask failed/crashed in $repo; rebuilding graft/ from scratch"
    rm -rf -- "$repo/graft"
    if ! run_u "$user" "$home" "timeout 600 graft build '$repo' >/tmp/graft-build.log 2>&1"; then
      run_u "$user" "$home" 'tail -120 /tmp/graft-init.log 2>/dev/null || true; tail -120 /tmp/graft-build.log 2>/dev/null || true'
      return 1
    fi
    if ! graft_repo_smoke "$user" "$home" "$repo"; then
      warn "[$user] Graft still fails after a clean rebuild in $repo"
      run_u "$user" "$home" 'tail -120 /tmp/graft-smoke.log 2>/dev/null || true'
      return 1
    fi
  fi

  local gv
  gv="$(run_u "$user" "$home" 'graft --version 2>/dev/null | head -1' || true)"
  mkdir -p "$repo/graft"
  printf '%s' "$gv" > "$repo/graft/.claude-bootstrap-graft-version"
  chown -R "$user":"$(group_of "$user")" "$repo/graft" 2>/dev/null || true
  run_u "$user" "$home" 'rm -f /tmp/graft-init.log /tmp/graft-build.log /tmp/graft-smoke.log'
}

init_existing_repos_full() {
  local user="$1" home="$2"
  log "[$user] Existing Git repositories"
  local roots=("$home/projects" "$home/Projects" "$home/src" "$home/code")
  local -a repos=()
  local -A seen=()
  local base gitdir repo

  for base in "${roots[@]}"; do
    [[ -d "$base" ]] || continue
    while IFS= read -r -d '' gitdir; do
      repo="${gitdir%/.git}"
      [[ -n "${seen[$repo]:-}" ]] && continue
      seen[$repo]=1
      repos+=("$repo")
    done < <(find "$base" -mindepth 1 -maxdepth 5 -type d -name .git -print0 2>/dev/null)
  done

  local total="${#repos[@]}" i=0
  if [[ "$total" -eq 0 ]]; then
    printf '   [%s repos] none found in standard roots; SessionStart will handle future/other repos\n' "$user"
    return 0
  fi

  printf '   [%s repos] found %s Git repo(s)\n' "$user" "$total"
  local gv_cached
  gv_cached="$(run_u "$user" "$home" 'graft --version 2>/dev/null | head -1' || true)"
  for repo in "${repos[@]}"; do
    i=$((i+1))
    printf '   ↳ [%s repo %02d/%02d] %s\n' "$user" "$i" "$total" "$repo"
    init_repo "$user" "$home" "$repo" "$gv_cached" || warn "[$user] Could not fully initialize Graft in $repo; SessionStart will retry later"
  done
}

init_existing_repos() {
  local user="$1" home="$2"

  if [[ "$VERIFY_ONLY" -eq 0 && "$UPDATE" -eq 0 ]] && repo_scan_marker_valid "$user" "$home"; then
    skip "[$user] existing-repo scan already verified for current Graft version; no filesystem tree scan"
    skip "[$user] new/other repos remain auto-wired by SessionStart when opened"
    return 0
  fi

  init_existing_repos_full "$user" "$home" || return 1

  if [[ "$VERIFY_ONLY" -eq 0 ]]; then
    write_repo_scan_marker "$user" "$home" || return 1
  fi
}

verify_settings() {
  local home="$1"
  python3 - "$home/.claude/settings.json" "$AUTO_COMPACT_WINDOW" <<'PY'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1]); want=sys.argv[2]
try:
    c=json.loads(p.read_text())
except Exception as e:
    print(f"settings JSON invalid: {e}", file=sys.stderr); raise SystemExit(1)
checks=[
    (c.get('autoMemoryEnabled') is True, 'autoMemoryEnabled=true'),
    (c.get('model')=='sonnet', 'model=sonnet'),
    (c.get('effortLevel')=='medium', 'effortLevel=medium'),
    (c.get('modelSettings',{}).get('claude-sonnet-5',{}).get('effortLevel')=='medium', 'modelSettings.claude-sonnet-5.effortLevel=medium'),
    (str(c.get('env',{}).get('CLAUDE_CODE_AUTO_COMPACT_WINDOW'))==want, f'CLAUDE_CODE_AUTO_COMPACT_WINDOW={want}'),
    (str(c.get('env',{}).get('ENABLE_TOOL_SEARCH','')).lower()=='true', 'ENABLE_TOOL_SEARCH=true'),
    (str(c.get('env',{}).get('CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH'))=='2', 'CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=2'),
    (str(c.get('env',{}).get('CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS'))=='2', 'CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=2'),
    (c.get('enabledPlugins',{}).get('context-mode@context-mode') is True, 'context-mode plugin enabled'),
    (c.get('enabledPlugins',{}).get('caveman@caveman') is True, 'caveman plugin enabled'),
    (c.get('extraKnownMarketplaces',{}).get('context-mode',{}).get('autoUpdate') is True, 'context-mode marketplace autoUpdate=true'),
    (c.get('extraKnownMarketplaces',{}).get('caveman',{}).get('autoUpdate') is True, 'caveman marketplace autoUpdate=true'),
]
failed=[name for ok,name in checks if not ok]
if failed:
    for name in failed: print(f"settings check failed: {name}", file=sys.stderr)
    raise SystemExit(1)
PY
}


verify_user_fast() {
  local user="$1" home="$2" fail=0
  log "[$user] FAST LOCAL VERIFICATION"

  # Earlier stages already executed version/health checks for Claude, Graphify,
  # Graft and the visual helpers. Do not launch them a second time here.
  if [[ -x "$home/.local/bin/claude" ]]; then ok "[$user] Claude executable"; else err "[$user] Claude executable missing"; fail=1; fi
  if run_u "$user" "$home" 'command -v graphify >/dev/null 2>&1'; then ok "[$user] Graphify executable"; else err "[$user] Graphify missing"; fail=1; fi
  if run_u "$user" "$home" 'command -v graft >/dev/null 2>&1'; then ok "[$user] Graft executable"; else err "[$user] Graft missing"; fail=1; fi

  if verify_settings "$home"; then ok "[$user] settings + model/effort + memory/compact + plugins"; else err "[$user] settings validation failed"; fail=1; fi

  if [[ -x "$home/.claude/hooks/ensure-project-context.sh" ]] &&
     grep -Fq 'CLAUDE-SMART-HOOK-SCHEMA=4.9.0-1' "$home/.claude/hooks/ensure-project-context.sh"; then
    ok "[$user] SessionStart hook current"
  else
    err "[$user] SessionStart hook missing/stale"; fail=1
  fi

  if grep -q 'BEGIN CLAUDE-CONTEXT-GLOBAL' "$home/.claude/CLAUDE.md" 2>/dev/null &&
     grep -q 'Usage-limit best practices (automatic)' "$home/.claude/CLAUDE.md" 2>/dev/null; then
    ok "[$user] global continuity/usage policy"
  else
    err "[$user] global CLAUDE.md policy missing"; fail=1
  fi

  if plugin_pair_fast_healthy "$home"; then
    ok "[$user] Context Mode + Caveman local payload/config"
  else
    err "[$user] plugin local payload/config missing"; fail=1
  fi

  if local_graft_mcp_ok "$home"; then
    ok "[$user] Graft MCP local config"
  else
    err "[$user] Graft MCP local config missing/incorrect"; fail=1
  fi

  if python3 - "$home/.claude.json" <<'PYFAST' >/dev/null 2>&1
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
if not p.exists(): raise SystemExit(0)
c=json.loads(p.read_text())
bad={"caveman","caveman-shrink","caveman-proxy","context-mode"}
def has_bad(m):
    return isinstance(m,dict) and bool(bad.intersection(m))
if has_bad(c.get("mcpServers")): raise SystemExit(1)
for pdata in (c.get("projects") or {}).values():
    if isinstance(pdata,dict) and has_bad(pdata.get("mcpServers")): raise SystemExit(1)
raise SystemExit(0)
PYFAST
  then
    ok "[$user] no legacy standalone Context/Caveman MCP"
  else
    err "[$user] legacy standalone Context/Caveman MCP remains"; fail=1
  fi

  if [[ -f "$home/.claude/tools/project_state.py" ]] &&
     grep -Fq 'payload.get("reason")' "$home/.claude/tools/project_state.py" &&
     grep -Fq 'payload.get("why")' "$home/.claude/tools/project_state.py" &&
     [[ -f "$home/.claude/skills/mobile-pixel-clone/SKILL.md" ]] &&
     [[ -f "$home/.claude/agents/mobile-ui-implementer.md" ]] &&
     [[ -f "$home/.claude/agents/mobile-ui-qa-opus.md" ]] &&
     [[ -x "$home/.local/bin/claude-mobile-visual" ]] &&
     [[ -x "$home/.local/bin/claude-project-state" ]]; then
    ok "[$user] mobile visual/project-state files"
  else
    err "[$user] mobile visual/project-state files missing"; fail=1
  fi

  skip "[$user] expensive plugin-list/MCP live probes skipped; use --verify-only for deep health"
  return "$fail"
}

verify_user() {
  local user="$1" home="$2" fail=0 out
  log "[$user] HARD VERIFICATION"

  local node_v
  node_v="$(run_u "$user" "$home" 'node -p "process.versions.node"' 2>/dev/null || true)"
  if [[ -n "$node_v" ]] && version_ge "$node_v" "$MIN_NODE_VERSION"; then ok "[$user] Node v$node_v >= $MIN_NODE_VERSION"; else err "[$user] Node runtime ${node_v:-MISSING} < $MIN_NODE_VERSION"; fail=1; fi
  if run_u "$user" "$home" 'test -x "$HOME/.local/bin/claude" && "$HOME/.local/bin/claude" --version'; then ok "[$user] Claude"; else err "[$user] Claude missing/broken"; fail=1; fi
  if run_u "$user" "$home" 'graphify --version >/dev/null && test -f "$HOME/.claude/skills/graphify/SKILL.md"'; then ok "[$user] Graphify + skill"; else err "[$user] Graphify/skill missing"; fail=1; fi
  if run_u "$user" "$home" 'graft --version >/dev/null'; then ok "[$user] Graft"; else err "[$user] Graft broken"; fail=1; fi
  if run_u "$user" "$home" "grep -Fq 'payload.get(\"reason\")' \"\$HOME/.claude/tools/project_state.py\" && grep -Fq 'payload.get(\"why\")' \"\$HOME/.claude/tools/project_state.py\""; then ok "[$user] project-state decision rationale aliases"; else err "[$user] project-state reason/why alias support missing"; fail=1; fi
  if run_u "$user" "$home" 'test -f "$HOME/.claude/skills/mobile-pixel-clone/SKILL.md" && test -f "$HOME/.claude/skills/google-android-testing-setup/SKILL.md" && test -f "$HOME/.claude/skills/google-android-edge-to-edge/SKILL.md" && test -f "$HOME/.claude/agents/mobile-ui-implementer.md" && test -f "$HOME/.claude/agents/mobile-ui-qa-opus.md" && grep -q "model: sonnet" "$HOME/.claude/agents/mobile-ui-implementer.md" && grep -q "effort: high" "$HOME/.claude/agents/mobile-ui-implementer.md" && grep -q "model: opus" "$HOME/.claude/agents/mobile-ui-qa-opus.md" && grep -q "effort: high" "$HOME/.claude/agents/mobile-ui-qa-opus.md" && ! grep -Eq "^(model|effort):" "$HOME/.claude/skills/mobile-pixel-clone/SKILL.md" && test -x "$HOME/.local/bin/claude-android" && test -x "$HOME/.local/bin/claude-mobile-visual" && test -x "$HOME/.local/bin/claude-project-state" && claude-mobile-visual --help >/dev/null && claude-project-state --help >/dev/null'; then ok "[$user] cache-safe mobile design + visual dedup + project recall stack"; else err "[$user] mobile design/project recall stack missing/broken"; fail=1; fi
  if verify_settings "$home"; then ok "[$user] settings + memory + compact + tool-search + model/effort + plugins"; else err "[$user] settings validation failed"; fail=1; fi
  if [[ -x "$home/.claude/hooks/ensure-project-context.sh" ]]; then ok "[$user] SessionStart bootstrap hook"; else err "[$user] SessionStart hook missing"; fail=1; fi
  if grep -q 'BEGIN CLAUDE-CONTEXT-GLOBAL' "$home/.claude/CLAUDE.md" 2>/dev/null; then ok "[$user] global CLAUDE.md policy"; else err "[$user] global CLAUDE.md policy missing"; fail=1; fi
  if grep -q 'Usage-limit best practices (automatic)' "$home/.claude/CLAUDE.md" 2>/dev/null \
     && grep -q 'Batch closely related requests into one bounded implementation pass' "$home/.claude/CLAUDE.md" 2>/dev/null \
     && grep -q 'Never ask the user to repeat text, re-upload an image' "$home/.claude/CLAUDE.md" 2>/dev/null; then
    ok "[$user] Anthropic-style usage-limit guardrails"
  else
    err "[$user] usage-limit guardrails missing"
    fail=1
  fi

  out="$(run_u "$user" "$home" '"$HOME/.local/bin/claude" plugin list 2>/dev/null' || true)"
  if grep -Fq 'context-mode@context-mode' <<<"$out"; then ok "[$user] Context Mode plugin"; else err "[$user] Context Mode plugin missing"; fail=1; fi
  if grep -Fq 'caveman@caveman' <<<"$out"; then ok "[$user] Caveman plugin"; else err "[$user] Caveman plugin missing"; fail=1; fi

  if [[ "$VERIFY_ONLY" -eq 1 || "$UPDATE" -eq 1 ]]; then
    # Deep live MCP probe is intentionally reserved for explicit verification/update.
    # It can launch/connect plugin MCP runtimes and is much slower than local config checks.
    out="$(run_u "$user" "$home" '"$HOME/.local/bin/claude" mcp list 2>/dev/null' || true)"
    if grep -Ei 'context-mode.*(Connected|✔)' <<<"$out" >/dev/null; then ok "[$user] Context Mode MCP connected"; else err "[$user] Context Mode MCP not connected"; fail=1; fi
    if grep -Ei '^graft:.*(Connected|✔)' <<<"$out" >/dev/null; then ok "[$user] Graft MCP connected"; else err "[$user] Graft MCP not connected"; fail=1; fi
    if grep -Ei '^(caveman|caveman-shrink|caveman-proxy):' <<<"$out" >/dev/null; then err "[$user] legacy standalone Caveman MCP still present"; fail=1; else ok "[$user] no duplicate Caveman input proxy"; fi
  else
    # Fast local verification for normal SMART-REPAIR reruns: no server connection/startup.
    out="$(run_u "$user" "$home" '"$HOME/.local/bin/claude" mcp get graft 2>/dev/null' || true)"
    if grep -Fq "$home/.local/bin/graft" <<<"$out" && grep -Fq 'mcp' <<<"$out"; then
      ok "[$user] Graft MCP config"
    else
      err "[$user] Graft MCP config missing/incorrect"; fail=1
    fi
    if python3 - "$home/.claude.json" <<'PYFAST' >/dev/null 2>&1
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
if not p.exists(): raise SystemExit(0)
c=json.loads(p.read_text())
bad={"caveman","caveman-shrink","caveman-proxy"}
def has_bad(m):
    return isinstance(m,dict) and bool(bad.intersection(m))
if has_bad(c.get("mcpServers")): raise SystemExit(1)
for pdata in (c.get("projects") or {}).values():
    if isinstance(pdata,dict) and has_bad(pdata.get("mcpServers")): raise SystemExit(1)
raise SystemExit(0)
PYFAST
    then ok "[$user] no duplicate Caveman input proxy (local config)"; else err "[$user] legacy standalone Caveman MCP still present"; fail=1; fi
    skip "[$user] live MCP connection probe skipped in fast SMART-REPAIR; use --verify-only for deep connection check"
  fi

  local dup=0 base mf
  for base in "$home/projects" "$home/Projects" "$home/src" "$home/code"; do
    [[ -d "$base" ]] || continue
    while IFS= read -r -d '' mf; do
      if python3 - "$mf" <<'PYDUP'
import json,sys
try: c=json.load(open(sys.argv[1]))
except Exception: raise SystemExit(1)
raise SystemExit(0 if isinstance(c.get('mcpServers'),dict) and 'graft' in c['mcpServers'] else 1)
PYDUP
      then
        err "[$user] duplicate project-local Graft MCP remains: $mf"; dup=1
      fi
    done < <(find "$base" -maxdepth 6 -type f -name .mcp.json -print0 2>/dev/null)
  done
  if [[ "$dup" -eq 0 ]]; then ok "[$user] no duplicate project-local Graft MCP"; else fail=1; fi

  return "$fail"
}

FAIL=0

# Machine-wide prerequisites/defaults before per-user installation.
printf '\n\033[1;35m▶ [GLOBAL 01/02] System Node.js >= %s\033[0m\n' "$MIN_NODE_VERSION"
if ! ensure_node22; then FAIL=1; else printf '\033[1;32m✓ [GLOBAL 01/02] DONE: System Node.js\033[0m\n'; fi
if command -v node >/dev/null 2>&1; then
  NODE_NOW="$(node --version | sed 's/^v//')"
  if version_ge "$NODE_NOW" "$MIN_NODE_VERSION"; then ok "Node runtime final: v$NODE_NOW"; else FAIL=1; fi
fi

printf '\n\033[1;35m▶ [GLOBAL 02/02] Claude startup defaults: Sonnet + medium\033[0m\n'
if ! ensure_managed_model_defaults; then
  FAIL=1
else
  printf '\033[1;32m✓ [GLOBAL 02/02] DONE: managed Sonnet/medium defaults\033[0m\n'
fi

for user in "${USERS[@]}"; do
  home="$(home_of "$user")"
  [[ -n "$home" && -d "$home" ]] || { warn "No home for $user; skipping"; continue; }

  log "===== USER: $user ($home) ====="
  if [[ "$VERIFY_ONLY" -eq 0 ]]; then
    mkdir -p "$home/.local/bin" "$home/.claude"
    chown "$user":"$(group_of "$user")" "$home/.local" "$home/.local/bin" "$home/.claude" 2>/dev/null || true
    append_path_block "$user" "$home"
  fi

  TOTAL_STEPS=11
  step_run "$user" 1 "$TOTAL_STEPS" "Claude Code native (smart)" install_claude_latest "$user" "$home"
  step_run "$user" 2 "$TOTAL_STEPS" "Graphify global skill/CLI (smart)" install_graphify "$user" "$home"
  step_run "$user" 3 "$TOTAL_STEPS" "Graft global CLI (smart)" install_graft "$user" "$home"
  step_run "$user" 4 "$TOTAL_STEPS" "Mobile pixel-clone skills + local visual tooling" install_mobile_design_stack "$user" "$home"

  if [[ "$VERIFY_ONLY" -eq 0 ]]; then
    step_run "$user" 5 "$TOTAL_STEPS" "SessionStart auto-bootstrap hook" write_repo_bootstrap_hook "$user" "$home"
    step_run "$user" 6 "$TOTAL_STEPS" "Global settings + memory/compact + quota policy" merge_settings "$user" "$home"
    step_run "$user" 7 "$TOTAL_STEPS" "Global CLAUDE.md continuity + visual parity policy" merge_global_claude_md "$user" "$home"
    step_run "$user" 8 "$TOTAL_STEPS" "Legacy MCP cleanup" cleanup_legacy_mcp_json "$user" "$home"
  else
    printf '\nINFO: [%s 05-08/%02d] verify-only: configuration write steps skipped\n' "$user" "$TOTAL_STEPS"
  fi

  step_run "$user" 9 "$TOTAL_STEPS" "Context Mode + Caveman plugins + Graft MCP (smart)" install_plugins_and_graft_mcp "$user" "$home"
  step_run "$user" 10 "$TOTAL_STEPS" "Existing Git repos / Graft wiring (smart)" init_existing_repos "$user" "$home"
  if [[ "$VERIFY_ONLY" -eq 1 || "$UPDATE" -eq 1 ]]; then
    step_run "$user" 11 "$TOTAL_STEPS" "Deep verification" verify_user "$user" "$home"
  else
    step_run "$user" 11 "$TOTAL_STEPS" "Fast local verification" verify_user_fast "$user" "$home"
  fi
done

printf '\n============================================================\n'
if [[ "$FAIL" -eq 0 ]]; then
  printf '\033[1;32mALL HARD CHECKS PASSED (bootstrap v%s)\033[0m\n' "$BOOTSTRAP_VERSION"
else
  printf '\033[1;31mONE OR MORE HARD CHECKS FAILED (bootstrap v%s)\033[0m\n' "$BOOTSTRAP_VERSION"
fi
cat <<EOF

Automatic from now on:
  - Target users (${USERS_CSV}) use user-global Claude Code configuration.
  - Claude native CLI uses its normal update channel; this bootstrap repairs it when broken and refreshes it only with --update.
  - Node >= ${MIN_NODE_VERSION} is enforced before Graft installation.
  - Graft installs only after Node >= ${MIN_NODE_VERSION}; engine mismatches are hard failures, not warnings.
  - Graft's known tree-sitter-swift peer-metadata conflict is handled with the upstream-compatible npm peer policy.
  - Context Mode is global, auto-updating, and owns large-output/history virtualization.
  - Caveman plugin is global for concise responses; standalone Caveman proxy/MCP is removed.
  - Auto Memory is enabled; auto-compaction uses a ${AUTO_COMPACT_WINDOW}-token calculation window.
  - Main NEW sessions default to Sonnet + medium at machine-managed precedence, and the user Sonnet-5 saved effort is normalized to medium. No manual Desktop/CLI effort toggle is required after bootstrap.
  - Existing already-open sessions keep their explicit/session-loaded effort until they end; start a NEW Code session to pick up the repaired default without causing a mid-session cache reset.
  - Mobile visual work still delegates to Sonnet/high, with at most one narrow Opus/high QA escalation when measured progress stalls; we deliberately do NOT set CLAUDE_CODE_EFFORT_LEVEL globally because it would suppress those agent-level high-effort overrides.
  - MCP Tool Search stays enabled so schemas remain deferred/on-demand.
  - Existing repos under ~/projects, ~/Projects, ~/src, ~/code are checked now; already-current repos are skipped.
  - Any other/new Git repo is initialized automatically on Claude SessionStart.
  - Graphify is installed globally and its installer output is silenced. You do NOT need to type '/graphify .'.
    Claude is instructed to create/query Graphify automatically only when useful.
  - mobile-pixel-clone is a small global orchestrator skill; it does not switch the main model/effort.
  - mobile-ui-implementer (Sonnet/high) owns render/diff loops; mobile-ui-qa-opus (Opus/high) is a one-shot targeted escalation.
  - Subagent nesting is capped at 2 and concurrent subagents at 2 to prevent token/usage spikes.
  - Graphify installs a code-only post-commit hook per repo; code graph refresh is local/no-LLM, while docs/images remain on-demand to avoid token spend.
  - ADB automation is local CLI (no extra MCP); selected Google Android screenshot-testing + edge-to-edge skills are available on demand.
  - claude-mobile-visual does local image info/crop/diff and returns compact JSON, avoiding repeated full-image analysis.
  - claude-project-state stores compact solved-issue/decision recall and content-addressed visual references under ~/.claude/project-state/ (outside repos, no git/prompt-cache churn).
  - Repeated local reference images are SHA-256 checked first; exact matches reuse stored specs/assets instead of paying for full vision analysis again. Near matches are only hints, never silently treated as identical.
  - Confirmed resolved issues and durable decisions (including rationale/reason/why) are compactly upserted for future conversations; recall search runs only when the prompt/symptom suggests prior work, not on every turn.
  - Anthropic-style usage-limit guardrails are global: reuse cached/local references before re-upload/re-analysis, batch related work, avoid unnecessary clarification/tool/research loops, and keep heavy outputs out of the parent conversation.
  - graph.json, graphify-out/, graft/, and mobile visual cache are added to each repo's .claudeignore managed block
    to avoid unnecessary prompt-cache invalidation/context churn.

SMART BOOTSTRAP BEHAVIOR:
  - Default run is offline-first SMART-REPAIR: healthy Claude Code, Graphify, Graft, plugins,
    vendor tools, visual Python deps, Graft MCP, settings, hooks, and repo wiring are SKIPPED.
  - Default reruns do NOT call the Claude installer, npm registry, uv upgrade, git fetch,
    plugin update, or Graft repo re-init merely to check for "latest".
  - Use --update only when you intentionally want fresh package/plugin/vendor versions.
  - Missing/broken required components are still repaired automatically, including a network install when needed.
  - Existing repos with the current Graft marker are not re-initialized or smoke-tested on every bootstrap run.
  - After one successful repo inventory for the current Graft version, ordinary reruns skip the full ~/projects tree scan; new repos are still auto-wired by SessionStart when opened.
  - Ordinary SMART-REPAIR verifies healthy plugins/MCP from local config/payloads without launching Claude's plugin/MCP runtime twice per user. Use --verify-only for deep live probes.

Open Claude sessions are never killed by this script (to avoid losing active work).
They may continue with their already-loaded runtime until that session ends; every NEW CLI/Desktop Code
session automatically reads the repaired global configuration. No 'read CLAUDE.md', '/compact', or
'/graphify .' reminder is required from you.

Progress output shows [user NN/11] for every stage; elapsed times use a monotonic counter so system clock/NTP changes cannot create negative durations.

This bootstrap reduces avoidable token/usage consumption but cannot remove Claude plan five-hour/weekly limits.
A one-time ~17s first-Bash/PreToolUse cold start may occur in a fresh Claude session; measured subsequent Bash/Graft overhead is ~0.3-0.4s, so the bootstrap intentionally does not add a warm-up that would merely move that cost to every session start.
For Claude Desktop Code, start a NEW Code session after this production bootstrap so the new user-level CLAUDE.md
and machine-managed Sonnet/medium startup defaults are loaded cleanly. Do NOT manually change an old Sonnet/high
session just to test the bootstrap; switching effort mid-session can invalidate prompt-cache reuse. A full app restart is only needed if an already-loaded MCP/plugin
process is dead/stale or Claude Desktop explicitly asks you to reload/restart.

Target users:
  - Use --users root,alice,bob for an explicit comma-separated list.
  - If omitted, the default is root plus SUDO_USER when available.
  - CLAUDE_BOOTSTRAP_USERS provides the same list for non-interactive automation.

Read-only DEEP health check anytime (includes live MCP connection probes):
  sudo $0 --verify-only

Intentional package/plugin/vendor refresh:
  sudo $0 --update

Full log:
  $LOG_FILE
============================================================
EOF

exit "$FAIL"
