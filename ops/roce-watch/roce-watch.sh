#!/bin/bash
# roce-watch.sh: the 48 h production watch for COMM=roce on GLM-5.3-Flash-EXL3 at TP=3, with one automatic rollback
# to COMM=nccl. It runs ON spark1 (the head): a transient systemd timer calls `run` once a minute. It reads spark1
# and the two workers (ssh) only, so a sleeping workstation or a monitoring-host outage does not blind it. The rule is fixed in
# docs/operations.md ("The RoCE watch").
#
#   start  [--base-sha SHA --roce-sha SHA] [--hours N]   arm after the adopted engine verifies, then start the timer
#   run                       one poll (the timer calls it). A trigger: one rollback, then the watch ends
#   check  [--base-sha SHA --roce-sha SHA]   read-only: each trigger's reading and what `run` would do now
#   dry    [CASE]             simulated readings for each trigger; prints the exact commands (nothing runs)
#   pause  [REASON]           before a planned restart or reboot: polls do nothing until `resume`
#   resume                    after it, when the engine serves: verify again, take a new baseline, poll again
#   stop                      end the watch with no rollback and stop the timer
#   status                    the record, the markers, the timer and the last log lines
# State: $RW_DIR (default $HOME/glm53/roce-watch). It survives a reboot. The transient timer does not
# (docs/operations.md, "The RoCE watch"). tests/test_roce_watch.sh runs every path against stub commands.
set -uo pipefail
# hosts.conf in ../bin, beside the ops scripts (GLM_HOSTS_CONF names another file), sets this cluster's values;
# without it the defaults below apply. hosts.conf.example lists every name.
_hc=${GLM_HOSTS_CONF:-$(dirname "$(readlink -f "$0")")/../bin/hosts.conf}
[ -z "${GLM_HOSTS_CONF:-}" ] || [ -r "$_hc" ] || { echo "roce-watch: cannot read GLM_HOSTS_CONF=$_hc" >&2; exit 1; }
# shellcheck source=/dev/null
[ -r "$_hc" ] && . "$_hc"

GLM_HOME=${GLM_HOME:-$HOME/glm53}
RW_DIR=${RW_DIR:-$GLM_HOME/roce-watch}
LOCAL=${GLM_LOCAL_SH:-$GLM_HOME/kit/scripts/local.sh}
WORKERS=${RW_WORKERS:-"spark2=${GLM_WORKER:-user@192.0.2.180} spark3=${GLM_WORKER2:-user@192.0.2.216}"}
NTFY_BASE=${NTFY_BASE-}   # empty (the default): no ntfy message at all
NTFY_TOPIC_CRIT=${NTFY_TOPIC_CRIT:-alerts-critical}
NTFY_TOPIC_INFO=${NTFY_TOPIC_INFO:-alerts}
PROM_URL=${PROM_URL:-}            # optional Prometheus base URL; empty = off (none by default)
ROLLBACK_WAIT_S=${ROLLBACK_WAIT_S:-1500}   # the TP=3 restore cap (25 min)
UNIT=glm53-serve.service
WU=glm53-roce-watch               # the transient timer and service
CTR=glm53-flash-tf
HEALTH_URL=http://127.0.0.1:8888/health
METRICS_URL=http://127.0.0.1:8888/metrics
MARKER_FILE=$GLM_HOME/GLM_ACTIVE  # glm53_active (glm53-textfile.sh): every glm53 alert rule needs it
WD_STATE=$GLM_HOME/state/watchdog.state
WD_LOG=$GLM_HOME/state/watchdog.log
REC=$RW_DIR/watch.env             # the arm record (start, resume)
ST=$RW_DIR/state                  # per-poll state (stall pending, foreign-config page)
LOGF=$RW_DIR/watch.log
BASE_COPY=$RW_DIR/local.sh.baseline
STALL_S=120; STALL_FOR_S=60       # GLMEngineStalled: iteration_seconds > 120, for: 1m
WAIT_POLL_S=15
LOG_MAX=5000
FAKE_NOW=${RW_FAKE_NOW:-}         # tests and dry: a clock that `nap` moves
# GLM_PRINT_CONFIG=1: print the values this run would use, then exit (tests/test_hosts_conf.sh)
if [ "${GLM_PRINT_CONFIG:-}" = 1 ]; then
  for _v in GLM_HOME RW_DIR LOCAL WORKERS NTFY_BASE NTFY_TOPIC_CRIT NTFY_TOPIC_INFO PROM_URL; do declare -p "$_v" 2>/dev/null || echo "unset $_v"; done
  exit 0
fi

# roce.py's error set (the production image's tensorfold/cuda/roce.py, sha256 61a75274). Fixed strings.
ROCE_ERR=(
  "RoCE all-gather failed (sequence"            # roce.py:302  check(): a GPU wait timed out or the proxy failed
  "RoCE all-gather could not connect"           # roce.py:273
  "RoCE all-gather setup failed on some rank"   # roce.py:242
  "RoCE routes: "                               # roce.py:261
  "RoCE: no HCA of rank"                        # roce.py:177
  "RoCE layout refused world"                   # roce.py:194
  "unexpected RoCE proxy ABI version"           # roce.py:86
  "building the RoCE proxy failed"              # roce.py:70
  "the RoCE all-gather needs a C compiler"      # roce.py:64
  "TF_ROCE_WAIT_S: 1 to 3600 seconds"           # roce.py:45
)
BROKEN_LINE="engine broken; TF_GLM_EXIT_ON_BROKEN=1"   # glm5_next/cuda/multi.py:793, the latch before os._exit(1)
STALL_RE='Timeout \([0-9]+:[0-9]{2}:[0-9]{2}\)!'       # faulthandler's header (multi.py:100-108, WATCHDOG_EXIT=1)
ROCE_UP_RE='all-gathers up to .* over RoCE'             # glm5_next/cuda/engine.py:556, rank 0: NOT an error
COARSE='RoCE|TF_ROCE_WAIT_S|engine broken; TF_GLM_EXIT_ON_BROKEN|Timeout \([0-9]+:[0-9]{2}:[0-9]{2}\)!'

PY_HEALTH='
import json, sys
try:
    h = json.load(sys.stdin)
except Exception:
    h = None
if not isinstance(h, dict):
    print("down - -"); sys.exit(0)
ok = {True: "true", False: "false"}.get(h.get("ok"), "other")
it = h.get("iteration_s")
it = "-" if isinstance(it, bool) or not isinstance(it, (int, float)) else repr(float(it))
b = str(h.get("broken") or "-").replace("\n", " ")[:160].replace(" ", "_") or "-"
print(ok, it, b)
'
PY_PROM='
import calendar, json, sys, time
since = int(sys.argv[1])
try:
    alerts = json.load(sys.stdin)["data"]["alerts"]
except Exception:
    print("noread"); sys.exit(0)
for a in alerts:
    if (a.get("labels") or {}).get("alertname") == "GLMEngineStalled" and a.get("state") == "firing":
        try:
            t = calendar.timegm(time.strptime((a.get("activeAt") or "")[:19], "%Y-%m-%dT%H:%M:%S"))
        except Exception:
            t = 0
        if t >= since:
            print("firing@%d" % t); sys.exit(0)
print("quiet")
'

