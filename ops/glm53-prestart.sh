#!/bin/bash
# glm53-prestart.sh: glm53-serve's ExecStartPre (as GLM_USER on spark1), after the start stamp. Installed to
# $HOME/glm53/bin/ (docs/operations.md). Added 2026-11-02 for the GLM-5.3 cutover.
#
# start.sh under systemd (FOREGROUND=1) skips the kit's own retries: it does not take the smaller window rank 0
# names when memory is short, and it exits 0 when the containers already run, which the unit's
# RestartForceExitStatus=0 would turn into a restart loop. So this refuses (exit 1, the unit fails, GLMServeFailed
# fires) before start.sh runs:
#   1. spark2's ssh does not answer within WAIT_S (300; a boot after a power loss must not burn the start limit while
#      spark2 boots);
#   2. rank 0's glm53-flash-tf container RUNS on spark1 (a start by hand outside systemd: stop both ranks with the
#      kit's ./stop.sh first). A stopped one is fine: start.sh saves its log and removes it. Rank 1 running ALONE on
#      spark2 is not refused: that is the state after a head hang and a power cycle of spark1 (kit issue #159), when
#      ExecStopPost never ran. It is stopped here (docker stop -t 30; start.sh then saves its log and removes it),
#      before the memory gate, so that the unit comes back by itself;
#   3. another engine's container (GLM_H_CONTAINER) runs on either node (the two cannot share the memory);
#   4. MemAvailable is under MIN_GIB (95 at TP=3, 110 at TP=2: the kit's start need) on any node, also after one
#      page-cache drop (sudo -n; a failed sudo only skips the drop).
# Exit 0 = start.sh may run.
set -uo pipefail
# hosts.conf beside this script (GLM_HOSTS_CONF names another file) sets this cluster's values; without it the
# defaults below apply. hosts.conf.example lists every name.
_hc=${GLM_HOSTS_CONF:-$(dirname "$(readlink -f "$0")")/hosts.conf}
[ -z "${GLM_HOSTS_CONF:-}" ] || [ -r "$_hc" ] || { echo "glm53-prestart: cannot read GLM_HOSTS_CONF=$_hc" >&2; exit 1; }
[ ! -r "$_hc" ] || bash -n "$_hc" 2>/dev/null || { echo "glm53-prestart: syntax error in $_hc" >&2; exit 1; }
# shellcheck source=/dev/null
[ -r "$_hc" ] && . "$_hc"
GLM_HOME="${GLM_HOME:-$HOME/glm53}"
WORKER="${GLM_WORKER:-user@192.0.2.180}"
# TP=3 (2026-11-05): spark3 is rank 2, so every check below must cover it too. Leaving it out meant a
# restart would not wait for its ssh, would not clear a stale rank 2 and would not gate its memory.
WORKER2="${GLM_WORKER2:-user@192.0.2.216}"
_tp=$(sed -n 's/^TP=\([0-9]\).*/\1/p' "$GLM_HOME/kit/scripts/local.sh" 2>/dev/null | tail -1)
TP="${_tp:-2}"
WORKERS=("$WORKER"); WNAMES=(spark2)
if [ "$TP" = 3 ]; then WORKERS+=("$WORKER2"); WNAMES+=(spark3); fi
CTR="${GLM_CONTAINER:-glm53-flash-tf}"
H_CTR="${GLM_H_CONTAINER:-tf-trial}"
WAIT_S="${GLM_PRE_WAIT_S:-300}"
# The 110 GiB gate sized TP=2, where one node holds the whole half. At TP=3 a rank loads about
# 72-84 GiB, so 110 would false-refuse on a node holding a little else. Scale it with TP.
if [ "$TP" = 3 ]; then MIN_GIB="${GLM_PRE_MIN_GIB:-95}"; else MIN_GIB="${GLM_PRE_MIN_GIB:-110}"; fi
# GLM_PRINT_CONFIG=1: print the values this run would use, then exit (tests/test_hosts_conf.sh)
if [ "${GLM_PRINT_CONFIG:-}" = 1 ]; then
  for _v in GLM_HOME WORKER WORKER2 TP WORKERS WNAMES CTR H_CTR WAIT_S MIN_GIB; do declare -p "$_v" 2>/dev/null || echo "unset $_v"; done
  exit 0
