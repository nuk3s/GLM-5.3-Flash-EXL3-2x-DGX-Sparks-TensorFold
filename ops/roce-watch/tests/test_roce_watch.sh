#!/bin/bash
# Stub tests for roce-watch.sh (workstation and CI; no host is touched). systemctl, sudo, systemd-run, journalctl,
# docker, curl and ssh are stubs on PATH that answer from files in a temp dir. cp and mv log each call, then run the
# real binaries. The ssh stub runs the script's exact remote command string locally against the docker stub, so the
# remote quoting is tested too. Each case arms a fresh watch (the real `start`) on a healthy COMM=roce engine,
# changes one input, runs one poll at a fake clock and checks what the poll did.
#   A  start: arms on the adopted engine; keeps the record on a second start; refuses a wrong engine; the timer's user
#   B  no trigger: no action (with the RoCE-up line and OLD error lines from before the scan start)
#   C  each trigger (and each roce.py pattern): exactly one rollback; the next poll does nothing
#   D  the staged copy fails its sha check: no restart, a page
#   E  the new engine never answers: a page with the by-hand steps, no second restart
#   F  the unit fails after the restart: an early page; G the old engine answers ok while it stops: not counted
#   H  the new engine still shows RoCE: a page;  I  the deadline: "passed, COMM=roce kept", nothing touched
#   J  ROLLED-BACK already: no action;  K pause and resume;  L local.sh is neither sha: one page, no action
#   M  a worker out of reach; N a stop by hand; O a rollback cut after its restart; P check writes nothing
#   Q  dry runs nothing; R ntfy down; S local.sh is the baseline already; T stop
#   Review fixes: U the GLM marker off (one page); V a bad record (one page); W a rollback continued after a long
#   reboot (the wait clock starts again); A start warns when the first poll will roll back; I the pass message gives
#   the real config; every rollback leaves local.sh at mode 664 and the staged copy at 444
# Usage: bash tests/test_roce_watch.sh -> PASS/FAIL per check; the exit code is the FAIL count.
# shellcheck disable=SC2016,SC2034  # check() evals its single-quoted conditions (and the names they read) on purpose
set -u
H="$(cd "$(dirname "$0")/.." && pwd)"; W="$H/roce-watch.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
F=0; NP=0
pass(){ NP=$((NP + 1)); echo "PASS $*"; }
fail(){ F=$((F + 1)); echo "FAIL $*"; }
check(){ if eval "$2"; then pass "$1"; else fail "$1"; echo "     ($2)"; sed 's/^/     | /' "$T/out" | tail -n 8; fi; }
REAL_CP=$(command -v cp); REAL_MV=$(command -v mv)
B="$T/bin"; S="$T/s"; mkdir -p "$B"
T0=1800000000
BASE_TXT=$'# baseline\nCOMM=nccl\n'; ROCE_TXT=$'# production roce\nCOMM=roce\n'; OTHER_TXT=$'# by hand\nCOMM=roce\nX=1\n'
BASE=$(printf '%s' "$BASE_TXT" | sha256sum | cut -d' ' -f1); ROCE=$(printf '%s' "$ROCE_TXT" | sha256sum | cut -d' ' -f1)
# real lines from spark1's glm53-serve journal, window k8 (2026-11-07): start.sh's banner (every boot, nccl too) and arm R's
# rank-0 RoCE-up line. None of them is an error.
BANNER0="[start.sh]   rank 0: RoCE rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1 (GID 3)"
BANNER1="[start.sh]   rank 1: RoCE rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1 (GID 3), link to the head 198.18.0.189 <-> 198.18.0.53"
BANNER2="[start.sh]   rank 2: RoCE rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1 (GID 3), link to the head 198.18.4.216 <-> 198.18.4.53"
UP="[tensorfold] all-gathers up to 1024 KiB over RoCE (rank 1 over rocep1s0f0+roceP2p1s0f0; rank 2 over rocep1s0f1+roceP2p1s0f1; b12x's RoCEnante transport), larger ones over NCCL"

# ------------------------------------------------------------------ stubs
cat > "$B/systemctl" <<'X'
#!/bin/bash
S=$FAKE_S; echo "systemctl $*" >> "$S/calls"
g(){ cat "$S/$1" 2>/dev/null; }
case "$1" in
  show)
    if [ -e "$S/restarted" ]; then
      n=$(( $(g shown || echo 0) + 1 )); echo "$n" > "$S/shown"
      a=active; s=running; nr=0; inv=inv-after; st=$(g start_after)
      case "$(g after)" in
        never) a=activating; s=start-pre ;;
        failed) a=failed; s=failed ;;
        loads) [ "$n" -le 3 ] && { a=activating; s=start-pre; } ;;
        slowstop) # the restart job is queued (still active, old InvocationID), then the stop; the old engine answers ok
                  if [ "$n" -le 1 ]; then inv=$(g inv); st=$(g start)
                  elif [ "$n" -le 3 ]; then a=deactivating; s=stop-sigterm; inv=$(g inv); st=$(g start); fi ;;
      esac
    else a=$(g active); s=$(g sub); nr=$(g nr); inv=$(g inv); st=$(g start); fi
    for p in "$@"; do
      case "$p" in
        ActiveState) echo "ActiveState=$a" ;; SubState) echo "SubState=$s" ;; NRestarts) echo "NRestarts=$nr" ;;
        InvocationID) echo "InvocationID=$inv" ;; Result) echo "Result=$(g result)" ;;
        ExecMainStartTimestamp) echo "ExecMainStartTimestamp=@$st" ;;
      esac
    done ;;
  is-active) if [ -e "$S/timer_active" ]; then echo active; else echo inactive; exit 3; fi ;;
  restart) touch "$S/restarted" ;;
  stop) case "$*" in *glm53-roce-watch.timer*) rm -f "$S/timer_active" ;; esac ;;