# ------------------------------------------------------------------ small helpers
now(){ if [ -n "$FAKE_NOW" ]; then echo "$FAKE_NOW"; else date +%s; fi; }
nap(){ if [ -n "$FAKE_NOW" ]; then FAKE_NOW=$((FAKE_NOW + $1)); else sleep "$1"; fi; }
utc(){ date -u -d "@$1" +%FT%TZ; }
num(){ if [[ ${1:-} =~ ^[0-9]+$ ]]; then echo "$1"; else echo "${2:-0}"; fi; }
gt(){ awk -v a="$1" -v b="$2" 'BEGIN { exit !((a + 0) > (b + 0)) }'; }
ge(){ awk -v a="$1" -v b="$2" 'BEGIN { exit !((a + 0) >= (b + 0)) }'; }
hms(){ local s=$1; [ "$s" -lt 0 ] && s=0; printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60)); }
kv_get(){ sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1; }
is_sha(){ [[ ${1:-} =~ ^[0-9a-f]{64}$ ]]; }
dry(){ [ "${DRY:-0}" = 1 ]; }
dnote(){ if dry; then echo "  $*"; fi; return 0; }   # --dry: a read or a wait the rollback makes
die(){ echo "roce-watch: $*" >&2; exit 1; }
say(){   # one line to stdout; `run`, `start`, `pause`, `resume`, `stop` and `dry` also append it to the log
  local l; l="$(utc "$(now)") $*"
  echo "$l"
  case "$MODE" in check|status) return 0 ;; esac
  echo "$l" >> "$LOGF" 2>/dev/null || return 0
  if [ "$(wc -l < "$LOGF")" -gt "$LOG_MAX" ]; then tail -n $((LOG_MAX - 1000)) "$LOGF" > "$LOGF.tmp" && mv -f "$LOGF.tmp" "$LOGF"; fi
}
x(){   # a command that changes something: --dry prints it instead
  if dry; then echo "  would run: $(printf '%q ' "$@")"; dry_effect "$@"; return 0; fi
  "$@"
}
put(){ cat > "$1.tmp" && mv -f "$1.tmp" "$1"; }   # put FILE < content: atomic
take_lock(){ exec 9>"$RW_DIR/.lock" || return 1; flock "$@" 9; }
ntfy(){   # ntfy TOPIC TITLE PRIORITY MESSAGE (three tries)
  local code
  [ -n "$NTFY_BASE" ] || { say "ntfy off (NTFY_BASE is empty): $2"; return 0; }
  if dry; then echo "  would post to $NTFY_BASE/$1 (Title: $2, Priority: $3): $4"; return 0; fi
  for _ in 1 2 3; do
    code=$(curl -sk -m 8 -o /dev/null -w '%{http_code}' -H "Title: $2" -H "Priority: $3" -d "$4" "$NTFY_BASE/$1" 2>/dev/null)
    [ "$code" = 200 ] && { say "ntfy $1: posted ($2)"; return 0; }
    nap 5
  done
  say "ntfy $1: FAILED three times (last HTTP ${code:-none}): $2"
  return 1
}