fi
SSHO=(-n -o BatchMode=yes -o ConnectTimeout=8)
say(){ echo "glm53-prestart: $*"; }
refuse(){ say "REFUSED: $*"; exit 1; }
wrun(){ timeout 20 ssh "${SSHO[@]}" "$WORKER" "$@"; }
wrun_long(){ local t="$1"; shift; timeout "$t" ssh "${SSHO[@]}" "$WORKER" "$@"; }
# the same two, against any rank
wrun_at(){ local w="$1"; shift; timeout 20 ssh "${SSHO[@]}" "$w" "$@"; }
wrun_at_long(){ local w="$1" t="$2"; shift 2; timeout "$t" ssh "${SSHO[@]}" "$w" "$@"; }

deadline=$((SECONDS + WAIT_S))
for _i in "${!WORKERS[@]}"; do
  until wrun_at "${WORKERS[$_i]}" true 2>/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || refuse "${WNAMES[$_i]} (${WORKERS[$_i]}) does not answer ssh after ${WAIT_S}s"
    sleep 10
  done
done
running(){ [ "$1" = true ]; }
here=$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null)
there=$(wrun "docker inspect -f '{{.State.Running}}' $CTR 2>/dev/null")
if running "$here"; then
  refuse "rank 0 ($CTR) already runs on spark1 (spark2: ${there:-none}): a start outside systemd? Stop both ranks with the kit's ./stop.sh, then start the unit"
fi
for _i in "${!WORKERS[@]}"; do
  _w=${WORKERS[$_i]}; _n=${WNAMES[$_i]}
  _r=$(wrun_at "$_w" "docker inspect -f '{{.State.Running}}' $CTR 2>/dev/null")
  running "$_r" || continue
  say "a rank ($CTR) runs alone on $_n (rank 0 is gone: a head hang and a power cycle? kit issue #159): docker stop -t 30 on $_n"
  wrun_at_long "$_w" 60 "docker stop -t 30 $CTR >/dev/null" 2>/dev/null || say "docker stop on $_n returned an error; checking the container"
  _r=$(wrun_at "$_w" "docker inspect -f '{{.State.Running}}' $CTR 2>/dev/null")
  running "$_r" && refuse "a rank ($CTR) still runs on $_n after docker stop: stop it by hand (ssh $_w docker stop $CTR)"
  say "the rank on $_n stopped (start.sh saves its log and removes it)"
done
here=$(docker inspect -f '{{.State.Running}}' "$H_CTR" 2>/dev/null)
there=$(wrun "docker inspect -f '{{.State.Running}}' $H_CTR 2>/dev/null")
if running "$here" || running "$there"; then
  refuse "another engine ($H_CTR) runs (spark1: ${here:-none}, spark2: ${there:-none}); stop it first"
fi
avail_gib(){ awk '/^MemAvailable:/ { printf "%d", $2 / 1048576 }' "${1:-/proc/meminfo}"; }
mem_ok(){
  h=$(avail_gib); h=${h:-0}; w=""; _worst=$h; _worstn=spark1
  for _i in "${!WORKERS[@]}"; do
    _v=$(wrun_at "${WORKERS[$_i]}" "awk '/^MemAvailable:/ { printf \"%d\", \$2 / 1048576 }' /proc/meminfo" 2>/dev/null)
    _v=${_v:-0}; w="${w:+$w, }${WNAMES[$_i]} ${_v}"
    [ "$_v" -lt "$_worst" ] && { _worst=$_v; _worstn=${WNAMES[$_i]}; }
  done
  [ "$h" -ge "$MIN_GIB" ] && [ "$_worst" -ge "$MIN_GIB" ]
}
if ! mem_ok; then
  say "MemAvailable spark1 ${h} GiB, spark2 ${w} GiB (need ${MIN_GIB}): dropping the page cache once"
  sudo -n sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || say "sudo drop_caches on spark1 not allowed; skipped"
  for _i in "${!WORKERS[@]}"; do
    wrun_at "${WORKERS[$_i]}" "sudo -n sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'" 2>/dev/null || say "sudo drop_caches on ${WNAMES[$_i]} not allowed; skipped"
  done
  sleep 5
  mem_ok || refuse "MemAvailable spark1 ${h} GiB, spark2 ${w} GiB, under ${MIN_GIB} GiB: the kit's window would not fit (a phantom-busy GPU? a second engine?)"
fi
say "ok (TP=$TP): ${WNAMES[*]} answer, no running rank or other engine container, MemAvailable spark1 ${h} GiB, ${w} GiB"
# The TP this start uses, for glm53-watchdog.sh: it checks rank 2 only when THIS start runs TP=3, so a local.sh
# edit staged while the engine still serves does not change what the watchdog expects (review 2026-11-06).
printf '%s\n' "$TP" > "$GLM_HOME/state/tp" 2>/dev/null || say "could not write state/tp"
