#!/bin/bash
# Stub tests (workstation and CI, no host touched) for glm53-watchdog.sh and glm53-prestart.sh. systemctl, sudo,
# curl, docker and ssh are stubs on PATH that answer from files in a temp dir.
#   A  glm53-serve not enabled: nothing; the HOLD marker: nothing; the 40-min grace
#   B  idle: /health then one chat probe (thinking off, 8 tokens); busy: /health only
#   C  "ok": false (the kit's broken latch, no exit): restart at once
#   D  a step over 360 s (iteration_s): failed ticks, restart after 2
#   E  a rank container missing on spark1 or spark2: failed ticks; spark2 out of reach: not counted
#   F  /health not 200 / no JSON: failed ticks; a good tick resets the count
#   G  the hourly cap (3) and the HOLD with one ntfy an hour; unit failed / inactive / auto-restart
#   P  glm53-prestart.sh: worker wait, running containers, another engine, the memory gate and the cache drop
# Usage: bash tests/test_glm53_watchdog.sh -> PASS/FAIL per check, exit = FAILs
# shellcheck disable=SC2016,SC2034  # check() evals its single-quoted conditions on purpose
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
F=0; pass(){ echo "PASS $*"; }; fail(){ echo "FAIL $*"; F=$((F+1)); }
check(){ if eval "$2"; then pass "$1"; else fail "$1"; fi; }
mkdir -p "$T/bin" "$T/home/state" "$T/s"
S="$T/s"
cat > "$T/bin/systemctl" <<'X'
#!/bin/bash
S=$FAKE_S; echo "systemctl $*" >> "$S/seq"
case "$1" in
  is-enabled) [ "$(cat "$S/enabled" 2>/dev/null)" = enabled ] ;;
  show) case "$3" in
          ActiveState) cat "$S/active" ;; SubState) cat "$S/sub" 2>/dev/null || echo running ;;
          Result) echo success ;; esac ;;
esac
X
cat > "$T/bin/sudo" <<'X'
#!/bin/bash
S=$FAKE_S; echo "sudo $*" >> "$S/seq"
[ "$1" = -n ] && shift
case "$1" in systemctl) exit 0 ;; sh) [ -f "$S/sudo_ok" ] && { echo dropped >> "$S/seq"; [ -f "$S/mem_after_drop" ] && cp "$S/mem_after_drop" "$S/meminfo"; exit 0; }; exit 1 ;; esac
X
cat > "$T/bin/curl" <<'X'
#!/bin/bash
S=$FAKE_S; out="" url="" data=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; -d) data=$2; shift 2 ;; -w|-m|-H) shift 2 ;; -s|-sk) shift ;; *) url=$1; shift ;; esac; done
echo "curl $url $data" >> "$S/seq"
case "$url" in
  */health) printf '%s\n%s' "$(cat "$S/health_body")" "$(cat "$S/health_code")" ;;
  */v1/chat/completions) cat "$S/chat_body" > "$out"; printf '%s 0.42' "$(cat "$S/chat_code")" ;;
  https://ntfy*) echo "NTFY $data" >> "$S/seq" ;;
esac
X
cat > "$T/bin/docker" <<'X'
#!/bin/bash
S=$FAKE_S; echo "docker $*" >> "$S/seq"
c=${@: -1}; f="$S/head_ctr_$c"
[ -f "$f" ] && cat "$f" || exit 1
X
cat > "$T/bin/ssh" <<'X'
#!/bin/bash
S=$FAKE_S; echo "ssh $*" >> "$S/seq"
[ -f "$S/worker_down" ] && exit 255
case "$*" in *192.0.2.216*) [ -f "$S/worker2_down" ] && exit 255 ;; esac
cmd=${@: -1}
case "$cmd" in
  true) exit 0 ;;
  *drop_caches*) [ -f "$S/sudo_ok" ] && exit 0; exit 1 ;;
  *MemAvailable*) awk '/^MemAvailable:/ { printf "%d", $2 / 1048576 }' "$S/worker_meminfo" ;;
  *"docker stop"*glm53-flash-tf*) echo "worker docker stop" >> "$S/seq"; [ -f "$S/worker_stop_fails" ] && exit 1
                                   echo false > "$S/worker_ctr_glm53-flash-tf" ;;
  *"docker inspect"*glm53-flash-tf*) case "$*" in *192.0.2.216*) w=worker2 ;; *) w=worker ;; esac
                                     cat "$S/${w}_ctr_glm53-flash-tf" 2>/dev/null || echo false ;;
  *"docker inspect"*tf-trial*) cat "$S/worker_ctr_tf-trial" 2>/dev/null ;;