esac
exit 0
X
cat > "$B/sudo" <<'X'
#!/bin/bash
[ "$1" = -n ] && shift
echo "sudo $*" >> "$FAKE_S/calls"
exec "$@"
X
cat > "$B/systemd-run" <<'X'
#!/bin/bash
echo "systemd-run $*" >> "$FAKE_S/calls"; touch "$FAKE_S/timer_active"
X
cat > "$B/journalctl" <<'X'
#!/bin/bash
S=$FAKE_S; since=0
while [ $# -gt 0 ]; do case "$1" in --since) since=${2#@}; shift 2 ;; *) shift ;; esac; done
for f in journal $([ -e "$S/restarted" ] && echo journal_after); do
  [ -e "$S/$f" ] && awk -v s="$since" '{ t = $0; sub(/\|.*/, "", t) } t + 0 >= s + 0 { sub(/^[0-9]+\|/, ""); print }' "$S/$f"
done
exit 0
X
cat > "$B/docker" <<'X'
#!/bin/bash
S=$FAKE_S; echo "docker ${FAKE_NODE:+[$FAKE_NODE] }$*" >> "$S/calls"
[ "$1" = logs ] || exit 0
shift; since=0
while [ $# -gt 1 ]; do case "$1" in --since) since=$2; shift 2 ;; *) shift ;; esac; done
if [ -n "${FAKE_NODE:-}" ]; then f=remote_$FAKE_NODE
else f=dlog; if [ -e "$S/restarted" ]; then f=dlog_after; [ "$(cat "$S/after")" = roce-left ] && f=dlog_after_roce; fi; fi
[ -e "$S/$f" ] || { echo "Error response from daemon: No such container: glm53-flash-tf" >&2; exit 1; }
awk -v s="$since" '{ t = $0; sub(/\|.*/, "", t) } t + 0 >= s + 0 { sub(/^[0-9]+\|/, ""); print }' "$S/$f"
X
cat > "$B/curl" <<'X'
#!/bin/bash
S=$FAKE_S; url="" data="" hdr=""
while [ $# -gt 0 ]; do
  case "$1" in -d) data=$2; shift 2 ;; -H) hdr+="$2;"; shift 2 ;; -o|-m|-w) shift 2 ;; -s|-sk|-k) shift ;; *) url=$1; shift ;; esac
done
case "$url" in
  */health)
    if [ -e "$S/restarted" ]; then
      case "$(cat "$S/after")" in
        never|failed) exit 7 ;;
        loads) [ "$(cat "$S/shown")" -le 3 ] && exit 7 ;;
        slowstop) [ "$(cat "$S/shown")" -le 3 ] && { cat "$S/health"; exit 0; } ;;
      esac
      cat "$S/health_after"; exit 0
    fi
    [ -s "$S/health" ] && cat "$S/health" || exit 7 ;;
  */metrics) cat "$S/metrics" 2>/dev/null ;;
  https://ntfy*) echo "${url##*/}|$hdr|$data" >> "$S/ntfy"; if [ -e "$S/ntfy_down" ]; then printf 000; exit 7; fi; printf 200 ;;
