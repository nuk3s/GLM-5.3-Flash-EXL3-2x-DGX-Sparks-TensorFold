#!/bin/bash
# glm53-watchdog.sh: one tick of the GLM-5.3 watchdog (glm53-watchdog.timer, every 2 min, as GLM_USER on spark1).
# Installed to $HOME/glm53/bin/ (docs/operations.md). Added 2026-11-02 for the GLM-5.3 cutover. It is
# a watchdog adapted to the GLM kit's defaults:
# the kit does not exit on a broken rank pair (TF_GLM_EXIT_ON_BROKEN=0) or on a stuck step
# (TF_GLM_MULTI_WATCHDOG_EXIT=0), so this watchdog reads /health's "ok" and "iteration_s" and restarts for them.
#
# systemd restarts glm53-serve when start.sh exits (rank 0 ended, or start.sh's foreground watcher saw rank 1 end).
# This watchdog covers what systemd cannot see: an engine that runs but cannot serve. Rules:
#   1. glm53-serve not enabled: nothing (GLM is not deployed).
#   2. ~/glm53/state/HOLD present (rollback, or the operator): nothing.
#   3. Grace: no probe and no restart for 40 min (GRACE_S 2400) after the last start. The start is the newer of the
#      stamp that glm53-serve's ExecStartPre writes at every start and this watchdog's own last restart. Each rank
#      reads its own NVMe copy of the checkpoint (local.sh: WORKER_WEIGHTS=copy), so a TP=3 start takes 2.5 to 6
#      min, and the first start on a node also builds the kernels (~5 min). The 40 min date from loads over NFS
#      (10-25 min) and keep a wide margin.
#   4. Unit state: "failed" means systemd gave up (start limit, or the ExecStartPre refused): no restart here, ntfy
#      once an hour, the operator decides. "inactive" means a stop by hand: nothing. A pending systemd auto-restart:
#      nothing. Still loading after the grace counts as a failed tick.
#   5. Probe: GET /health (10 s). Not 200 = a failed tick. "ok": false (the broken latch: every request fails until a
#      restart) = restart now (FAILS_MAX does not apply; the hourly cap does). iteration_s over STALL_S (360: the
#      kit's 300 s stack report plus a tick) = a failed tick. A rank container not running on spark1 or on spark2 (when
#      spark2 answers ssh) = a failed tick. When no request is in flight (requests_running 0), also one tiny
#      non-streaming chat (8 tokens, thinking off) with a 120 s timeout; no 200 or an empty reply = a failed tick.
#      A busy engine gets /health only.
#   6. 2 failed ticks in a row (FAILS_MAX): `systemctl reset-failed` (the unit's start-limit counter: the
#      watchdog's own cap below bounds its restarts) and `systemctl restart --no-block glm53-serve`, at most 3
#      restarts in any hour. A 4th is not done: the tick logs HOLD and sends ntfy once an hour, until the oldest restart is an hour old.
# Every tick writes one line to the journal (stdout) and to ~/glm53/state/watchdog.log, and rewrites
# ~/glm53/state/watchdog.state (key=value).
set -uo pipefail
# hosts.conf beside this script (GLM_HOSTS_CONF names another file) sets this cluster's values; without it the
# defaults below apply. hosts.conf.example lists every name.
_hc=${GLM_HOSTS_CONF:-$(dirname "$(readlink -f "$0")")/hosts.conf}
[ -z "${GLM_HOSTS_CONF:-}" ] || [ -r "$_hc" ] || { echo "glm53-watchdog: cannot read GLM_HOSTS_CONF=$_hc" >&2; exit 1; }
[ ! -r "$_hc" ] || bash -n "$_hc" 2>/dev/null || { echo "glm53-watchdog: syntax error in $_hc" >&2; exit 1; }
# shellcheck source=/dev/null
[ -r "$_hc" ] && . "$_hc"
GLM_HOME="${GLM_HOME:-$HOME/glm53}"
ST="$GLM_HOME/state"
UNIT="${GLM_UNIT:-glm53-serve.service}"
PORT="${GLM_PORT:-8888}"
SERVED="${GLM_SERVED:-GLM-5.3-Flash-EXL3}"
CTR="${GLM_CONTAINER:-glm53-flash-tf}"
WORKER="${GLM_WORKER:-user@192.0.2.180}"
# TP=3 (2026-11-05): spark3 is rank 2. rank_down() checks it when the RUNNING engine is TP=3. Before 2026-11-06 a
# dead rank 2 showed only as a stalled step or a failed probe. The TP comes from state/tp, which glm53-prestart.sh
# writes at each start, so a local.sh edit staged while the engine serves cannot turn a healthy TP=2 engine into a
# "rank 2 down" restart (review 2026-11-06). Until the first start after this change, it falls back to local.sh.
WORKER2="${GLM_WORKER2:-user@192.0.2.216}"
_tp=$(sed -n 's/^\([0-9]\)$/\1/p' "$ST/tp" 2>/dev/null | tail -1)
[ -n "$_tp" ] || _tp=$(sed -n 's/^TP=\([0-9]\).*/\1/p' "${GLM_LOCAL_SH:-$GLM_HOME/kit/scripts/local.sh}" 2>/dev/null | tail -1)
TP="${_tp:-2}"
GRACE_S="${GLM_WD_GRACE_S:-2400}"
STALL_S="${GLM_WD_STALL_S:-360}"
FAILS_MAX="${GLM_WD_FAILS_MAX:-2}"
RESTARTS_MAX=3
HOUR=3600
HEALTH_S=10
PROBE_S=120
NTFY_BASE=${NTFY_BASE-}      # empty (the default): no ntfy message at all
NTFY="${NTFY-${NTFY_BASE:+$NTFY_BASE/${NTFY_TOPIC_CRIT:-alerts-critical}}}"
# GLM_PRINT_CONFIG=1: print the values this run would use, then exit (tests/test_hosts_conf.sh)
if [ "${GLM_PRINT_CONFIG:-}" = 1 ]; then
  for _v in GLM_HOME ST UNIT PORT SERVED CTR WORKER WORKER2 TP GRACE_S STALL_S FAILS_MAX NTFY; do declare -p "$_v" 2>/dev/null || echo "unset $_v"; done
  exit 0