esac
X
chmod +x "$T/bin/"*
# GLM_HOSTS_CONF=/dev/null: the scripts read no hosts.conf, so a real one beside them cannot change a test value
export FAKE_S="$S" PATH="$T/bin:$PATH" GLM_HOME="$T/home" NTFY=https://ntfy.test/x GLM_HOSTS_CONF=/dev/null
SF="$T/home/state/watchdog.state"
WD(){ bash "$KIT/glm53-watchdog.sh" > "$T/wd.out" 2>&1; }
res(){ sed -n 's/^result=//p' "$SF"; }
key(){ sed -n "s/^$1=//p" "$SF"; }
restarts(){ grep -c "sudo -n systemctl restart --no-block glm53-serve.service" "$S/seq"; }
ntfys(){ grep -c "^NTFY" "$S/seq"; }
live(){  # a deployed, healthy, idle GLM 50 min after its start (the grace is 40 min)
  rm -f "$SF" "$T/home/state/HOLD" "$S/worker_down"; : > "$S/seq"
  echo enabled > "$S/enabled"; echo active > "$S/active"; echo running > "$S/sub"
  echo $(( $(date +%s) - 3000 )) > "$T/home/state/last-start"
  echo true > "$S/head_ctr_glm53-flash-tf"; echo true > "$S/worker_ctr_glm53-flash-tf"; echo true > "$S/worker2_ctr_glm53-flash-tf"
  echo 200 > "$S/health_code"; echo '{"ok": true, "requests_running": 0, "iteration_s": 0.0}' > "$S/health_body"
  echo 200 > "$S/chat_code"; echo '{"choices": [{"message": {"content": "ready"}}]}' > "$S/chat_body"; }

# A
live; echo disabled > "$S/enabled"; WD
check "A not enabled: off, no probe" '[ "$(res)" = off ] && ! grep -q curl "$S/seq"'
live; echo rollback > "$T/home/state/HOLD"; WD
check "A HOLD: held, no probe" '[ "$(res)" = held ] && ! grep -q curl "$S/seq"'
live; date +%s > "$T/home/state/last-start"; echo 503 > "$S/health_code"; WD
check "A grace after a start: no probe" '[ "$(res)" = grace ] && ! grep -q curl "$S/seq"'
live; echo $(( $(date +%s) - 1500 )) > "$T/home/state/last-start"; echo 503 > "$S/health_code"; WD
check "A 25 min after a start (an NFS load): still the grace" '[ "$(res)" = grace ] && ! grep -q curl "$S/seq"'

# B
live; WD
check "B idle: /health on :8888 then a chat probe, ok" '[ "$(res)" = ok ] && grep -q "curl http://127.0.0.1:8888/health" "$S/seq" && grep -q "curl http://127.0.0.1:8888/v1/chat/completions" "$S/seq"'
check "B the probe: served name, 8 tokens, thinking off, not streaming" 'grep "chat/completions" "$S/seq" | grep -q "\"model\": \"GLM-5.3-Flash-EXL3\", \"max_tokens\": 8" && grep "chat/completions" "$S/seq" | grep -q "\"enable_thinking\": false" && ! grep "chat/completions" "$S/seq" | grep -q stream'
live; echo '{"ok": true, "requests_running": 3, "iteration_s": 1.5}' > "$S/health_body"; WD
check "B busy: /health only, ok" '[ "$(res)" = ok ] && ! grep -q "chat/completions" "$S/seq" && grep -q "busy: 3 running" "$SF"'

# C
live; echo '{"ok": false, "broken": "RuntimeError: ranks out of step", "requests_running": 2}' > "$S/health_body"; WD
check "C broken latch: restart at once, ntfy" '[ "$(res)" = restarted ] && [ "$(restarts)" = 1 ] && [ "$(ntfys)" = 1 ] && grep -q "broken: RuntimeError: ranks out of step" "$T/home/state/watchdog.log"'

# D
live; echo '{"ok": true, "requests_running": 1, "iteration_s": 400}' > "$S/health_body"; WD
check "D step 400 s: failed tick 1, no restart" '[ "$(res)" = fail ] && [ "$(key fails)" = 1 ] && [ "$(restarts)" = 0 ]'
WD
check "D second tick: restart" '[ "$(res)" = restarted ] && [ "$(restarts)" = 1 ] && [ "$(key fails)" = 0 ]'
check "D the restart resets the start-limit counter first" 'grep -n "systemctl reset-failed glm53-serve.service" "$S/seq" | head -1 | cut -d: -f1 | { read -r a; b=$(grep -n "systemctl restart --no-block" "$S/seq" | head -1 | cut -d: -f1); [ -n "$a" ] && [ "$a" -lt "$b" ]; }'
live; echo '{"ok": true, "requests_running": 1, "iteration_s": 300}' > "$S/health_body"; WD
check "D step 300 s (the kit only reports): ok" '[ "$(res)" = ok ]'