esac
exit 0
X
cat > "$B/ssh" <<'X'
#!/bin/bash
S=$FAKE_S; host=""; for a in "$@"; do case "$a" in user@*) host=$a ;; esac; done
echo "ssh $host" >> "$S/calls"
case "$host" in *@192.0.2.180) n=spark2 ;; *@192.0.2.216) n=spark3 ;; *) exit 255 ;; esac
[ -e "$S/ssh_down_$n" ] && exit 255
FAKE_NODE=$n exec bash -c "${@: -1}"
X
printf '#!/bin/bash\necho "cp $*" >> "$FAKE_S/calls"\nexec %s "$@"\n' "$REAL_CP" > "$B/cp"
printf '#!/bin/bash\necho "mv $*" >> "$FAKE_S/calls"\nexec %s "$@"\n' "$REAL_MV" > "$B/mv"
chmod +x "$B"/*

# ------------------------------------------------------------------ one case
GH="$T/home"; RW="$GH/roce-watch"; LSH="$GH/kit/scripts/local.sh"
RUN(){   # RUN AT MODE [ARGS]: the script with the stubs, at fake time AT; output in $T/out
  local at=$1; shift
  env PATH="$B:$PATH" FAKE_S="$S" GLM_HOME="$GH" RW_FAKE_NOW="$at" NTFY_BASE=https://ntfy.test GLM_HOSTS_CONF=/dev/null \
    bash "$W" "$@" > "$T/out" 2>&1
  RC=$?
}
fresh(){   # a healthy COMM=roce engine (started T0-900), armed at T0-600 by the real `start`
  rm -rf "$S" "$GH"; mkdir -p "$S" "$GH/kit/scripts" "$GH/state" "$RW"
  printf '%s' "$ROCE_TXT" > "$LSH"; printf '%s' "$BASE_TXT" > "$RW/local.sh.baseline"; cp "$W" "$RW/roce-watch.sh"
  chmod 664 "$LSH"; chmod 444 "$RW/local.sh.baseline"
  touch "$GH/GLM_ACTIVE"
  printf 'last_restart=1700000000\nrestarts=\n' > "$GH/state/watchdog.state"
  echo "2023-11-14T22:13:20Z glm53-watchdog: RESTART glm53-serve: an old one (restart 1 of 3 in this hour)" > "$GH/state/watchdog.log"
  echo active > "$S/active"; echo running > "$S/sub"; echo 0 > "$S/nr"; echo inv-1 > "$S/inv"; echo success > "$S/result"
  echo $((T0 - 900)) > "$S/start"; echo $((T0 + 60)) > "$S/start_after"; echo healthy > "$S/after"
  echo '{"ok": true, "iteration_s": 0.0, "requests_running": 0}' > "$S/health"; cp "$S/health" "$S/health_after"
  echo "tensorfold_health:ok 1" > "$S/metrics"
  printf '%s|%s\n%s|%s\n' $((T0 - 3000)) "RuntimeError: RoCE all-gather failed (sequence 3, peer 1, hca 0): an OLD engine" $((T0 - 890)) "$UP" > "$S/journal"
  for l in "$BANNER0" "$BANNER1" "$BANNER2"; do echo "$((T0 - 895))|$l" >> "$S/journal"; done   # start.sh prints these at every boot
  printf '%s|%s\n' $((T0 - 890)) "$UP" > "$S/dlog"
  printf '%s|%s\n' $((T0 + 70)) "[tensorfold] serving GLM-5.3-Flash-EXL3 at http://0.0.0.0:8888/v1 on CUDA, rank 0 of 3" > "$S/dlog_after"
  printf '%s|%s\n' $((T0 + 70)) "$UP" > "$S/dlog_after_roce"
  for n in spark2 spark3; do
    printf '%s|%s\n%s|%s\n' $((T0 - 5000)) "RuntimeError: RoCE all-gather could not connect: an OLD engine" $((T0 - 880)) "[tensorfold] rank ready" > "$S/remote_$n"
  done
  RUN $((T0 - 600)) start --base-sha "$BASE" --roce-sha "$ROCE"
  ARM_RC=$RC; : > "$S/calls"; : > "$S/ntfy"
}
restarts(){ grep -c '^systemctl restart' "$S/calls"; }
nt(){ grep -c "^$1|" "$S/ntfy"; }                   # ntfy posts to a topic
cfg(){ case "$(sha256sum < "$LSH" | cut -d' ' -f1)" in "$BASE") echo base ;; "$ROCE") echo roce ;; *) echo other ;; esac; }
rolled_once(){   # the checks every "one rollback" case makes; then one more poll must do nothing
  check "$1: one restart" '[ "$(restarts)" = 1 ]'
  check "$1: local.sh is the baseline" '[ "$(cfg)" = base ]'
  PAT=$2   # check() evals in its own frame, where $2 is the condition
  check "$1: ROLLED-BACK with the evidence" '[ -e "$RW/ROLLED-BACK" ] && grep "^why=" "$RW/ROLLED-BACK" | grep -qF -- "$PAT" && grep -q "^result=ROLLED-BACK" "$RW/ROLLED-BACK"'
  check "$1: one critical page" '[ "$(nt alerts-critical)" = 1 ] && grep -q "rolled back to COMM=nccl" "$S/ntfy"'
  check "$1: the timer stopped" '[ ! -e "$S/timer_active" ]'
  check "$1: local.sh mode 664, the staged copy still 444" '[ "$(stat -c %a "$LSH")" = 664 ] && [ "$(stat -c %a "$RW/local.sh.baseline")" = 444 ]'
  RUN $((T0 + 3000)) run
  check "$1: the next poll does nothing" '[ "$(restarts)" = 1 ] && [ "$(nt alerts-critical)" = 1 ] && grep -q "the watch ended (ROLLED-BACK" "$T/out"'
}

# ------------------------------------------------------------------ A start
fresh
check "A start arms the adopted engine" '[ "$ARM_RC" = 0 ] && grep -q "^NR0=0$" "$RW/watch.env" && grep -q "^INV0=inv-1$" "$RW/watch.env" && grep -q "^SCAN_FROM=$((T0 - 900))$" "$RW/watch.env" && [ -e "$S/timer_active" ]'
check "A start passes both shas (not hard-coded)" 'grep -q "^BASE_SHA=$BASE$" "$RW/watch.env" && grep -q "^ROCE_SHA=$ROCE$" "$RW/watch.env"'
RUN $((T0 + 100)) start --base-sha "$BASE" --roce-sha "$ROCE"
check "A a second start keeps the record and starts no second timer" '[ "$RC" = 0 ] && grep -q "armed already" "$T/out" && grep -q "^START=$((T0 - 600))$" "$RW/watch.env" && ! grep -q systemd-run "$S/calls"'
check "A a second start on the same engine has no WARNING" '! grep -q "WILL roll back" "$T/out"'
rm -f "$S/timer_active"; echo inv-2 > "$S/inv"; : > "$S/calls"
RUN $((T0 + 200)) start
check "A start after an engine restart (a reboot): says the first poll WILL roll back, the rule unchanged" '[ "$RC" = 0 ] && grep -q "the engine restarted since the watch armed" "$T/out" && grep -q "The first poll (30 s after the timer starts) WILL roll back. To keep roce, run pause, then resume" "$T/out" && grep -q systemd-run "$S/calls" && grep -q "^INV0=inv-1$" "$RW/watch.env"'
RUN $((T0 + 210)) run
check "A ... and the first poll does roll back" '[ "$(restarts)" = 1 ] && [ -e "$RW/ROLLED-BACK" ]'
fresh; RUN "$T0" pause planned reboot; echo inv-2 > "$S/inv"; rm -f "$S/timer_active"; RUN $((T0 + 200)) start
check "A start while paused: says PAUSED and resume, no WARNING" '[ "$RC" = 0 ] && grep -q "the watch is PAUSED" "$T/out" && ! grep -q "WILL roll back" "$T/out"'
for c in base noup nr health; do
  rm -rf "$S" "$GH"; fresh
  rm -f "$RW/watch.env"; : > "$S/calls"
  case $c in
    base) printf '%s' "$BASE_TXT" > "$LSH" ;; noup) sed -i '/over RoCE/d' "$S/dlog" ;;
    nr) echo 1 > "$S/nr" ;; health) echo '{"ok": false, "broken": "x"}' > "$S/health" ;;
  esac
  RUN $((T0 - 600)) start --base-sha "$BASE" --roce-sha "$ROCE"
  check "A start refuses ($c)" '[ "$RC" != 0 ] && [ ! -e "$RW/watch.env" ] && ! grep -q systemd-run "$S/calls" && grep -q MISS "$T/out"'
done
# the timer's user: GLM_USER and GLM_USER_HOME (hosts.conf) when set, else the user that runs start, with its HOME
fresh; rm -f "$RW/watch.env" "$S/timer_active"; : > "$S/calls"
RUN $((T0 - 600)) start --base-sha "$BASE" --roce-sha "$ROCE"
check "A the timer runs as the caller when GLM_USER is unset" '[ "$RC" = 0 ] && grep "^systemd-run " "$S/calls" | grep -qF -- " -p User=$(id -un) -p Group=$(id -un) -p Environment=HOME=$HOME "'
fresh; rm -f "$RW/watch.env" "$S/timer_active"; : > "$S/calls"
GLM_USER=svc GLM_USER_HOME=/srv/svc RUN $((T0 - 600)) start --base-sha "$BASE" --roce-sha "$ROCE"
check "A the timer runs as GLM_USER with GLM_USER_HOME when hosts.conf sets them" '[ "$RC" = 0 ] && grep "^systemd-run " "$S/calls" | grep -qF -- " -p User=svc -p Group=svc -p Environment=HOME=/srv/svc "'

# ------------------------------------------------------------------ B no trigger
fresh; RUN "$T0" run
check "B no trigger: no restart, no page" '[ "$(restarts)" = 0 ] && [ ! -s "$S/ntfy" ] && [ "$(cfg)" = roce ]'
check "B no trigger: one log line; start.sh banners, the RoCE-up line and old errors ignored" '[ "$(grep -c " poll cfg=" "$RW/watch.log")" = 1 ] && grep -q "err=0/0/0 up=2 " "$RW/watch.log" && grep -q -- "-> ok, 47h50m left" "$RW/watch.log"'
check "B no trigger: the three nodes read" 'grep -q "nodes=spark1,spark2,spark3" "$RW/watch.log"'

# ------------------------------------------------------------------ C the triggers
fresh; echo "$((T0 - 30))|Traceback ... RuntimeError: RoCE all-gather failed (sequence 41, peer 2, hca 1): wait timed out [doorbell 9]" >> "$S/journal"
RUN "$T0" run; rolled_once "C1 roce-error in the journal" "roce-error"
fresh; echo "$((T0 - 30))|RuntimeError: RoCE all-gather could not connect: rdma connect" >> "$S/dlog"
RUN "$T0" run; rolled_once "C2 roce-error in the spark1 rank-0 log" "spark1-rank"
fresh; echo "$((T0 - 30))|RuntimeError: RoCE all-gather setup failed on some rank: x" >> "$S/remote_spark3"
RUN "$T0" run; rolled_once "C3 roce-error in the spark3 rank log (ssh)" "spark3-rank"
for p in "RoCE all-gather failed (sequence 1, peer 0, hca 0)" "RoCE all-gather could not connect: x" "RoCE all-gather setup failed on some rank: x" \
         "RoCE routes: invalid RoCE route to rank 2" "RoCE: no HCA of rank(s) 0-2 shares a subnet" "RoCE layout refused world 3, slot 4096" \
         "unexpected RoCE proxy ABI version" "building the RoCE proxy failed: gcc" "the RoCE all-gather needs a C compiler and libibverbs headers" \
         "TF_ROCE_WAIT_S: 1 to 3600 seconds, not 'x'"; do
  fresh; echo "$((T0 - 30))|ValueError: $p" >> "$S/remote_spark2"; RUN "$T0" run
  check "C4 roce.py pattern fires: ${p:0:40}" '[ "$(restarts)" = 1 ] && grep -q "^why=roce-error" "$RW/ROLLED-BACK"'
done
fresh; echo '{"ok": true, "iteration_s": 200.4}' > "$S/health"; RUN "$T0" run; rolled_once "C5 stall: one read at 200 s" "stall: /health iteration_s 200.4"
fresh; echo '{"ok": true, "iteration_s": 130.0}' > "$S/health"; RUN "$T0" run
check "C5 stall: 130 s once is pending only" '[ "$(restarts)" = 0 ] && grep -q "^stall_since=$T0$" "$RW/state"'
RUN $((T0 + 60)) run; rolled_once "C5 stall: over 120 s on two reads 60 s apart" "over 120 s since"
fresh; echo '{"ok": true, "iteration_s": 130.0}' > "$S/health"; RUN "$T0" run
echo '{"ok": true, "iteration_s": 100.0}' > "$S/health"; RUN $((T0 + 60)) run
echo '{"ok": true, "iteration_s": 125.0}' > "$S/health"; RUN $((T0 + 120)) run
check "C5 stall: a read at or under 120 s clears the pending state" '[ "$(restarts)" = 0 ] && grep -q "^stall_since=$((T0 + 120))$" "$RW/state"'
fresh; rm -f "$GH/GLM_ACTIVE"; echo '{"ok": true, "iteration_s": 400.0}' > "$S/health"; RUN "$T0" run
check "C5 stall: no GLM marker, no stall (the rule needs glm53_active)" '[ "$(restarts)" = 0 ]'
fresh; echo "$((T0 - 30))|Timeout (0:05:00)!" >> "$S/journal"; RUN "$T0" run; rolled_once "C6 stall: the faulthandler line" "faulthandler"
fresh; echo 1 > "$S/nr"; RUN "$T0" run; rolled_once "C7 NRestarts rise" "NRestarts 1, was 0"
fresh; echo inv-2 > "$S/inv"; RUN "$T0" run; rolled_once "C8 a new InvocationID" "a new start with no pause"
fresh; echo activating > "$S/active"; echo auto-restart > "$S/sub"; : > "$S/health"; RUN "$T0" run
rolled_once "C9 auto-restart pending" "auto-restart pending"
fresh; echo failed > "$S/active"; echo failed > "$S/sub"; echo exit-code > "$S/result"; : > "$S/health"; RUN "$T0" run
rolled_once "C10 the unit failed" "glm53-serve failed (Result=exit-code)"
fresh; printf 'last_restart=%s\nrestarts=%s\n' $((T0 - 100)) $((T0 - 100)) > "$GH/state/watchdog.state"; RUN "$T0" run
rolled_once "C11 a glm53-watchdog restart (its state file)" "glm53-watchdog restarted"
fresh; echo "$(date -u -d @$((T0 - 100)) +%FT%TZ) glm53-watchdog: RESTART glm53-serve: /health ok false (restart 1 of 3 in this hour)" >> "$GH/state/watchdog.log"
RUN "$T0" run; rolled_once "C12 a glm53-watchdog restart (its log only)" "1 RESTART log line"
fresh; echo '{"ok": false, "broken": "RuntimeError: the two ranks are out of step after an error; restart both", "iteration_s": 0.0}' > "$S/health"
RUN "$T0" run; rolled_once "C13 /health ok false" "broken: /health ok false, broken: RuntimeError: the two ranks"
fresh; echo "tensorfold_health:ok 0" > "$S/metrics"; RUN "$T0" run; rolled_once "C14 /metrics tensorfold_health:ok 0" "tensorfold_health:ok 0"
fresh; echo "$((T0 - 30))|[tensorfold] engine broken; TF_GLM_EXIT_ON_BROKEN=1: exiting with code 1" >> "$S/remote_spark2"
RUN "$T0" run; rolled_once "C15 the latch line on spark2" "TF_GLM_EXIT_ON_BROKEN=1' line"

# ------------------------------------------------------------------ D-H rollback failures
fresh; chmod 644 "$RW/local.sh.baseline"; echo "tampered" >> "$RW/local.sh.baseline"; echo 1 > "$S/nr"; RUN "$T0" run   # 444 refuses the write: open it first
check "D sha check fails: no restart" '[ "$(restarts)" = 0 ] && [ "$(cfg)" = roce ]'
check "D sha check fails: a page, ROLLBACK-FAILED, the timer stopped" '[ "$(nt alerts-critical)" = 1 ] && grep -q "NOT restarted" "$S/ntfy" && [ -e "$RW/ROLLBACK-FAILED" ] && [ ! -e "$S/timer_active" ]'
RUN $((T0 + 60)) run
check "D the next poll does nothing" '[ "$(restarts)" = 0 ] && [ "$(nt alerts-critical)" = 1 ]'
fresh; echo never > "$S/after"; echo 1 > "$S/nr"; RUN "$T0" run
check "E never healthy: one restart, then a page with the by-hand steps" '[ "$(restarts)" = 1 ] && grep -q "rollback FAILED" "$S/ntfy" && grep -q "By hand on spark1" "$S/ntfy" && grep -q "in 1500s" "$RW/ROLLBACK-FAILED"'
check "E never healthy: local.sh stays the baseline, no second restart" '[ "$(cfg)" = base ] && grep -q "no second restart" "$RW/ROLLBACK-FAILED"'
RUN $((T0 + 3000)) run
check "E the next poll does nothing" '[ "$(restarts)" = 1 ] && [ "$(nt alerts-critical)" = 1 ]'
fresh; echo failed > "$S/after"; echo 1 > "$S/nr"; RUN "$T0" run
check "F unit failed after the restart: an early page" '[ "$(restarts)" = 1 ] && grep -q "glm53-serve is failed" "$RW/ROLLBACK-FAILED" && ! grep -q "in 1500s" "$RW/ROLLBACK-FAILED"'
fresh; echo slowstop > "$S/after"; echo 1 > "$S/nr"; RUN "$T0" run
check "G old engine answers ok while it stops: waited for the new InvocationID" '[ "$(restarts)" = 1 ] && [ -e "$RW/ROLLED-BACK" ] && grep -q "InvocationID inv-after" "$RW/ROLLED-BACK" && [ "$(cat "$S/shown")" -ge 4 ]'
fresh; echo roce-left > "$S/after"; echo "$((T0 + 70))|$UP" > "$S/journal_after"; echo 1 > "$S/nr"; RUN "$T0" run
check "H the new engine still shows RoCE: a page, no second restart" '[ "$(restarts)" = 1 ] && [ -e "$RW/ROLLBACK-FAILED" ] && grep -q "still shows RoCE" "$RW/ROLLBACK-FAILED"'

# ------------------------------------------------------------------ I the deadline: pass keeps roce
fresh; sum0=$(sha256sum < "$LSH"); RUN $((T0 - 600 + 48 * 3600)) run
check "I deadline: 'passed, COMM=roce kept' to alerts, PASSED, the timer stopped" '[ "$(nt alerts)" = 1 ] && grep -q "watch passed, COMM=roce kept" "$S/ntfy" && [ -e "$RW/PASSED" ] && [ ! -e "$S/timer_active" ] && [ "$(nt alerts-critical)" = 0 ]'
check "I pass: no systemctl verb on glm53-serve (show only)" '! grep "^systemctl" "$S/calls" | grep -v "^systemctl show" | grep -q glm53-serve'
check "I pass: no cp or mv on local.sh, local.sh unchanged" '! grep -E "^(cp|mv) " "$S/calls" | grep -q "kit/scripts/local.sh" && [ "$(sha256sum < "$LSH")" = "$sum0" ] && [ "$(cfg)" = roce ]'
check "I pass: the only stop is this watch's own timer" '[ "$(grep -c "^systemctl stop" "$S/calls")" = 1 ] && grep -q "^systemctl stop glm53-roce-watch.timer$" "$S/calls" && [ "$(restarts)" = 0 ]'
RUN $((T0 + 48 * 3600)) run
check "I the next poll does nothing" '[ "$(nt alerts)" = 1 ] && grep -q "the watch ended (PASSED" "$T/out"'
fresh; echo 1 > "$S/nr"; RUN $((T0 - 600 + 48 * 3600)) run
check "I a trigger at the deadline still rolls back" '[ "$(restarts)" = 1 ] && [ -e "$RW/ROLLED-BACK" ] && [ ! -e "$RW/PASSED" ]'
fresh; printf '%s' "$BASE_TXT" > "$LSH"; RUN $((T0 - 600 + 48 * 3600)) run
check "I pass with the baseline put back by hand: the message says baseline, not roce kept; nothing touched" '[ "$(nt alerts)" = 1 ] && grep -q "watch passed, local.sh is the baseline" "$S/ntfy" && ! grep -q "COMM=roce kept" "$S/ntfy" && grep -q "someone put it back by hand" "$RW/PASSED" && [ "$(restarts)" = 0 ] && [ "$(cfg)" = base ]'

# ------------------------------------------------------------------ J-T
fresh; printf 'result=ROLLED-BACK\nended_utc=x\n' > "$RW/ROLLED-BACK"; echo 1 > "$S/nr"; RUN "$T0" run
check "J ROLLED-BACK already: no action" '[ "$(restarts)" = 0 ] && [ ! -s "$S/ntfy" ] && [ "$(cfg)" = roce ]'
fresh; RUN "$T0" pause planned restart for a kernel update
check "K pause" '[ "$RC" = 0 ] && [ -e "$RW/PAUSED" ]'
echo inv-2 > "$S/inv"; echo $((T0 + 300)) > "$S/start"; echo '{"ok": false, "broken": "x"}' > "$S/health"
RUN $((T0 + 60)) run
check "K paused: a new start and ok false do nothing" '[ "$(restarts)" = 0 ] && [ ! -s "$S/ntfy" ] && grep -q "paused since" "$T/out"'
RUN $((T0 + 400)) resume
check "K resume refuses an engine that does not verify (still paused)" '[ "$RC" != 0 ] && [ -e "$RW/PAUSED" ]'
echo '{"ok": true, "iteration_s": 0.0}' > "$S/health"; printf '%s|%s\n' $((T0 + 310)) "$UP" > "$S/dlog"
RUN $((T0 + 600)) resume
check "K resume takes a new baseline and adds the pause to the deadline" '[ "$RC" = 0 ] && [ ! -e "$RW/PAUSED" ] && grep -q "^INV0=inv-2$" "$RW/watch.env" && grep -q "^SCAN_FROM=$((T0 + 300))$" "$RW/watch.env" && grep -q "^PAUSED_TOTAL=600$" "$RW/watch.env"'
RUN $((T0 + 700)) run
check "K after resume: no trigger" '[ "$(restarts)" = 0 ] && grep -q -- "-> ok" "$T/out"'
fresh; printf '%s' "$OTHER_TXT" > "$LSH"; echo 1 > "$S/nr"; RUN "$T0" run
check "L local.sh is neither sha: one page, no restart, local.sh left as it is" '[ "$(restarts)" = 0 ] && [ "$(nt alerts-critical)" = 1 ] && grep -q "changed by hand" "$S/ntfy" && [ "$(cfg)" = other ] && ! grep -qE "^(cp|mv) .*kit/scripts/local.sh" "$S/calls"'
RUN $((T0 + 60)) run
check "L the next poll: no second page" '[ "$(nt alerts-critical)" = 1 ] && [ "$(restarts)" = 0 ] && grep -q "FOREIGN" "$T/out"'
fresh; touch "$S/ssh_down_spark2"; RUN "$T0" run
check "M spark2 out of reach: no trigger, logged" '[ "$(restarts)" = 0 ] && grep -q "nodes=spark1,spark2:noread,spark3" "$RW/watch.log"'
fresh; echo inactive > "$S/active"; echo dead > "$S/sub"; : > "$S/health"; RUN "$T0" run
check "N a stop by hand (inactive): no trigger" '[ "$(restarts)" = 0 ] && [ ! -s "$S/ntfy" ]'
fresh; printf '%s' "$BASE_TXT" > "$LSH"
printf 'at=%s\nat_utc=x\nwhy=restart: NRestarts 1\npre_inv=inv-1\nrestarted_at=%s\n' "$T0" "$T0" > "$RW/ROLLBACK-STARTED"; touch "$S/restarted"
RUN $((T0 + 120)) run
check "O a rollback cut after its restart: finished with no second restart" '[ "$(restarts)" = 0 ] && [ -e "$RW/ROLLED-BACK" ] && [ "$(nt alerts-critical)" = 1 ]'
fresh; echo 1 > "$S/nr"; before=$(cd "$RW" && find . -printf '%p %s %T@\n' | sort); : > "$S/calls"; RUN "$T0" check
after=$(cd "$RW" && find . -printf '%p %s %T@\n' | sort)
check "P check: nothing written, no change made" '[ "$RC" = 0 ] && [ "$before" = "$after" ] && ! grep -qE "^(systemctl (restart|stop|start|reset-failed)|systemd-run|cp |mv )" "$S/calls" && [ ! -s "$S/ntfy" ]'
check "P check: says it would roll back" 'grep -q "run would: ROLL BACK" "$T/out" && grep -q "NRestarts 1, was 0" "$T/out"'
rm -rf "$S" "$GH"; fresh; rm -f "$RW/watch.env"; : > "$S/calls"; RUN "$T0" check --base-sha "$BASE" --roce-sha "$ROCE"
check "P check unarmed: no trigger, start would arm" '[ "$RC" = 0 ] && grep -q "^fired: none" "$T/out" && grep -q "start would: arm" "$T/out" && [ ! -e "$RW/watch.env" ]'
fresh; : > "$S/calls"; RUN "$T0" dry
check "Q dry: runs nothing, prints the rollback commands" '[ "$RC" = 0 ] && ! grep -qE "^(systemctl (restart|stop|start|reset-failed)|systemd-run|sudo )" "$S/calls" && ! grep -E "^(cp|mv) " "$S/calls" | grep -qE "kit/scripts/local.sh|$RW" && [ ! -s "$S/ntfy" ] && grep -q "would run: timeout 30 sudo -n systemctl restart --no-block glm53-serve.service" "$T/out" && [ "$(grep -c "^== case" "$T/out")" = 14 ]'
fresh; touch "$S/ntfy_down"; echo 1 > "$S/nr"; RUN "$T0" run
check "R ntfy down: the rollback still ends, the log says so" '[ "$(restarts)" = 1 ] && [ -e "$RW/ROLLED-BACK" ] && grep -q "ntfy alerts-critical: FAILED three times" "$RW/watch.log"'
fresh; printf '%s' "$BASE_TXT" > "$LSH"; echo inv-2 > "$S/inv"; sed -i '/over RoCE/d' "$S/dlog"; RUN "$T0" run
check "S local.sh is the baseline and a COMM=nccl engine serves: no restart" '[ "$(restarts)" = 0 ] && grep -q "no restart was needed" "$RW/ROLLED-BACK"'
fresh; RUN "$T0" stop operator ends it
check "T stop: STOPPED, the timer stopped" '[ "$RC" = 0 ] && [ -e "$RW/STOPPED" ] && [ ! -e "$S/timer_active" ]'
echo 1 > "$S/nr"; RUN $((T0 + 60)) run
check "T after stop: no action" '[ "$(restarts)" = 0 ] && [ ! -s "$S/ntfy" ]'

# ------------------------------------------------------------------ U-W (review fixes)
fresh; rm -f "$GH/GLM_ACTIVE"; RUN "$T0" run
check "U marker off: one page, marker=off in the poll line, no restart" '[ "$(nt alerts-critical)" = 1 ] && grep -q "GLM_ACTIVE marker is off" "$S/ntfy" && grep -q " marker=off " "$RW/watch.log" && [ "$(restarts)" = 0 ]'
RUN $((T0 + 60)) run
check "U marker still off: no second page" '[ "$(nt alerts-critical)" = 1 ]'
touch "$GH/GLM_ACTIVE"; RUN $((T0 + 120)) run
check "U marker back: the page state clears" '! grep -q "^marker_sent=1$" "$RW/state" && grep -q " marker=on " "$T/out"'
rm -f "$GH/GLM_ACTIVE"; RUN $((T0 + 180)) run
check "U marker off again: a new page" '[ "$(nt alerts-critical)" = 2 ]'
fresh; sed -i 's/^BASE_SHA=.*/BASE_SHA=bad/' "$RW/watch.env"; RUN "$T0" run
check "V a bad record: exit 1, one page, BAD-RECORD-PAGED" '[ "$RC" = 1 ] && [ "$(nt alerts-critical)" = 1 ] && grep -q "the record is bad" "$S/ntfy" && [ -e "$RW/BAD-RECORD-PAGED" ] && grep -q "no valid BASE_SHA" "$RW/watch.log"'
RUN $((T0 + 60)) run
check "V the next poll: logged again, no second page" '[ "$RC" = 1 ] && [ "$(nt alerts-critical)" = 1 ] && [ "$(grep -c "no valid BASE_SHA" "$RW/watch.log")" = 2 ]'
fresh; printf '%s' "$BASE_TXT" > "$LSH"; echo loads > "$S/after"
printf 'at=%s\nat_utc=x\nwhy=restart: NRestarts 1\npre_inv=inv-1\nrestarted_at=%s\n' $((T0 - 3000)) $((T0 - 3000)) > "$RW/ROLLBACK-STARTED"; touch "$S/restarted"
RUN "$T0" run
check "W a rollback continued 3000 s after its restart (a long reboot): the wait clock starts again, then ROLLED-BACK" '[ -e "$RW/ROLLED-BACK" ] && [ ! -e "$RW/ROLLBACK-FAILED" ] && grep -q "the wait clock starts again" "$RW/watch.log" && grep -q "^wait_restarted_at=$T0$" "$RW/ROLLED-BACK" && [ "$(cat "$S/shown")" -ge 4 ]'
check "W ... with no second restart" '[ "$(restarts)" = 0 ]'

echo "== $NP PASS, $F FAIL"
exit "$F"