fi
STATE_FILE="$ST/watchdog.state"
LOGF="$ST/watchdog.log"
NOW=$(date +%s)
mkdir -p "$ST"

get(){ sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | tail -1; }
num(){ case "$1" in ''|*[!0-9]*) echo "${2:-0}" ;; *) echo "$1" ;; esac; }
fails=$(num "$(get fails)")
last_restart=$(num "$(get last_restart)")
notified_hold=$(num "$(get notified_hold)")
notified_down=$(num "$(get notified_down)")
restarts=""
for r in $(get restarts); do r=$(num "$r" 0); [ "$r" -ge $((NOW - 86400)) ] && restarts="$restarts $r"; done
restarts="${restarts# }"
restarts_hour(){ local n=0 r; for r in $restarts; do [ "$r" -ge $((NOW - HOUR)) ] && n=$((n+1)); done; echo "$n"; }

say(){ local l; l="$(date -u +%FT%TZ) glm53-watchdog: $*"; echo "$l"; echo "$l" >> "$LOGF"
  if [ "$(wc -l < "$LOGF")" -gt 6000 ]; then tail -n 5000 "$LOGF" > "$LOGF.tmp" && mv -f "$LOGF.tmp" "$LOGF"; fi; }
notify(){ [ -n "$NTFY" ] || return 0; curl -sk -m 5 -H "Title: GLM-5.3 engine" -d "$*" "$NTFY" >/dev/null 2>&1 || true; }
save(){ # $1 result word, $2 detail
  local hold=no; [ "$1" = hold ] && hold=yes
  { echo "updated=$NOW"; echo "updated_utc=$(date -u -d "@$NOW" +%FT%TZ)"; echo "result=$1"; echo "detail=$2"
    echo "fails=$fails"; echo "restarts=$restarts"; echo "restarts_hour=$(restarts_hour)"; echo "last_restart=$last_restart"
    echo "hold=$hold"; echo "notified_hold=$notified_hold"; echo "notified_down=$notified_down"; } > "$STATE_FILE.tmp" \
    && mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}
finish(){ save "$1" "$2"; say "$1: $2"; exit 0; }

ok_tick(){ fails=0; finish ok "$1"; }
restart_unit(){  # $1 why, $2 failed-tick text
  local why="$1" n
  n=$(restarts_hour)
  if [ "$n" -ge "$RESTARTS_MAX" ]; then
    if [ $((NOW - notified_hold)) -ge "$HOUR" ]; then
      notified_hold=$NOW
      notify "glm53-watchdog HOLD: $why, and $n restarts in the last hour already. No restart. Restart or fix glm53-serve."
    fi
    finish hold "$why ($2); $n restarts in the last hour (cap $RESTARTS_MAX): no restart"
  fi
  say "RESTART glm53-serve: $why ($2; restart $((n + 1)) of $RESTARTS_MAX in this hour)"
  sudo -n systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true   # its restarts must not use up StartLimitBurst
  if sudo -n systemctl restart --no-block "$UNIT"; then
    restarts="${restarts:+$restarts }$NOW"; last_restart=$NOW; fails=0
    notify "glm53-watchdog restarted glm53-serve: $why (restart $((n + 1)) of $RESTARTS_MAX in this hour)."
    finish restarted "$why"
  fi
  finish restart-failed "$why: systemctl restart glm53-serve failed"
}
fail_tick(){
  fails=$((fails + 1))
  [ "$fails" -lt "$FAILS_MAX" ] && finish fail "$1 (failed tick $fails of $FAILS_MAX)"
  restart_unit "$1" "failed tick $fails"
}

