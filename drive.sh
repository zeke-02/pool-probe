#!/usr/bin/env bash
# Feeds a deployed pool-probe enclave from this machine: a dev fount-coordinator dials the runner's
# link (unattested at both ends) and sends the runner smoke jobs one at a time, then PDF jobs 4 and
# 8 at once on separate workers. Every job's exit, time, memory peak and OOM kills are in the
# coordinator's log, which this prints at the end.
#
#   RUNNER=https://<domain> drive.sh
set -euo pipefail

RUNNER="${RUNNER:?set RUNNER to https://<enclave domain>}"
BROKER_REPO="${BROKER_REPO:-$HOME/Desktop/code/fount-broker}"
ROOT="${FOUNT_ROOT:-$HOME/Desktop/code/fount}"
FIXTURES="$ROOT/src-tauri/crates/fount-runner/tests/fixtures"
WORK="$(mktemp -d)"
API=127.0.0.1:8792
COORD_PID=
cleanup() { [ -n "$COORD_PID" ] && kill "$COORD_PID" 2> /dev/null || true; }
trap cleanup EXIT

(cd "$BROKER_REPO" && go build -tags dev -o "$WORK/fount-coordinator" ./cmd/fount-coordinator)
"$WORK/fount-coordinator" --dir "$WORK/coord" --listen "$API" --runner-addr "$RUNNER" --runner-repo unattested \
  --runners 1 --slots 8 > "$WORK/coordinator.log" 2>&1 &
COORD_PID=$!
until [ "$(curl -s -o /dev/null -w '%{http_code}' "http://$API/v0/jobs/none")" != 000 ]; do sleep 0.2; done
echo "coordinator log: $WORK/coordinator.log"

worker() { curl -sf -X POST "http://$API/v0/workers" -d "{\"account\":\"acct_$1\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'; }
# put <worker> <file> <path>
put() { curl -sf -X PUT --data-binary "@$2" "http://$API/v0/workers/$1/root/$3" > /dev/null; }
# putText <worker> <path> <text>
putText() { printf '%s' "$3" | curl -sf -X PUT --data-binary @- "http://$API/v0/workers/$1/root/$2" > /dev/null; }
# enqueue <worker> <fixture>: prints the job id.
enqueue() {
  python3 - "$FIXTURES/$2" <<'PY' | curl -sf -X POST "http://$API/v0/workers/$1/jobs" -d @- | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
import json, sys
f = json.load(open(sys.argv[1]))
print(json.dumps({"threadId": "t1", "sessionId": f["sessionId"], "instruction": f["prompt"], "config": f["config"], "script": f["script"]}))
PY
}
# wait_job <job>: prints the final state.
wait_job() {
  local state
  while :; do
    state=$(curl -sf "http://$API/v0/jobs/$1")
    case "$state" in *'"state":"queued"'*|*'"state":"running"'*) sleep 1 ;; *) echo "$state"; return ;; esac
  done
}
# said <worker> <text>: the worker's transcripts hold text.
said() {
  local p
  for p in $(curl -sf "http://$API/v0/workers/$1/files?prefix=fount/conversations/" | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["paths"]))'); do
    curl -sf "http://$API/v0/workers/$1/files/$p" | grep -qF "$2" && return 0
  done
  echo "  MISSING in transcript: $2"; return 1
}

FAIL=0
W=$(worker smoke)
run() {
  local started=$(date +%s) job state
  job=$(enqueue "$W" "$1")
  state=$(wait_job "$job")
  echo "$1: $(( $(date +%s) - started ))s wall, $(echo "$state" | python3 -c 'import json,sys; j=json.load(sys.stdin); print(j.get("state"), j.get("error",""))')"
  shift
  local t; for t in "$@"; do said "$W" "$t" || FAIL=1; done
}

echo "== the nine smoke jobs, one at a time"
run write-job.json
run python-job.json 'rows: 5'
run confine-job.json 'socket-inet: denied' 'write-workspace: allowed'
put "$W" "$ROOT/e2e/fixtures/Blank.xlsx" Blank.xlsx
run xlsx-job.json 'B1 = 42'
put "$W" "$ROOT/e2e/fixtures/notes-visibility.docx" notes-visibility.docx
run docx-job.json 'footnote #f1: Prepared per SEC guidance.'
put "$W" "$ROOT/e2e/fixtures/runner-memo.pdf" runner-memo.pdf
run pdf-job.json 'The runner read page two of this memo.'
putText "$W" data/sales.csv $'region,amount\nNorth,120\nSouth,80\n'
putText "$W" pages/about.html $'<html><body><h1>About us</h1><p>The quarterly total was 200.</p></body></html>\n'
putText "$W" mail/letter.eml $'From: ana@example.com\nTo: ops@example.com\nSubject: Q3 numbers\n\nThe letter body says hello.\n'
run reads-job.json 'quarterly total' 'Q3 numbers' 'The letter body says hello.'
putText "$W" nb/analysis.ipynb '{"cells": [{"cell_type": "markdown", "metadata": {}, "source": ["# Quarterly check"]}, {"cell_type": "code", "execution_count": 1, "metadata": {}, "source": ["total = 120 + 80\n", "print(total)"], "outputs": [{"output_type": "stream", "name": "stdout", "text": ["200\n"]}]}], "metadata": {}, "nbformat": 4, "nbformat_minor": 5}'
putText "$W" report.typ $'#set page(paper: "a6")\n= Report\n#include "part.typ"\n#pagebreak()\nThe end.\n'
putText "$W" part.typ $'The quarterly total was 200.\n'
run typst-notebook-job.json 'Quarterly check' 'Compilation successful' 'Pages: 2'
putText "$W" mail/governance.md $'# Governance\n\nThe directors convene on the first Tuesday of each quarter, at 9am in Room 4.\n'
run search-job.json '/work/mail/governance.md'

# burst <n>: n workers, one PDF job each, all at once.
burst() {
  local n=$1 i w ws=() jobs=() started
  for i in $(seq 1 "$n"); do w=$(worker "burst${n}_$i"); ws+=("$w"); put "$w" "$ROOT/e2e/fixtures/runner-memo.pdf" runner-memo.pdf; done
  started=$(date +%s)
  for w in "${ws[@]}"; do jobs+=("$(enqueue "$w" pdf-job.json)"); done
  for j in "${jobs[@]}"; do echo "  $(wait_job "$j" | python3 -c 'import json,sys; j=json.load(sys.stdin); print(j.get("state"), j.get("error",""))')"; done
  echo "$n PDF jobs at once: $(( $(date +%s) - started ))s wall"
}
echo "== PDF jobs at once"
burst 4
burst 8

echo "== per job, from the coordinator's log"
grep -E "runner: |job .*:" "$WORK/coordinator.log" || true
[ "$FAIL" = 0 ] && echo "all checks passed" || { echo "some checks failed"; exit 1; }
