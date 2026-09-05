#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/claude-smart-bootstrap.sh"

echo "[1/6] Bash syntax"
bash -n "$SCRIPT"

echo "[2/6] Embedded Python syntax"
python3 - "$SCRIPT" <<'PY'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1])
lines=p.read_text().splitlines()
count=0
for i,line in enumerate(lines):
    m=re.search(r"<<'([A-Za-z0-9_]+)'", line)
    if not m or "python3" not in line:
        continue
    tag=m.group(1); buf=[]; j=i+1
    while j < len(lines) and lines[j] != tag:
        buf.append(lines[j]); j+=1
    if j >= len(lines):
        raise SystemExit(f"missing heredoc terminator {tag} after line {i+1}")
    compile("\n".join(buf)+"\n", f"{p.name}:{i+1}:{tag}", "exec")
    count += 1
print(f"compiled {count} embedded Python blocks")
PY

echo "[3/6] Public multi-user interface"
grep -Fq -- '--users USER1,USER2' "$SCRIPT"
grep -Fq 'CLAUDE_BOOTSTRAP_USERS' "$SCRIPT"
grep -Fq 'SUDO_USER' "$SCRIPT"

echo "[4/6] No private hard-coded user list"
if grep -Eq 'USERS=\(root[[:space:]]+[A-Za-z0-9_.-]+\)' "$SCRIPT"; then
  echo "Found a hard-coded root+private-user USERS array" >&2
  exit 1
fi

echo "[5/6] Smart-mode markers"
grep -Fq 'SMART-REPAIR' "$SCRIPT"
grep -Fq 'no installer/network call' "$SCRIPT"
grep -Fq 'no Claude plugin runtime call' "$SCRIPT"
grep -Fq 'no Claude MCP runtime call' "$SCRIPT"
grep -Fq 'no filesystem tree scan' "$SCRIPT"

echo "[6/6] Docs/evidence"
test -f "$ROOT/docs/TEST-RESULTS.md"
test -f "$ROOT/docs/test-results/measured-results.json"
test -f "$ROOT/docs/test-results/validation-matrix.svg"

echo "STATIC CHECKS PASSED"