rank_down(){  # prints which rank container is not running ("" = all run, or a worker out of reach)
  local w
  [ "$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null)" = true ] || { echo "rank 0 (spark1)"; return; }
  w=$(timeout 15 ssh -n -o BatchMode=yes -o ConnectTimeout=8 "$WORKER" "docker inspect -f '{{.State.Running}}' $CTR 2>/dev/null || echo false" 2>/dev/null) || return 0
  [ "$w" = true ] || { echo "rank 1 (spark2)"; return; }
  [ "$TP" = 3 ] || return 0
  w=$(timeout 15 ssh -n -o BatchMode=yes -o ConnectTimeout=8 "$WORKER2" "docker inspect -f '{{.State.Running}}' $CTR 2>/dev/null || echo false" 2>/dev/null) || return 0
  [ "$w" = true ] || echo "rank 2 (spark3)"
}

probe(){
  local out code body hl ok iter inflight broken tmp t down
  out=$(curl -s -m "$HEALTH_S" -w '\n%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)
  code=${out##*$'\n'}; body=${out%$'\n'*}
  [ "$code" = 200 ] || fail_tick "/health answered ${code:-nothing}"
  hl=$(printf '%s' "$body" | python3 -c '
import json, sys
try:
    h = json.load(sys.stdin)
except Exception:
    print("x 0 0 -"); sys.exit(0)
ok = "0" if h.get("ok") is False else "1"
it = h.get("iteration_s") or 0
run = h.get("requests_running") or 0
b = str(h.get("broken") or "-").replace("\n", " ")[:80].replace(" ", "_")
print(ok, int(float(it)), int(run), b)' 2>/dev/null)
  read -r ok iter inflight broken <<< "${hl:-x 0 0 -}"
  [ "$ok" = x ] && fail_tick "/health 200 without a JSON body"
  [ "$ok" = 0 ] && restart_unit "/health ok false (broken: ${broken//_/ })" "the kit does not exit on a broken pair"
  iter=$(num "$iter" 0); inflight=$(num "$inflight" 0)
  [ "$iter" -le "$STALL_S" ] || fail_tick "one engine step has run ${iter}s (over ${STALL_S}s)"
  down=$(rank_down)
  [ -z "$down" ] || fail_tick "$down container not running"
  [ "$inflight" = 0 ] || ok_tick "busy: $inflight running; /health 200 ok, step ${iter}s (no chat probe on a busy engine)"
  tmp=$(mktemp)
  out=$(curl -s -m "$PROBE_S" -o "$tmp" -w '%{http_code} %{time_total}' -H 'Content-Type: application/json' \
    -d "{\"model\": \"$SERVED\", \"max_tokens\": 8, \"temperature\": 0, \"chat_template_kwargs\": {\"enable_thinking\": false}, \"messages\": [{\"role\": \"user\", \"content\": \"Reply with the single word: ready\"}]}" \
    "http://127.0.0.1:$PORT/v1/chat/completions" 2>/dev/null)
  code=${out%% *}; t=${out#* }
  if [ "$code" = 200 ] && python3 -c '
import json, sys
m = (json.load(open(sys.argv[1])).get("choices") or [{}])[0].get("message") or {}
sys.exit(0 if (m.get("content") or m.get("reasoning_content") or "").strip() else 1)' "$tmp" 2>/dev/null; then
    rm -f "$tmp"; ok_tick "idle; chat probe 200 in ${t}s"
  fi
  rm -f "$tmp"
  fail_tick "idle; chat probe ${code:-no answer} after ${t:-?}s"
}

systemctl is-enabled --quiet "$UNIT" 2>/dev/null || { fails=0; finish off "glm53-serve is not enabled: GLM is not deployed"; }
[ -e "$ST/HOLD" ] && finish held "HOLD marker ($(head -c 80 "$ST/HOLD")): no probe, no restart"
start=$(num "$(cat "$ST/last-start" 2>/dev/null)" 0)
[ "$last_restart" -gt "$start" ] && start=$last_restart
age=$((NOW - start))
if [ "$age" -lt "$GRACE_S" ]; then fails=0; finish grace "${age}s since the last start (grace ${GRACE_S}s): no probe"; fi
active=$(systemctl show -p ActiveState --value "$UNIT" 2>/dev/null)
sub=$(systemctl show -p SubState --value "$UNIT" 2>/dev/null)
result=$(systemctl show -p Result --value "$UNIT" 2>/dev/null)
case "$active" in
  active) probe ;;
  activating)
    if [ "$sub" = auto-restart ]; then fails=0; finish systemd-restart "systemd restarts glm53-serve (auto-restart pending)"; fi
    fail_tick "glm53-serve still loading ${age}s after the start ($sub)" ;;
  failed)
    if [ $((NOW - notified_down)) -ge "$HOUR" ]; then
      notified_down=$NOW
      notify "glm53-serve FAILED (Result=$result): systemd stopped restarting it. Restart or fix glm53-serve."
    fi
    finish unit-failed "glm53-serve failed (Result=$result): systemd gave up; the watchdog does not restart it" ;;
  *) fails=0; finish "unit-${active:-unknown}" "glm53-serve is ${active:-unknown}/${sub:-?}: no probe, no restart (a stop by hand?)" ;;
esac