# E
live; echo false > "$S/worker_ctr_glm53-flash-tf"; WD
check "E rank 1 gone: failed tick" '[ "$(res)" = fail ] && grep -q "rank 1 (spark2) container not running" "$SF"'
mkdir -p "$T/home/kit/scripts"; printf 'TP=3\nCOMM=nccl\n' > "$T/home/kit/scripts/local.sh"
live; echo false > "$S/worker2_ctr_glm53-flash-tf"; WD
check "E TP=3, rank 2 gone: failed tick" '[ "$(res)" = fail ] && grep -q "rank 2 (spark3) container not running" "$SF"'
live; WD
check "E TP=3, all three run: ok, spark3 asked" '[ "$(res)" = ok ] && grep -q "ssh .*192.0.2.216.*docker inspect" "$S/seq"'
rm -f "$T/home/kit/scripts/local.sh"
live; echo false > "$S/worker2_ctr_glm53-flash-tf"; WD
check "E TP=2: rank 2 not checked" '[ "$(res)" = ok ] && ! grep -q "192.0.2.216" "$S/seq"'
live; touch "$S/worker2_down"; printf '3\n' > "$T/home/state/tp"; WD
check "E TP=3 (state/tp), spark3 unreachable: no fail" '[ "$(res)" = ok ]'
rm -f "$S/worker2_down"
mkdir -p "$T/home/kit/scripts"; printf 'TP=3\n' > "$T/home/kit/scripts/local.sh"; printf '2\n' > "$T/home/state/tp"
live; echo false > "$S/worker2_ctr_glm53-flash-tf"; WD
check "E local.sh says TP=3 but the running start was TP=2 (state/tp): rank 2 not checked" '[ "$(res)" = ok ] && ! grep -q "192.0.2.216" "$S/seq"'
printf '3\n' > "$T/home/state/tp"
live; echo false > "$S/worker2_ctr_glm53-flash-tf"; WD
check "E state/tp=3, rank 2 gone: failed tick" '[ "$(res)" = fail ] && grep -q "rank 2 (spark3) container not running" "$SF"'
rm -f "$T/home/kit/scripts/local.sh" "$T/home/state/tp"
live; rm -f "$S/head_ctr_glm53-flash-tf"; WD
check "E rank 0 gone: failed tick" '[ "$(res)" = fail ] && grep -q "rank 0 (spark1) container not running" "$SF"'
live; touch "$S/worker_down"; WD
check "E spark2 out of reach: not counted, probe goes on" '[ "$(res)" = ok ]'

# F
live; echo 000 > "$S/health_code"; WD; WD
check "F /health no answer twice: restart" '[ "$(res)" = restarted ] && grep -q "/health answered 000" "$T/home/state/watchdog.log"'
live; echo 'not json' > "$S/health_body"; WD
check "F 200 without JSON: failed tick" '[ "$(res)" = fail ]'
echo '{"ok": true, "requests_running": 0}' > "$S/health_body"; WD
check "F a good tick resets the count" '[ "$(res)" = ok ] && [ "$(key fails)" = 0 ]'
live; echo 500 > "$S/chat_code"; WD; WD
check "F idle chat probe 500 twice: restart" '[ "$(res)" = restarted ]'
live; echo '{"choices": [{"message": {"content": ""}}]}' > "$S/chat_body"; WD
check "F empty reply: failed tick" '[ "$(res)" = fail ]'

# G
live; now=$(date +%s)
printf 'fails=1\nrestarts=%s %s %s\nlast_restart=%s\n' $((now-3500)) $((now-3000)) $((now-2600)) $((now-2600)) > "$SF"
echo '{"ok": false}' > "$S/health_body"; WD
check "G hourly cap: hold, no restart, one ntfy" '[ "$(res)" = hold ] && [ "$(restarts)" = 0 ] && [ "$(ntfys)" = 1 ]'
WD
check "G the next held tick: no second ntfy" '[ "$(res)" = hold ] && [ "$(ntfys)" = 1 ]'
live; echo failed > "$S/active"; WD
check "G unit failed: no restart, ntfy" '[ "$(res)" = unit-failed ] && [ "$(restarts)" = 0 ] && [ "$(ntfys)" = 1 ]'
live; echo failed > "$S/active"; NTFY= WD
check "G unit failed, NTFY set and empty: no ntfy call at all" '[ "$(res)" = unit-failed ] && [ "$(ntfys)" = 0 ] && ! grep -q "^curl  " "$S/seq"'
live; echo inactive > "$S/active"; WD
check "G unit inactive: nothing" '[ "$(res)" = unit-inactive ] && ! grep -q curl "$S/seq"'
live; echo activating > "$S/active"; echo auto-restart > "$S/sub"; WD
check "G auto-restart pending: nothing" '[ "$(res)" = systemd-restart ]'
live; echo activating > "$S/active"; echo start-pre > "$S/sub"; WD
check "G still loading after the grace: failed tick" '[ "$(res)" = fail ]'