# ------------------------------------------------------------------ reads (dry: simulated, see the dry section)
sha_of(){ if dry; then sim_sha "$1"; return; fi; if [ -r "$1" ]; then sha256sum < "$1" | cut -d' ' -f1; else echo none; fi; }
cfg_read(){   # CFG: roce | base | foreign (local.sh is neither sha: someone changed it by hand)
  CFG_SHA=$(sha_of "$LOCAL")
  if [ "$CFG_SHA" = "$ROCE_SHA" ]; then CFG=roce; elif [ "$CFG_SHA" = "$BASE_SHA" ]; then CFG=base; else CFG=foreign; fi
}
unit_read(){   # U_active U_sub U_nr U_inv U_result U_start (systemctl show; --timestamp=unix gives @epoch)
  local out k v
  U_active=""; U_sub=""; U_nr=""; U_inv=""; U_result=""; U_start=0
  if dry; then out=$(sim_unit); else
    out=$(timeout 15 systemctl show --timestamp=unix -p ActiveState -p SubState -p NRestarts -p InvocationID \
      -p Result -p ExecMainStartTimestamp "$UNIT" 2>/dev/null)
  fi
  while IFS='=' read -r k v; do
    case "$k" in
      ActiveState) U_active=$v ;; SubState) U_sub=$v ;; NRestarts) U_nr=$v ;; InvocationID) U_inv=$v ;;
      Result) U_result=$v ;; ExecMainStartTimestamp) U_start=$(num "${v#@}") ;;
    esac
  done <<< "$out"
}
health_read(){   # H_ok: true | false | other | down; H_iter: iteration_s or -; H_broken: the latch text or -
  local body
  if dry; then body=$(sim_health); else body=$(curl -s -m 10 "$HEALTH_URL" 2>/dev/null); fi
  read -r H_ok H_iter H_broken <<< "$(printf '%s' "$body" | python3 -c "$PY_HEALTH" 2>/dev/null)"
  H_ok=${H_ok:-down}; H_iter=${H_iter:--}; H_broken=${H_broken:--}
}
metrics_read(){   # M_ok: tensorfold_health:ok (metrics.py:198); M_pair: tensorfold:pair_broken (not in this kit)
  local body
  if dry; then body=$(sim_metrics); else body=$(curl -s -m 10 "$METRICS_URL" 2>/dev/null); fi
  M_ok=$(printf '%s\n' "$body" | awk '$1 == "tensorfold_health:ok" { print $2; exit }')
  M_pair=$(printf '%s\n' "$body" | awk 'index($1, "tensorfold:pair_broken") == 1 { print $2; exit }')
}
coarse(){ grep -a -E "$COARSE" | tail -n 200; }
logs_read(){   # logs_read FROM: LOG_HITS ("src<TAB>kind<TAB>line" a line), NODES (who answered), N_UP (RoCE-up lines).
               # The kit's saved logs (~/.cache/tensorfold-glm53/logs/*.log.gz) are NOT read: start.sh saves a crashed
               # container's log after the next main start, so the old engine's lines get a new mtime. A saved log
               # exists only after a restart, and trigger 3 sees every restart.
  local from=$1 raw="" name host out ln src kind p
  NODES=""
  if dry; then raw=$(sim_logs); NODES="spark1 spark2 spark3"; else
    out=$(timeout 30 journalctl -u "$UNIT" --since "@$from" --no-pager -o cat 2>/dev/null | coarse)
    raw+=$(printf '%s\n' "$out" | sed '/^$/d; s/^/spark1-journal\t/')$'\n'
    out=$(timeout 30 docker logs --since "$from" "$CTR" 2>&1 | coarse)
    raw+=$(printf '%s\n' "$out" | sed '/^$/d; s/^/spark1-rank0\t/')$'\n'
    NODES="spark1"
    for p in $WORKERS; do
      name=${p%%=*}; host=${p#*=}
      out=$(timeout 40 ssh -n -o BatchMode=yes -o ConnectTimeout=8 "$host" \
        "docker logs --since $from $CTR 2>&1 | grep -a -E '$COARSE' | tail -n 200 | sed 's/^/R|/'; echo __rw_ok__" 2>/dev/null)
      if [[ $out == *__rw_ok__* ]]; then
        NODES+=" $name"
        raw+=$(printf '%s\n' "$out" | grep -v '^__rw_ok__$' | sed -e '/^$/d' -e "s/^R|/$name-rank\t/")$'\n'
      else NODES+=" $name:noread"; fi
    done
  fi
  LOG_HITS=""; N_UP=0
  while IFS=$'\t' read -r src ln; do
    [ -n "$src" ] || continue
    if [[ $ln =~ $ROCE_UP_RE ]]; then N_UP=$((N_UP + 1)); continue; fi
    kind=""
    for p in "${ROCE_ERR[@]}"; do [[ $ln == *"$p"* ]] && { kind=roce; break; }; done
    [ -z "$kind" ] && [[ $ln == *"$BROKEN_LINE"* ]] && kind=broken
    [ -z "$kind" ] && [[ $ln =~ $STALL_RE ]] && kind=stall
    [ -n "$kind" ] && LOG_HITS+="$src"$'\t'"$kind"$'\t'"${ln:0:300}"$'\n'
  done <<< "$raw"
}
hits(){ printf '%s' "$LOG_HITS" | awk -F'\t' -v k="$1" '$2 == k' ; }
nhits(){ hits "$1" | grep -c . ; }
wd_read(){   # glm53-watchdog's own restarts: state file last_restart and restarts list, log RESTART lines
  local r a
  if dry; then read -r WD_last WD_list WD_log <<< "$(sim_wd)"; return; fi
  WD_last=$(num "$(kv_get "$WD_STATE" last_restart)")
  WD_list=0
  for r in $(kv_get "$WD_STATE" restarts); do r=$(num "$r"); [ "$r" -ge "$ARMED_AT" ] && WD_list=$((WD_list + 1)); done
  a=$(utc "$ARMED_AT")
  WD_log=$(awk -v a="$a" '$1 >= a && index($0, "glm53-watchdog: RESTART glm53-serve") > 0' "$WD_LOG" 2>/dev/null | grep -c .)
}
rocup_count(){   # RoCE-up lines in the running rank-0 container's log; "?" when docker gives no log
  local out
  if dry; then sim_rocup; return; fi
  out=$(timeout 30 docker logs "$CTR" 2>&1) || { echo "?"; return; }
  printf '%s\n' "$out" | grep -c -E "$ROCE_UP_RE"
}
journal_rocup(){   # journal_rocup FROM: RoCE-up lines in the glm53-serve journal since FROM
  if dry; then sim_rocup; return; fi
  timeout 30 journalctl -u "$UNIT" --since "@$1" --no-pager -o cat 2>/dev/null | grep -c -E "$ROCE_UP_RE"
}
marker_on(){ if dry; then return 0; fi; [ -e "$MARKER_FILE" ]; }
prom_read(){   # P_STATE: off | noread | quiet | firing@EPOCH (GLMEngineStalled firing since the arm); never needed
  local body
  if dry; then P_STATE=off; return; fi
  [ -n "$PROM_URL" ] || { P_STATE=off; return; }
  body=$(curl -sk -m 5 "$PROM_URL/api/v1/alerts" 2>/dev/null) || { P_STATE=noread; return; }
  P_STATE=$(printf '%s' "$body" | python3 -c "$PY_PROM" "$ARMED_AT" 2>/dev/null); P_STATE=${P_STATE:-noread}
}
timer_active(){ if dry; then return 0; fi; [ "$(timeout 10 systemctl is-active "$WU.timer" 2>/dev/null)" = active ]; }

# ------------------------------------------------------------------ the record
load_rec(){
  BASE_SHA=$(kv_get "$REC" BASE_SHA); ROCE_SHA=$(kv_get "$REC" ROCE_SHA)
  HOURS=$(num "$(kv_get "$REC" HOURS)" 48); START=$(num "$(kv_get "$REC" START)")
  ARMED_AT=$(num "$(kv_get "$REC" ARMED_AT)"); SCAN_FROM=$(num "$(kv_get "$REC" SCAN_FROM)")
  NR0=$(num "$(kv_get "$REC" NR0)"); INV0=$(kv_get "$REC" INV0); WD0=$(num "$(kv_get "$REC" WD0)")
  PAUSED_TOTAL=$(num "$(kv_get "$REC" PAUSED_TOTAL)")
  DEADLINE=$((START + HOURS * 3600 + PAUSED_TOTAL))
  is_sha "$BASE_SHA" && is_sha "$ROCE_SHA" && return 0
  if [ "$MODE" = run ]; then   # a timer poll: page once (BAD-RECORD-PAGED), then every poll logs it and exits 1
    say "poll: $REC has no valid BASE_SHA and ROCE_SHA: the watch cannot act"
    if [ ! -e "$RW_DIR/BAD-RECORD-PAGED" ]; then
      ntfy "$NTFY_TOPIC_CRIT" "GLM-5.3 roce watch: the record is bad" high \
        "On spark1 $REC has no valid BASE_SHA and ROCE_SHA. The COMM=roce watch cannot act: no trigger can roll back. Check the file, or roll back by hand (docs/operations.md, 'Return to NCCL by hand')." \
        && date -u +%FT%TZ > "$RW_DIR/BAD-RECORD-PAGED"
    fi
  fi
  die "$REC has no valid BASE_SHA and ROCE_SHA"
}
write_rec(){
  put "$REC" <<EOF
# roce-watch arm record ($(utc "$(now)")); start writes it, resume rewrites it. Do not edit.
BASE_SHA=$BASE_SHA
ROCE_SHA=$ROCE_SHA
HOURS=$HOURS
START=$START
START_UTC=$(utc "$START")
ARMED_AT=$ARMED_AT
SCAN_FROM=$SCAN_FROM
NR0=$NR0
INV0=$INV0
WD0=$WD0
PAUSED_TOTAL=$PAUSED_TOTAL
EOF
}
save_state(){ printf 'updated=%s\nstall_since=%s\nforeign_sent=%s\nmarker_sent=%s\n' "$NOW" "${NEW_STALL:-}" "${FOREIGN_SENT:-}" "${MARKER_SENT:-}" | put "$ST"; }
TERMINAL="ROLLED-BACK ROLLBACK-FAILED PASSED STOPPED"
terminal(){ local m; for m in $TERMINAL; do [ -e "$RW_DIR/$m" ] && { echo "$m"; return 0; }; done; return 1; }

# ------------------------------------------------------------------ the four triggers (reads only)
FIRED=""
fire(){ FIRED+="$1: $2"$'\n'; }
evaluate(){   # every reading, then FIRED (one "trigger: detail" a line) and NEW_STALL; writes nothing
  local prev_stall=${STALL_PREV:-} n first
  FIRED=""; NEW_STALL=""
  cfg_read; unit_read; health_read; metrics_read; logs_read "$SCAN_FROM"; wd_read; prom_read
  if marker_on; then MARKER=on; else MARKER=off; fi
  # 1. a RoCE error line from roce.py's error set, in the journal or a rank log on any node, since SCAN_FROM
  n=$(nhits roce)
  if [ "$n" -gt 0 ]; then first=$(hits roce | head -n 1 | cut -f1,3 | tr '\t' ' '); fire roce-error "$n line(s); first: $first"; fi
  # 2. GLMEngineStalled: iteration_seconds > 120 for 1 min, with the GLM marker on. iteration_s is the age of rank 0's
  #    running iteration (multi.py:781), so one read at 180 s or more is the same condition.
  if [ "$MARKER" = on ] && [ "$H_iter" != - ] && gt "$H_iter" "$STALL_S"; then
    NEW_STALL=${prev_stall:-$NOW}
    if ge "$H_iter" $((STALL_S + STALL_FOR_S)) || [ $((NOW - NEW_STALL)) -ge "$STALL_FOR_S" ]; then
      fire stall "/health iteration_s $H_iter s (over $STALL_S s since $(utc "$NEW_STALL"))"
    fi
  fi
  n=$(nhits stall)
  [ "$n" -gt 0 ] && fire stall "$n faulthandler 'Timeout (...)!' line(s) (TF_GLM_MULTI_WATCHDOG_EXIT): $(hits stall | head -n 1 | cut -f1)"
  [[ $P_STATE == firing* ]] && fire stall "Prometheus: GLMEngineStalled firing since $(utc "${P_STATE#firing@}")"
  # 3. an unplanned glm53-serve restart
  [[ $U_nr =~ ^[0-9]+$ ]] && [ "$U_nr" -gt "$NR0" ] && fire restart "NRestarts $U_nr, was $NR0 at the arm"
  [ -n "$INV0" ] && [ -n "$U_inv" ] && [ "$U_inv" != "$INV0" ] && fire restart "a new start with no pause (InvocationID ${U_inv:0:12}, was ${INV0:0:12})"
  [ "$U_sub" = auto-restart ] && fire restart "the engine exited and systemd restarts it (auto-restart pending)"
  [ "$U_active" = failed ] && fire restart "glm53-serve failed (Result=$U_result)"
  if [ "$WD_last" -gt "$WD0" ] || [ "$WD_list" -gt 0 ] || [ "$WD_log" -gt 0 ]; then
    fire restart "glm53-watchdog restarted glm53-serve (last_restart $WD_last, was $WD0; $WD_list in its list and $WD_log RESTART log line(s) since the arm)"
  fi
  # 4. the broken latch
  [ "$H_ok" = false ] && fire broken "/health ok false, broken: ${H_broken//_/ }"
  [ "${M_ok:-}" = 0 ] && fire broken "/metrics tensorfold_health:ok 0"
  [ -n "${M_pair:-}" ] && gt "$M_pair" 0 && fire broken "/metrics tensorfold:pair_broken $M_pair"
  n=$(nhits broken)
  [ "$n" -gt 0 ] && fire broken "$n '$BROKEN_LINE' line(s): $(hits broken | head -n 1 | cut -f1)"
  return 0
}
summary(){
  printf 'cfg=%s unit=%s/%s nr=%s inv=%s health=%s iter=%s marker=%s m_ok=%s err=%s/%s/%s up=%s wd=%s/%s/%s prom=%s nodes=%s' \
    "$CFG" "${U_active:-?}" "${U_sub:-?}" "${U_nr:-?}" "${U_inv:0:8}" "$H_ok" "$H_iter" "${MARKER:-?}" "${M_ok:--}" \
    "$(nhits roce)" "$(nhits broken)" "$(nhits stall)" "$N_UP" "$WD_last" "$WD_list" "$WD_log" "$P_STATE" "${NODES// /,}"
}

# ------------------------------------------------------------------ the rollback (one at most)
RB=$RW_DIR/ROLLBACK-STARTED
rb_note(){ echo "$1" >> "$RB"; }
end_failed(){   # end_failed REASON: ROLLBACK-FAILED, page with the by-hand steps, stop the timer
  local why=$1 fired
  fired=$(kv_get "$RB" why)
  { cat "$RB" 2>/dev/null; echo "result=FAILED"; echo "result_why=$why"; echo "ended_utc=$(utc "$(now)")"; } | put "$RW_DIR/ROLLBACK-FAILED"
  say "ROLLBACK FAILED: $why"
  ntfy "$NTFY_TOPIC_CRIT" "GLM-5.3 COMM=roce rollback FAILED on spark1" urgent \
    "The COMM=roce watch fired ($fired) and the rollback did not finish: $why. The watch is stopped and does not try again. By hand on spark1: cp ~/glm53/roce-watch/local.sh.baseline ~/glm53/kit/scripts/local.sh (sha256 must be ${BASE_SHA:0:12}; else the baseline from this repo's history); sudo systemctl reset-failed glm53-serve; sudo systemctl restart glm53-serve; wait for curl -s localhost:8888/health to show ok true (TP=3 load up to 25 min); docker logs glm53-flash-tf 2>&1 | grep -c 'over RoCE' must print 0. Evidence: ~/glm53/roce-watch/ROLLBACK-FAILED."
  stop_timer
  exit 0
}
end_done(){   # end_done RESULT: ROLLED-BACK with the evidence, ntfy, stop the timer
  local res=$1 fired
  fired=$(kv_get "$RB" why)
  { cat "$RB"; echo "result=ROLLED-BACK"; echo "result_detail=$res"; echo "ended_utc=$(utc "$(now)")"; } | put "$RW_DIR/ROLLED-BACK"
  say "ROLLED BACK: $res"
  ntfy "$NTFY_TOPIC_CRIT" "GLM-5.3 rolled back to COMM=nccl on spark1" urgent \
    "The COMM=roce watch fired: $fired. Result: $res. The watch is stopped and never goes back to roce. This repo's ops/local.sh still says COMM=roce: put the baseline back in git. Evidence: ~/glm53/roce-watch/ROLLED-BACK on spark1."
  stop_timer
  exit 0
}
verify_new(){   # after /health ok from a new engine: the baseline local.sh and no RoCE-up line, else ROLLBACK-FAILED
  local s n j
  dnote "check: docker logs $CTR | grep -c '$ROCE_UP_RE' must be 0; the same in journalctl -u $UNIT --since @$U_start; local.sh must be ${BASE_SHA:0:12}"
  s=$(sha_of "$LOCAL"); n=$(rocup_count); j=$(journal_rocup "$U_start")
  rb_note "verify=local.sh ${s:0:12}; rank-0 RoCE-up lines container $n journal $j; InvocationID $U_inv"
  [ "$s" = "$BASE_SHA" ] || end_failed "a new engine serves, but local.sh is ${s:0:12}, not the baseline ${BASE_SHA:0:12}"
  [ "$n" = 0 ] && [ "$j" = 0 ] || end_failed "the new engine still shows RoCE (rank-0 RoCE-up lines: container '$n', journal '$j')"
  end_done "COMM=nccl serves: /health ok ${WAIT_EL}s after the restart, InvocationID ${U_inv:0:12}, local.sh ${s:0:12}, 0 RoCE-up lines"
}
wait_new(){   # wait_new INV_BEFORE RESTART_T: 0 when a NEW engine answers /health ok (unit active and a new InvocationID;
              # the old engine answers ok while systemd stops it, window k8 2026-11-07). No second restart, ever.
  local pre=$1 t0=$2 bad=0 next=0 el
  WAIT_WHY=""
  dnote "wait <= ${ROLLBACK_WAIT_S}s, every ${WAIT_POLL_S}s: systemctl show $UNIT (ActiveState=active, InvocationID != ${pre:-?}) and curl $HEALTH_URL (ok true)"
  while :; do
    NOW=$(now); el=$((NOW - t0)); WAIT_EL=$el
    unit_read; health_read
    if [ "$U_active" = active ] && [ -n "$U_inv" ] && [ "$U_inv" != "$pre" ] && [ "$H_ok" = true ]; then return 0; fi
    if [ "$el" -ge 180 ] && { [ "$U_active" = failed ] || [ "$U_active" = inactive ]; }; then
      bad=$((bad + 1))
      [ "$bad" -ge 3 ] && { WAIT_WHY="glm53-serve is $U_active (Result=$U_result) ${el}s after the restart"; return 1; }
    else bad=0; fi
    if [ "$el" -ge "$next" ]; then
      say "rollback wait +${el}s: unit $U_active/$U_sub InvocationID ${U_inv:0:12} (before ${pre:0:12}), /health $H_ok"
      next=$((el + 300))
    fi
    if [ "$el" -ge "$ROLLBACK_WAIT_S" ]; then
      WAIT_WHY="no /health ok from a new engine in ${ROLLBACK_WAIT_S}s (unit $U_active/$U_sub, InvocationID ${U_inv:0:12}, /health $H_ok)"
      return 1
    fi
    nap "$WAIT_POLL_S"
  done
}
rollback_steps(){   # the baseline back (sha-checked), one restart, the wait, the verify
  local b t s pre
  cfg_read
  if [ "$CFG" = foreign ]; then end_failed "local.sh changed by hand to ${CFG_SHA:0:12} (neither sha): NOT changed, glm53-serve NOT restarted"; fi
  unit_read; health_read
  if [ "$CFG" = base ] && [ "$U_active" = active ] && [ "$H_ok" = true ] && ! gt "$H_iter" "$STALL_S" && [ "$(rocup_count)" = 0 ]; then
    rb_note "step=local.sh is the baseline already and a COMM=nccl engine serves: no restart"
    WAIT_EL=0; end_done "COMM=nccl serves already (local.sh ${CFG_SHA:0:12}, /health ok, 0 RoCE-up lines): no restart was needed"
  fi
  dnote "check: sha256sum < $BASE_COPY must be $BASE_SHA"
  b=$(sha_of "$BASE_COPY")
  [ "$b" = "$BASE_SHA" ] || end_failed "the staged copy $BASE_COPY is ${b:0:12}, not the baseline ${BASE_SHA:0:12}: local.sh NOT changed, glm53-serve NOT restarted"
  t="$LOCAL.rw-tmp"
  x cp -f "$BASE_COPY" "$t" || end_failed "cp of the baseline copy failed: local.sh NOT changed, glm53-serve NOT restarted"
  x chmod 664 "$t" || say "rollback: chmod 664 $t failed: local.sh keeps the staged copy's mode 444 (the engine reads it all the same)"
  dnote "check: sha256sum < $t must be $BASE_SHA"
  s=$(sha_of "$t")
  if [ "$s" != "$BASE_SHA" ]; then x rm -f "$t"; end_failed "the copied file is ${s:0:12}, not ${BASE_SHA:0:12}: local.sh NOT changed, glm53-serve NOT restarted"; fi
  x mv -f "$t" "$LOCAL" || end_failed "mv over local.sh failed: glm53-serve NOT restarted"
  dnote "check: sha256sum < $LOCAL must be $BASE_SHA"
  s=$(sha_of "$LOCAL")
  [ "$s" = "$BASE_SHA" ] || end_failed "after the mv local.sh is ${s:0:12}, not ${BASE_SHA:0:12}: glm53-serve NOT restarted"
  rb_note "step=local.sh is the baseline ${s:0:12} again"
  unit_read; pre=$U_inv
  x timeout 30 sudo -n systemctl reset-failed "$UNIT"
  if ! x timeout 30 sudo -n systemctl restart --no-block "$UNIT"; then
    end_failed "systemctl restart glm53-serve failed. local.sh IS the baseline now; the engine was not restarted"
  fi
  NOW=$(now)
  rb_note "pre_inv=$pre"; rb_note "restarted_at=$NOW"
  say "rollback: local.sh is the baseline, glm53-serve restarted (InvocationID before ${pre:0:12}); waiting up to ${ROLLBACK_WAIT_S}s"
  wait_new "$pre" "$NOW" || end_failed "$WAIT_WHY. local.sh IS the baseline; no second restart was made"
  verify_new
}
rollback(){   # ROLLBACK-STARTED first (one rollback at most, even when this run dies half way)
  local why
  why=$(printf '%s' "$FIRED" | sed '/^$/d' | paste -sd'|' | sed 's/|/ | /g')
  {
    echo "at=$NOW"; echo "at_utc=$(utc "$NOW")"; echo "why=$why"; echo "readings=$(summary)"
    printf '%s' "$LOG_HITS" | sed '/^$/d' | head -n 20 | sed 's/^/hit=/'
  } | put "$RB"
  say "ROLLBACK: $why"
  rollback_steps
}
continue_rollback(){   # a rollback began in an earlier run: finish it; never restart a second time
  local pre t0
  pre=$(kv_get "$RB" pre_inv); t0=$(kv_get "$RB" restarted_at)
  if [ -z "$t0" ]; then
    say "a rollback began at $(kv_get "$RB" at_utc) and did not reach the restart: it goes on now"
    rollback_steps
  fi
  # A reboot or a kill stopped the earlier wait. The engine may load again from the start (a spark1 reboot), so the wait
  # clock starts again now. There is still no second restart.
  NOW=$(now); rb_note "wait_restarted_at=$NOW"
  say "a rollback restarted glm53-serve at $(utc "$t0"); the earlier run stopped in its wait: the wait clock starts again at $(utc "$NOW") (${ROLLBACK_WAIT_S}s, no second restart)"
  t0=$NOW
  wait_new "$pre" "$t0" || end_failed "$WAIT_WHY. local.sh IS the baseline; no second restart was made"
  verify_new
}

# ------------------------------------------------------------------ the timer
stop_timer(){ if timer_active; then x timeout 20 sudo -n systemctl stop "$WU.timer" || say "the timer stop FAILED: sudo systemctl stop $WU.timer"; fi; return 0; }
ensure_timer(){
  if timer_active; then say "the timer $WU.timer runs already"; return 0; fi
  dry || [ -r "$RW_DIR/roce-watch.sh" ] || die "$RW_DIR/roce-watch.sh is not there (copy it there: docs/operations.md, 'The RoCE watch')"
  x timeout 20 sudo -n systemctl reset-failed "$WU.service" "$WU.timer" 2>/dev/null   # a failed transient unit blocks the name
  x timeout 30 sudo -n systemd-run --unit="$WU" --description="GLM-5.3 COMM=roce watch, one poll (ops/roce-watch)" \
    --on-active=30s --on-unit-active=60s --timer-property=AccuracySec=5s \
    -p Type=oneshot -p User="${GLM_USER:-$(id -un)}" -p Group="${GLM_USER:-$(id -un)}" -p Environment=HOME="${GLM_USER_HOME:-$HOME}" -p TimeoutStartSec=35min \
    /bin/bash "$RW_DIR/roce-watch.sh" run || die "systemd-run failed: the timer did not start"
  say "the timer $WU.timer started (a poll each 60 s)"
}

# ------------------------------------------------------------------ the arm checks (start, resume)
arm_verify(){   # the adopted engine must verify before a baseline is taken. Prints each miss; 1 on any.
  local bad=0 b n
  cfg_read; unit_read; health_read
  [ "$CFG" = roce ] || { echo "MISS local.sh is ${CFG_SHA:0:12} ($CFG), not the roce sha ${ROCE_SHA:0:12}"; bad=1; }
  b=$(sha_of "$BASE_COPY"); [ "$b" = "$BASE_SHA" ] || { echo "MISS the staged copy $BASE_COPY is ${b:0:12}, not the baseline ${BASE_SHA:0:12}"; bad=1; }
  [ "$U_active/$U_sub" = active/running ] || { echo "MISS glm53-serve is ${U_active:-?}/${U_sub:-?}, not active/running"; bad=1; }
  [ "$U_nr" = 0 ] || { echo "MISS NRestarts is ${U_nr:-?}: the adopted engine restarted on its own (by the rule a rollback case)"; bad=1; }
  [ -n "$U_inv" ] && [ "$U_start" -gt 0 ] || { echo "MISS no InvocationID or main start time from systemd"; bad=1; }
  [ "$H_ok" = true ] || { echo "MISS /health ok is $H_ok (wait for ok true)"; bad=1; }
  n=$(rocup_count); [[ $n =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] || { echo "MISS the rank-0 log has '$n' RoCE-up lines: the engine is not on RoCE"; bad=1; }
  if [ "$U_start" -gt 0 ]; then
    logs_read "$U_start"
    [ -z "$LOG_HITS" ] || { echo "MISS this engine's logs already hold error lines:"; printf '%s' "$LOG_HITS" | head -n 5 | sed 's/^/  /'; bad=1; }
    [[ $NODES == *noread* ]] && { echo "MISS no log read from: $NODES"; bad=1; }
  fi
  return $bad
}

# ------------------------------------------------------------------ the commands
cmd_run(){
  local t m
  [ -d "$RW_DIR" ] || { echo "no $RW_DIR: nothing (not installed)"; exit 0; }
  take_lock -n || { say "poll: another run holds the lock (a rollback?): nothing"; exit 0; }
  NOW=$(now)
  if t=$(terminal); then say "poll: the watch ended ($t, $(kv_get "$RW_DIR/$t" ended_utc)): nothing"; stop_timer; exit 0; fi
  [ -s "$REC" ] || { say "poll: not armed (no $REC): nothing"; exit 0; }
  load_rec
  [ -e "$RB" ] && { continue_rollback; exit 0; }
  if [ -e "$RW_DIR/PAUSED" ]; then say "poll: paused since $(kv_get "$RW_DIR/PAUSED" at_utc) ($(kv_get "$RW_DIR/PAUSED" reason)): nothing"; exit 0; fi
  STALL_PREV=$(kv_get "$ST" stall_since); FOREIGN_SENT=$(kv_get "$ST" foreign_sent); MARKER_SENT=$(kv_get "$ST" marker_sent)
  evaluate
  if [ "$MARKER" = off ]; then   # GLMEngineStalled needs glm53_active, so trigger 2's /health path is off: say so once
    if [ "$MARKER_SENT" != 1 ]; then
      ntfy "$NTFY_TOPIC_CRIT" "GLM-5.3 roce watch: the GLM_ACTIVE marker is off" high \
        "On spark1 $MARKER_FILE does not exist. GLMEngineStalled needs it (glm53_active), so the watch's /health stall check is off, and so is every glm53 alert rule. The other triggers still act. Put it back (touch $MARKER_FILE) or end the watch: ~/glm53/roce-watch/roce-watch.sh stop."
      MARKER_SENT=1
    fi
  else MARKER_SENT=""; fi
  if [ "$CFG" = foreign ]; then
    if [ "$FOREIGN_SENT" != "$CFG_SHA" ]; then
      ntfy "$NTFY_TOPIC_CRIT" "GLM-5.3 roce watch: local.sh changed by hand" high \
        "On spark1 ~/glm53/kit/scripts/local.sh is ${CFG_SHA:0:12}: neither the roce sha ${ROCE_SHA:0:12} nor the baseline ${BASE_SHA:0:12}. The watch does nothing while it is so (no rollback). Put one of the two back, or end the watch: ~/glm53/roce-watch/roce-watch.sh stop."
      FOREIGN_SENT=$CFG_SHA
    fi
    save_state
    m=$(printf '%s' "$FIRED" | sed '/^$/d' | paste -sd'|')
    say "poll $(summary) -> FOREIGN local.sh ${CFG_SHA:0:12}: no action${m:+ (would fire: $m)}"
    exit 0
  fi
  FOREIGN_SENT=""
  if [ -n "$FIRED" ]; then save_state; rollback; exit 0; fi
  if [ "$NOW" -ge "$DEADLINE" ]; then
    # The pass keeps roce (operator rule): nothing touches the engine, local.sh or glm53-serve here. Only the marker,
    # one ntfy message and this watch's own timer.
    save_state
    local up title kept
    up=$(rocup_count)
    if [ "$CFG" = roce ]; then
      title="GLM-5.3 watch passed, COMM=roce kept"
      kept="COMM=roce is kept: local.sh is the roce sha ${CFG_SHA:0:12}, and the rank-0 log has $up RoCE-up line(s)"
    else
      title="GLM-5.3 watch passed, local.sh is the baseline"
      kept="local.sh is the baseline ${CFG_SHA:0:12}, not the roce sha ${ROCE_SHA:0:12}: someone put it back by hand. The running engine's rank-0 log has $up RoCE-up line(s); the next start of glm53-serve loads COMM=nccl"
    fi
    { echo "at_utc=$(utc "$NOW")"; echo "ended_utc=$(utc "$NOW")"; echo "result=PASSED; $kept"; echo "readings=$(summary)"; } | put "$RW_DIR/PASSED"
    say "PASSED: $HOURS h from $(utc "$START") with no trigger; $kept; $(summary)"
    ntfy "$NTFY_TOPIC_INFO" "$title" default \
      "The COMM=roce watch on spark1 passed: $HOURS h from $(utc "$START") (paused $((PAUSED_TOTAL / 60)) min) with no trigger. $kept. The watch changed nothing on the engine. The watch is stopped."
    stop_timer
    exit 0
  fi
  save_state
  say "poll $(summary) -> ok, $(hms $((DEADLINE - NOW))) left"
  exit 0
}
cmd_check(){   # read-only: nothing is written, no lock is taken, no unit is touched
  local armed=no t
  NOW=$(now)
  if [ -s "$REC" ]; then
    armed=yes; load_rec
    { [ -n "$ARG_BASE" ] && [ "$ARG_BASE" != "$BASE_SHA" ]; } || { [ -n "$ARG_ROCE" ] && [ "$ARG_ROCE" != "$ROCE_SHA" ]; } \
      && echo "NOTE the record's shas differ from the arguments: the record's are used"
    STALL_PREV=$(kv_get "$ST" stall_since)
  else
    BASE_SHA=$ARG_BASE; ROCE_SHA=$ARG_ROCE
    is_sha "$BASE_SHA" && is_sha "$ROCE_SHA" || die "not armed: give --base-sha SHA --roce-sha SHA (64 hex each)"
    unit_read
    HOURS=${ARG_HOURS:-48}; START=$NOW; ARMED_AT=$U_start; SCAN_FROM=$U_start; NR0=0; INV0=""; WD0=$(num "$(kv_get "$WD_STATE" last_restart)")
    PAUSED_TOTAL=0; DEADLINE=$((NOW + HOURS * 3600)); STALL_PREV=""
  fi
  echo "== roce-watch check on $(hostname -s) at $(utc "$NOW") (read-only)"
  echo "armed: $armed$([ "$armed" = yes ] && echo " at $(utc "$START"); deadline $(utc "$DEADLINE") ($(hms $((DEADLINE - NOW))) left)")"
  echo "shas: roce ${ROCE_SHA:0:12}, baseline ${BASE_SHA:0:12}; staged copy $BASE_COPY: $(sha_of "$BASE_COPY" | cut -c1-12)"
  echo "markers: $(for t in PAUSED ROLLBACK-STARTED $TERMINAL; do [ -e "$RW_DIR/$t" ] && printf '%s ' "$t"; done)"
  echo "timer $WU.timer: $(timeout 10 systemctl is-active "$WU.timer" 2>/dev/null)"
  echo "scan from: $(utc "$SCAN_FROM") (the engine's start$([ "$armed" = yes ] && echo " at the arm or resume")); restarts since: $(utc "$ARMED_AT")"
  evaluate
  echo "config: local.sh ${CFG_SHA:0:12} = $CFG; the rank-0 RoCE-up line: $(rocup_count) (the engine is $([ "$(rocup_count)" = 0 ] && echo "NOT on RoCE" || echo "on RoCE"))"
  echo "1 roce-error : $(nhits roce) line(s) from roce.py's error set; logs read from: $NODES"
  echo "2 stall      : iteration_s $H_iter (fires over $STALL_S s for $STALL_FOR_S s); marker GLM_ACTIVE $(marker_on && echo on || echo off); faulthandler lines $(nhits stall); Prometheus $P_STATE"
  echo "3 restart    : unit $U_active/$U_sub Result=$U_result NRestarts $U_nr (arm $NR0); InvocationID ${U_inv:0:12} (arm ${INV0:0:12}); watchdog last_restart $WD_last (arm $WD0), list $WD_list, log $WD_log"
  echo "4 broken     : /health ok $H_ok (broken: ${H_broken//_/ }); /metrics tensorfold_health:ok ${M_ok:-none}, tensorfold:pair_broken ${M_pair:-absent}; latch lines $(nhits broken)"
  [ -z "$LOG_HITS" ] || { echo "log hits:"; printf '%s' "$LOG_HITS" | head -n 10 | sed 's/^/  /'; }
  if [ -n "$FIRED" ]; then echo "fired:"; printf '%s' "$FIRED" | sed '/^$/d; s/^/  /'; else echo "fired: none"; fi
  echo "poll line: $(summary)"
  if [ "$armed" = no ]; then
    echo "run would: nothing (not armed)"
    if t=$(arm_verify 2>&1); then echo "start would: arm (the adopted engine verifies)"
    else echo "start would: REFUSE:"; printf '%s\n' "$t" | sed 's/^/  /'; fi
  elif t=$(terminal); then echo "run would: nothing (the watch ended: $t)"
  elif [ -e "$RB" ]; then echo "run would: finish the rollback that began at $(kv_get "$RB" at_utc) (no second restart)"
  elif [ -e "$RW_DIR/PAUSED" ]; then echo "run would: nothing (paused)"
  elif [ "$CFG" = foreign ]; then echo "run would: page once (local.sh is neither sha), no rollback"
  elif [ -n "$FIRED" ]; then echo "run would: ROLL BACK now (baseline local.sh ${BASE_SHA:0:12} back, sha-checked; one restart; wait <= ${ROLLBACK_WAIT_S}s)"
  elif [ "$NOW" -ge "$DEADLINE" ]; then echo "run would: post 'watch passed' to $NTFY_TOPIC_INFO and stop"
  else echo "run would: log one line, no action"; fi
  exit 0
}
cmd_start(){
  [ -d "$RW_DIR" ] || die "no $RW_DIR: install it first (docs/operations.md, 'The RoCE watch')"
  take_lock -w 30 || die "another run holds the lock"
  NOW=$(now)
  if t=$(terminal); then die "the watch ended ($t). A new watch needs a new state dir: move $RW_DIR aside first"; fi
  if [ -s "$REC" ]; then
    load_rec
    { [ -n "$ARG_BASE" ] && [ "$ARG_BASE" != "$BASE_SHA" ]; } || { [ -n "$ARG_ROCE" ] && [ "$ARG_ROCE" != "$ROCE_SHA" ]; } \
      && die "armed already with other shas (roce ${ROCE_SHA:0:12}, baseline ${BASE_SHA:0:12})"
    say "start: armed already at $(utc "$START"), deadline $(utc "$DEADLINE"): the timer only (the record is kept)"
    unit_read
    if [ -e "$RW_DIR/PAUSED" ]; then
      say "start: the watch is PAUSED: polls do nothing. When the engine serves, run: $RW_DIR/roce-watch.sh resume"
    elif { [ -n "$U_inv" ] && [ "$U_inv" != "$INV0" ]; } || { [[ $U_nr =~ ^[0-9]+$ ]] && [ "$U_nr" -gt "$NR0" ]; }; then
      say "start: WARNING: the engine restarted since the watch armed (InvocationID ${U_inv:0:12}, armed ${INV0:0:12}; NRestarts ${U_nr:-?}, armed $NR0). The first poll (30 s after the timer starts) WILL roll back. To keep roce, run pause, then resume"
    fi
    ensure_timer; exit 0
  fi
  BASE_SHA=$ARG_BASE; ROCE_SHA=$ARG_ROCE; HOURS=${ARG_HOURS:-48}
  is_sha "$BASE_SHA" && is_sha "$ROCE_SHA" || die "give --base-sha SHA --roce-sha SHA (64 hex each)"
  [ "$BASE_SHA" != "$ROCE_SHA" ] || die "the two shas are the same"
  [[ $HOURS =~ ^[0-9]+$ ]] && [ "$HOURS" -ge 1 ] && [ "$HOURS" -le 168 ] || die "--hours: 1 to 168"
  ARMED_AT=$NOW
  if ! arm_verify; then die "start: the adopted engine does not verify: NOT armed (the misses above)"; fi
  START=$NOW; SCAN_FROM=$U_start; NR0=$U_nr; INV0=$U_inv; WD0=$(num "$(kv_get "$WD_STATE" last_restart)"); PAUSED_TOTAL=0
  write_rec; rm -f "$ST"
  say "start: armed for $HOURS h, deadline $(utc $((START + HOURS * 3600))); engine start $(utc "$SCAN_FROM"), NRestarts $NR0, InvocationID ${INV0:0:12}, watchdog last_restart $WD0"
  ensure_timer
}
cmd_pause(){
  take_lock -w 30 || die "a poll or a rollback holds the lock: see status"
  [ -s "$REC" ] || die "not armed"
  ! t=$(terminal) || die "the watch ended ($t)"
  [ -e "$RB" ] && die "a rollback runs or began: no pause"
  NOW=$(now)
  if [ -e "$RW_DIR/PAUSED" ]; then echo "paused already since $(kv_get "$RW_DIR/PAUSED" at_utc)"; exit 0; fi
  printf 'at=%s\nat_utc=%s\nreason=%s\nby=%s\n' "$NOW" "$(utc "$NOW")" "${REST[*]:-planned work}" "$(id -un)" | put "$RW_DIR/PAUSED"
  say "pause: ${REST[*]:-planned work}. Polls do nothing. When the engine serves again: $RW_DIR/roce-watch.sh resume"
}
cmd_resume(){
  local pa
  take_lock -w 30 || die "a poll or a rollback holds the lock: see status"
  [ -s "$REC" ] || die "not armed"
  [ -e "$RW_DIR/PAUSED" ] || die "not paused"
  load_rec; NOW=$(now)
  if ! arm_verify; then die "resume: the engine does not verify: still PAUSED (the misses above). Fix it, or roll back by hand and run stop"; fi
  pa=$(num "$(kv_get "$RW_DIR/PAUSED" at)" "$NOW")
  PAUSED_TOTAL=$((PAUSED_TOTAL + NOW - pa)); ARMED_AT=$NOW; SCAN_FROM=$U_start; NR0=$U_nr; INV0=$U_inv
  WD0=$(num "$(kv_get "$WD_STATE" last_restart)")
  write_rec; rm -f "$RW_DIR/PAUSED" "$ST"; load_rec
  say "resume: paused $(( (NOW - pa) / 60 )) min; new baseline: engine start $(utc "$SCAN_FROM"), NRestarts $NR0, InvocationID ${INV0:0:12}; deadline $(utc "$DEADLINE")"
  ensure_timer
}
cmd_stop(){
  take_lock -w 30 || die "a poll or a rollback holds the lock: see status"
  [ -d "$RW_DIR" ] || die "no $RW_DIR"
  NOW=$(now)
  printf 'at_utc=%s\nended_utc=%s\nby=%s\nreason=%s\n' "$(utc "$NOW")" "$(utc "$NOW")" "$(id -un)" "${REST[*]:-by hand}" | put "$RW_DIR/STOPPED"
  say "stop: the watch ends with no rollback (${REST[*]:-by hand})"
  stop_timer
}
cmd_status(){
  local t
  NOW=$(now)
  echo "== $RW_DIR"
  if [ -s "$REC" ]; then load_rec; sed -n '/^[A-Z]/p' "$REC"; echo "deadline $(utc "$DEADLINE") ($(hms $((DEADLINE - NOW))) left)"; else echo "not armed"; fi
  for t in PAUSED ROLLBACK-STARTED $TERMINAL; do [ -e "$RW_DIR/$t" ] && { echo "-- $t"; head -n 8 "$RW_DIR/$t"; }; done
  echo "-- timer: $(timeout 10 systemctl is-active "$WU.timer" 2>/dev/null)"
  timeout 10 systemctl list-timers --all --no-pager "$WU.timer" 2>/dev/null | sed -n 2p
  echo "-- the last log lines"; tail -n 5 "$LOGF" 2>/dev/null
}

# ------------------------------------------------------------------ dry: simulated readings, exact commands
DRY_CASES="none roce-error stall restart-nrestarts restart-invocation restart-autorestart restart-watchdog broken foreign sha-bad never-healthy roce-left deadline rolled-back"
S_MOVED=0; S_RESTARTED=0; DRY_CASE=none
dry_effect(){ case "$*" in "mv -f "*) S_MOVED=1 ;; *"systemctl restart"*) S_RESTARTED=1 ;; esac; }
sim_sha(){
  case "$1" in
    "$LOCAL") if [ "$S_MOVED" = 1 ]; then echo "$BASE_SHA"; elif [ "$DRY_CASE" = foreign ]; then printf 'f%.0s' {1..64}; echo; else echo "$ROCE_SHA"; fi ;;
    "$BASE_COPY") if [ "$DRY_CASE" = sha-bad ]; then printf 'b%.0s' {1..64}; echo; else echo "$BASE_SHA"; fi ;;
    *) echo "$BASE_SHA" ;;
  esac
}
sim_unit(){
  local a=active s=running nr=$NR0 inv=$INV0 st=$SCAN_FROM
  if [ "$S_RESTARTED" = 1 ]; then
    inv=dry-inv-after-rollback; nr=0; st=$((FAKE_NOW - 30))
    [ "$DRY_CASE" = never-healthy ] && { a=activating; s=start-pre; }
  else
    case "$DRY_CASE" in
      restart-nrestarts) nr=$((NR0 + 1)); inv=dry-inv-auto ;;
      restart-invocation) inv=dry-inv-unplanned ;;
      restart-autorestart) a=activating; s=auto-restart ;;
    esac
  fi
  printf 'ActiveState=%s\nSubState=%s\nNRestarts=%s\nInvocationID=%s\nResult=success\nExecMainStartTimestamp=@%s\n' "$a" "$s" "$nr" "$inv" "$st"
}
sim_health(){
  if [ "$S_RESTARTED" = 1 ]; then [ "$DRY_CASE" = never-healthy ] || echo '{"ok": true, "iteration_s": 0.0}'; return; fi
  case "$DRY_CASE" in
    stall) echo '{"ok": true, "iteration_s": 200.4}' ;;
    broken) echo '{"ok": false, "broken": "RuntimeError: RoCE all-gather failed (sequence 9, peer 2, hca 1)", "iteration_s": 0.0}' ;;
    restart-autorestart) echo "" ;;
    *) echo '{"ok": true, "iteration_s": 0.0}' ;;
  esac
}
sim_metrics(){ if [ "$DRY_CASE" = broken ] && [ "$S_RESTARTED" = 0 ]; then echo "tensorfold_health:ok 0"; else echo "tensorfold_health:ok 1"; fi; }
sim_logs(){
  printf 'spark1-rank0\t[tensorfold] all-gathers up to 1024 KiB over RoCE (rank 1 over rocep1s0f0+roceP2p1s0f0; rank 2 over rocep1s0f1+roceP2p1s0f1; b12x'"'"'s RoCEnante transport), larger ones over NCCL\n'
  case "$DRY_CASE" in roce-error|sha-bad|never-healthy|roce-left) printf 'spark2-rank\tRuntimeError: RoCE all-gather failed (sequence 41, peer 0, hca 1): work completion error [doorbell 9]\n' ;; esac
  return 0
}
sim_wd(){ if [ "$DRY_CASE" = restart-watchdog ]; then echo "$((FAKE_NOW - 40)) 1 1"; else echo "$WD0 0 0"; fi; }
sim_rocup(){ if [ "$S_RESTARTED" = 1 ] && [ "$DRY_CASE" != roce-left ]; then echo 0; else echo 1; fi; }
cmd_dry(){
  local c cases=${REST[*]:-$DRY_CASES} tmp
  tmp=$(mktemp -d /tmp/roce-watch-dry.XXXXXX) || die "mktemp failed"
  echo "== roce-watch dry: simulated readings; every command is printed, none runs; state in $tmp (removed at the end)"
  for c in $cases; do
    [[ " $DRY_CASES " == *" $c "* ]] || { echo "unknown case $c (cases: $DRY_CASES)"; continue; }
    echo; echo "== case $c"
    (
      DRY=1; DRY_CASE=$c; MODE=dry; RW_DIR=$tmp/$c; mkdir -p "$RW_DIR"
      REC=$RW_DIR/watch.env; ST=$RW_DIR/state; LOGF=$RW_DIR/watch.log; BASE_COPY=$RW_DIR/local.sh.baseline; RB=$RW_DIR/ROLLBACK-STARTED
      FAKE_NOW=$(date +%s)
      BASE_SHA=${ARG_BASE:-5728257bfc5a976d958a649a965c867c541fd861662301718a1c1a123636a7e5}
      ROCE_SHA=${ARG_ROCE:-ade39bc5b36e59609d04e4114736dfcd6ee5d9abfe70d0cf6780e0f51befe698}
      HOURS=48; START=$((FAKE_NOW - 3600)); ARMED_AT=$START; SCAN_FROM=$((START - 400)); NR0=0; INV0=dry-inv-at-arm; WD0=0; PAUSED_TOTAL=0
      [ "$c" = deadline ] && START=$((FAKE_NOW - 48 * 3600 - 60))
      write_rec
      [ "$c" = rolled-back ] && printf 'result=ROLLED-BACK\nended_utc=%s\n' "$(utc "$FAKE_NOW")" > "$RW_DIR/ROLLED-BACK"
      cmd_run
    )
  done
  rm -rf "$tmp"
}

# ------------------------------------------------------------------ main
MODE=${1:-}; [ $# -gt 0 ] && shift
ARG_BASE=""; ARG_ROCE=""; ARG_HOURS=""; REST=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base-sha) ARG_BASE=${2:-}; shift ;;
    --roce-sha) ARG_ROCE=${2:-}; shift ;;
    --hours) ARG_HOURS=${2:-}; shift ;;
    *) REST+=("$1") ;;
  esac
  shift
done
case "$MODE" in
  run) cmd_run ;; check) cmd_check ;; dry) cmd_dry ;; start) cmd_start ;; pause) cmd_pause ;;
  resume) cmd_resume ;; stop) cmd_stop ;; status) cmd_status ;;
  -h|--help|help|"") sed -n '2,/^set -uo/p' "$0" | sed '$d'; [ -n "$MODE" ] || exit 2 ;;
  *) echo "unknown mode '$MODE' (start run check dry pause resume stop status)"; exit 2 ;;
esac
