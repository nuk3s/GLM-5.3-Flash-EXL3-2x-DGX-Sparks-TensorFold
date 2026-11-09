#!/bin/bash
# glm53-memguard.sh start|stop: memguard for the GLM rank container on all three ranks. glm53-serve.service runs
# `start` as its last ExecStartPre and `stop` in ExecStopPost (as GLM_USER on spark1). Installed to
# $HOME/glm53/bin/ (docs/operations.md). Added 2026-11-02 for the GLM-5.3 cutover.
#
# The GLM kit has no memguard. A GB10 freezes before the kernel OOM killer acts, and the cluster's earlyoom
# in its percentage form (for example -m 2 -s 20) does not act while swap is mostly free. This script runs
# memguard.sh (the scripts/memguard.sh of another MiaAI kit: docs/operations.md gives its source and sha256),
# copied to $HOME/glm53/bin/memguard.sh on every node, with these numbers: SIGKILL
# (docker kill) of the rank under 2.5 GiB MemAvailable for 4 s, or under 1 GiB in two samples.
# A kill ends the rank, start.sh exits, systemd
# restarts the unit.
#
# Optional by installation: with no $HOME/glm53/bin/memguard.sh on spark1, `start` logs that and exits 0 (the
# operator's choice: GLM without memguard). When it is installed, a failed start on any node fails the unit
# start (no unguarded engine).
set -uo pipefail
# hosts.conf beside this script (GLM_HOSTS_CONF names another file) sets this cluster's values; without it the
# defaults below apply. hosts.conf.example lists every name.
_hc=${GLM_HOSTS_CONF:-$(dirname "$(readlink -f "$0")")/hosts.conf}
[ -z "${GLM_HOSTS_CONF:-}" ] || [ -r "$_hc" ] || { echo "glm53-memguard: cannot read GLM_HOSTS_CONF=$_hc" >&2; exit 1; }
[ ! -r "$_hc" ] || bash -n "$_hc" 2>/dev/null || { echo "glm53-memguard: syntax error in $_hc" >&2; exit 1; }
# shellcheck source=/dev/null
[ -r "$_hc" ] && . "$_hc"
GLM_HOME="${GLM_HOME:-$HOME/glm53}"
MG="$GLM_HOME/bin/memguard.sh"
CTR="${GLM_CONTAINER:-glm53-flash-tf}"
FLOOR="${GLM_MEMGUARD_GIB:-2.5}"
LOGF="$GLM_HOME/logs/memguard.log"
PIDF="$GLM_HOME/state/memguard.pid"
WORKER="${GLM_WORKER:-user@192.0.2.180}"
# rank 2, added 2026-11-06. The engine went to TP=3 on 2026-11-05 and this script still guarded two
# nodes, so the third rank had no memguard at all. Its
# only killer was earlyoom in the percentage form (-m 2 -s 80), which does not act while swap is
# mostly free. Requiring it here matches spark2's treatment and adds no new failure surface, because
# glm53-prestart.sh already refuses to start when this node's ssh is unreachable.
WORKER2="${GLM_WORKER2:-user@192.0.2.216}"
# GLM_PRINT_CONFIG=1: print the values this run would use, then exit (tests/test_hosts_conf.sh)
if [ "${GLM_PRINT_CONFIG:-}" = 1 ]; then
  for _v in GLM_HOME MG CTR FLOOR LOGF PIDF WORKER WORKER2; do declare -p "$_v" 2>/dev/null || echo "unset $_v"; done
  exit 0
fi
SSHO=(-n -o BatchMode=yes -o ConnectTimeout=8)
say(){ echo "glm53-memguard: $*"; }
wrun(){ timeout 30 ssh "${SSHO[@]}" "$WORKER" "$@"; }
w2run(){ timeout 30 ssh "${SSHO[@]}" "$WORKER2" "$@"; }

case "${1:-}" in
  start)
    if [ ! -s "$MG" ]; then
      say "no $MG on spark1: memguard is not installed, GLM runs without it (earlyoom is the only killer)"; exit 0
    fi
    mkdir -p "$GLM_HOME/logs" "$GLM_HOME/state"
    bash "$MG" start "$CTR" "$FLOOR" "$LOGF" "$PIDF" 4 1 || { say "start on spark1 FAILED"; exit 1; }
    if ! wrun "test -s $MG && mkdir -p $GLM_HOME/logs $GLM_HOME/state && bash $MG start $CTR $FLOOR $LOGF $PIDF 4 1"; then
      say "start on spark2 FAILED (is $MG there? copy it to every rank)"
      bash "$MG" stop "$PIDF" 2>/dev/null
      exit 1
    fi
    if ! w2run "test -s $MG && mkdir -p $GLM_HOME/logs $GLM_HOME/state && bash $MG start $CTR $FLOOR $LOGF $PIDF 4 1"; then
      say "start on spark3 FAILED (is $MG there? copy it to every rank)"
      bash "$MG" stop "$PIDF" 2>/dev/null
      wrun "test -s $MG && bash $MG stop $PIDF 2>/dev/null; true" >/dev/null 2>&1
      exit 1
    fi
    say "watching $CTR on spark1, spark2 and spark3: floor $FLOOR GiB for 4 s, hard floor 1 GiB ($LOGF on each node)" ;;
  stop)
    [ -s "$MG" ] && bash "$MG" stop "$PIDF" 2>/dev/null
    wrun "test -s $MG && bash $MG stop $PIDF 2>/dev/null; true" >/dev/null 2>&1
    w2run "test -s $MG && bash $MG stop $PIDF 2>/dev/null; true" >/dev/null 2>&1
    say "stopped on all three nodes" ;;
  *) echo "usage: glm53-memguard.sh start|stop"; exit 2 ;;
esac
exit 0