# P glm53-prestart.sh
PRE(){ GLM_PRE_WAIT_S=${1:-0} bash "$KIT/glm53-prestart.sh" > "$T/pre.out" 2>&1; echo $?; }
mi(){ printf 'MemTotal: 128000000 kB\nMemAvailable: %d kB\n' $(( $1 * 1048576 )) > "$2"; }
memwrap(){  # point the prestart's /proc/meminfo at a fake one
  sed "s#awk '/^MemAvailable:/ { printf \"%d\", \$2 / 1048576 }' \"\${1:-/proc/meminfo}\"#awk '/^MemAvailable:/ { printf \"%d\", \$2 / 1048576 }' \"$S/meminfo\"#" "$KIT/glm53-prestart.sh" > "$T/pre.sh"; }
memwrap
PRE2(){ GLM_PRE_WAIT_S=0 bash "$T/pre.sh" > "$T/pre.out" 2>&1; echo $?; }
live; rm -f "$S/head_ctr_glm53-flash-tf" "$S/sudo_ok" "$S/mem_after_drop"; echo false > "$S/worker_ctr_glm53-flash-tf"
mi 118 "$S/meminfo"; mi 117 "$S/worker_meminfo"
check "P memwrap applied" 'grep -q "$S/meminfo" "$T/pre.sh"'
check "P all clear: exit 0" '[ "$(PRE2)" = 0 ] && grep -q "ok (TP=2): spark2 answer," "$T/pre.out"'
check "P all clear writes the start's TP to state/tp" '[ "$(cat "$T/home/state/tp" 2>/dev/null)" = 2 ]'
rm -f "$T/home/state/tp"
touch "$S/worker_down"
check "P spark2 does not answer: refused" '[ "$(PRE2)" = 1 ] && grep -q "does not answer ssh" "$T/pre.out"'
rm -f "$S/worker_down"; echo true > "$S/worker_ctr_glm53-flash-tf"; : > "$S/seq"
check "P rank 1 alone on spark2 (#159 after a head power cycle): stopped, then exit 0" '[ "$(PRE2)" = 0 ] && grep -q "worker docker stop" "$S/seq" && grep -q "runs alone on spark2" "$T/pre.out" && [ "$(cat "$S/worker_ctr_glm53-flash-tf")" = false ]'
echo true > "$S/worker_ctr_glm53-flash-tf"; touch "$S/worker_stop_fails"
check "P rank 1 alone on spark2 and docker stop fails: refused" '[ "$(PRE2)" = 1 ] && grep -q "still runs on spark2" "$T/pre.out"'
rm -f "$S/worker_stop_fails"; echo true > "$S/head_ctr_glm53-flash-tf"; echo true > "$S/worker_ctr_glm53-flash-tf"
check "P rank 0 runs on spark1 (a start outside systemd): refused" '[ "$(PRE2)" = 1 ] && grep -q "rank 0 (glm53-flash-tf) already runs on spark1" "$T/pre.out"'
echo false > "$S/worker_ctr_glm53-flash-tf"
check "P rank 0 alone on spark1: refused" '[ "$(PRE2)" = 1 ] && grep -q "already runs on spark1" "$T/pre.out"'
echo false > "$S/worker_ctr_glm53-flash-tf"; echo false > "$S/head_ctr_glm53-flash-tf"
check "P a stopped container is fine" '[ "$(PRE2)" = 0 ]'
echo true > "$S/head_ctr_tf-trial"
check "P another engine runs on spark1: refused" '[ "$(PRE2)" = 1 ] && grep -q "another engine" "$T/pre.out"'
rm -f "$S/head_ctr_tf-trial"; mi 100 "$S/meminfo"
check "P spark1 at 100 GiB, no sudo: refused" '[ "$(PRE2)" = 1 ] && grep -q "under 110 GiB" "$T/pre.out"'
touch "$S/sudo_ok"; mi 115 "$S/mem_after_drop"; mi 100 "$S/meminfo"
check "P spark1 at 100 GiB, the cache drop frees it: exit 0" '[ "$(PRE2)" = 0 ] && grep -q dropped "$S/seq"'

echo "RESULT: $F failed"
exit "$F"
