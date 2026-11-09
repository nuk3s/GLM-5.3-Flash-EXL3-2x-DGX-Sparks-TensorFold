#!/bin/bash
# hosts.conf: the lab file changes no value (each script prints the same with it as with its defaults), a fixture
# file sets every value, a GLM_HOSTS_CONF that cannot be read refuses, an empty NTFY_BASE turns ntfy off, and
# hosts.conf.example names the same values as the lab file. No host is touched: GLM_PRINT_CONFIG=1 makes each
# script print its values and exit before it does anything.
# Usage: bash tests/test_hosts_conf.sh -> PASS/FAIL per check, exit = FAILs
# shellcheck disable=SC2016,SC2034  # check() evals its single-quoted conditions on purpose
set -u
H="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
F=0; pass(){ echo "PASS $*"; }; fail(){ echo "FAIL $*"; F=$((F+1)); }
check(){ if eval "$2"; then pass "$1"; else fail "$1"; fi; }
NCCL3=""
for p in "$H/nccl3/nccl3_world_run.sh" "$H/../../benchmarks/nccl3_world_run.sh"; do [ -f "$p" ] && { NCCL3=$p; break; }; done
SCRIPTS=("$H/glm53-memguard.sh" "$H/glm53-prestart.sh" "$H/glm53-watchdog.sh" "$H/roce-watch/roce-watch.sh" ${NCCL3:+"$NCCL3"})
LOCAL_VARS="WORKER WORKER2 FABRIC_PEER FABRIC_PEER2 MASTER_ADDR SOCKET_IFNAME HF_CACHE WORKER_HF_CACHE WORKER_HF_CACHE2 SPILL_DIR TP COMM PARALLEL"
# Two guards keep every script away from the cluster: a script without the GLM_PRINT_CONFIG hook is never run, and
# ssh, scp, docker, sudo, curl, systemctl and systemd-run are stubs that log the call and fail.
mkdir -p "$T/stub"
for c in ssh scp docker sudo curl systemctl systemd-run; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 99\n' "$c" "$T/stub.log" > "$T/stub/$c"; chmod +x "$T/stub/$c"
done
cfg(){  # cfg HOSTS_CONF SCRIPT [NAME=VALUE...]: the script's values, in a clean environment
  local hc=$1 s=$2; shift 2
  grep -q 'GLM_PRINT_CONFIG' "$s" || { echo "NO GLM_PRINT_CONFIG HOOK in $s: not run"; return 99; }
  env -i PATH="$T/stub:$PATH" HOME="$HOME" GLM_PRINT_CONFIG=1 GLM_HOSTS_CONF="$hc" "$@" bash "$s" 2>&1
}
lcfg(){  # lcfg HOSTS_CONF: local.sh's kit values, in a clean environment
  env -i PATH="$PATH" HOME="$HOME" GLM_HOSTS_CONF="$1" bash -c ". '$H/local.sh'; for v in $LOCAL_VARS; do declare -p \$v; done" 2>&1
}
cat > "$T/fixture.conf" <<'X'
GLM_USER=svc
GLM_USER_HOME=/srv/svc
GLM_HOME=/srv/svc/glm
GLM_HEAD_LAN=192.0.2.1
GLM_WORKER=svc@192.0.2.2
GLM_WORKER2=svc@192.0.2.3
GLM_FABRIC_PEER=198.51.100.2
GLM_FABRIC_PEER2=198.51.100.3
GLM_SOCKET_IFNAME=eth9
GLM_HF_CACHE=/srv/svc/hf
GLM_SPILL_DIR=/srv/svc/spill
NTFY_BASE=https://ntfy.test
NTFY_TOPIC_CRIT=crit
NTFY_TOPIC_INFO=info
X

# 1. the lab file changes nothing. Skipped in the published tree (no tests/golden/), where a hosts.conf is the
# user's own file with other values.
if [ -r "$H/hosts.conf" ] && [ -d "$H/tests/golden" ]; then
  for s in "${SCRIPTS[@]}"; do
    n=${s#"$H"/}
    check "lab hosts.conf = defaults: $n" 'a=$(cfg /dev/null "$s"); [ "$a" = "$(cfg "$H/hosts.conf" "$s")" ] && grep -q "^declare" <<<"$a"'
  done
  check "lab hosts.conf = defaults: local.sh" 'a=$(lcfg /dev/null); [ "$a" = "$(lcfg "$H/hosts.conf")" ] && grep -q "^declare -- MASTER_ADDR=" <<<"$a"'
  check "hosts.conf.example sets the lab file's names" \
    '[ "$(grep -oE "^[A-Z0-9_]+=" "$H/hosts.conf" | sort)" = "$(grep -oE "^[A-Z0-9_]+=" "$H/hosts.conf.example" | sort)" ]'
else
  echo "SKIP the lab hosts.conf checks (no $H/hosts.conf or $H/tests/golden)"
fi

# 2. a fixture sets every value
o=$(cfg "$T/fixture.conf" "$H/glm53-memguard.sh")
check "fixture: memguard" 'grep -qx "declare -- WORKER=\"svc@192.0.2.2\"" <<<"$o" && grep -qx "declare -- WORKER2=\"svc@192.0.2.3\"" <<<"$o" && grep -qx "declare -- MG=\"/srv/svc/glm/bin/memguard.sh\"" <<<"$o"'
o=$(cfg "$T/fixture.conf" "$H/glm53-prestart.sh")
check "fixture: prestart" 'grep -qx "declare -- WORKER=\"svc@192.0.2.2\"" <<<"$o" && grep -qx "declare -- WORKER2=\"svc@192.0.2.3\"" <<<"$o"'
o=$(cfg "$T/fixture.conf" "$H/glm53-watchdog.sh")
check "fixture: watchdog" 'grep -qx "declare -- WORKER2=\"svc@192.0.2.3\"" <<<"$o" && grep -qx "declare -- NTFY=\"https://ntfy.test/crit\"" <<<"$o" && grep -qx "declare -- ST=\"/srv/svc/glm/state\"" <<<"$o"'
o=$(cfg "$T/fixture.conf" "$H/roce-watch/roce-watch.sh")
check "fixture: roce-watch" 'grep -qx "declare -- WORKERS=\"spark2=svc@192.0.2.2 spark3=svc@192.0.2.3\"" <<<"$o" && grep -qx "declare -- RW_DIR=\"/srv/svc/glm/roce-watch\"" <<<"$o" && grep -qx "declare -- NTFY_TOPIC_CRIT=\"crit\"" <<<"$o"'
if [ -n "$NCCL3" ]; then
  o=$(cfg "$T/fixture.conf" "$NCCL3")
  check "fixture: nccl3_world_run" 'grep -qx "declare -a HOSTS=(\[0\]=\"svc@192.0.2.1\" \[1\]=\"svc@192.0.2.2\" \[2\]=\"svc@192.0.2.3\")" <<<"$o" && grep -qx "declare -- SOCK=\"eth9\"" <<<"$o"'
fi
o=$(lcfg "$T/fixture.conf")
check "fixture: local.sh" 'grep -qx "declare -- MASTER_ADDR=\"192.0.2.1\"" <<<"$o" && grep -qx "declare -- FABRIC_PEER2=\"198.51.100.3\"" <<<"$o" && grep -qx "declare -- SOCKET_IFNAME=\"eth9\"" <<<"$o" && grep -qx "declare -- WORKER_HF_CACHE2=\"/srv/svc/hf\"" <<<"$o" && grep -qx "declare -- SPILL_DIR=\"/srv/svc/spill\"" <<<"$o"'

# 3. an environment value wins over the file, and an unreadable GLM_HOSTS_CONF refuses
o=$(cfg "$H/hosts.conf.example" "$H/glm53-memguard.sh" GLM_WORKER=x@192.0.2.9)
check "the environment wins over hosts.conf.example" 'grep -qx "declare -- WORKER=\"x@192.0.2.9\"" <<<"$o"'
for s in "${SCRIPTS[@]}"; do
  n=${s#"$H"/}
  check "unreadable GLM_HOSTS_CONF refuses: $n" '! cfg "$T/missing.conf" "$s" >/dev/null && cfg "$T/missing.conf" "$s" | grep -q "cannot read GLM_HOSTS_CONF"'
done
check "unreadable GLM_HOSTS_CONF refuses: local.sh" \
  'o=$(env -i PATH="$PATH" HOME="$HOME" GLM_HOSTS_CONF="$T/missing.conf" bash -c ". \"$H/local.sh\"; echo rc=\$?" 2>&1); grep -q "cannot read GLM_HOSTS_CONF" <<<"$o" && grep -qx "rc=1" <<<"$o"'

# 3b. a GLM_HOSTS_CONF with a syntax error refuses with exit 1, before it is sourced and before any host command.
# The roce watch is left out on purpose: a poll that refuses cannot roll back. The bad file runs a marker command
# on its first line, so a script that sourced it anyway would leave the marker.
printf 'echo SOURCED >> "%s/sourced.marker"\nGLM_WORKER=(\n' "$T" > "$T/bad.conf"
GUARDED=("$H/glm53-memguard.sh" "$H/glm53-prestart.sh" "$H/glm53-watchdog.sh" ${NCCL3:+"$NCCL3"})
for s in "${GUARDED[@]}"; do
  n=${s#"$H"/}
  check "syntax error in GLM_HOSTS_CONF refuses with exit 1: $n" 'o=$(cfg "$T/bad.conf" "$s"); rc=$?; [ "$rc" = 1 ] && grep -q "syntax error in" <<<"$o"'
done
check "a conf with a syntax error was never sourced" '[ ! -e "$T/sourced.marker" ]'

# 3c. the public layout: nccl3_world_run.sh in ops/nccl3/ finds ops/hosts.conf (its parent directory)
if [ -n "$NCCL3" ]; then
  mkdir -p "$T/pub/nccl3"; cp "$NCCL3" "$T/pub/nccl3/nccl3_world_run.sh"; cp "$T/fixture.conf" "$T/pub/hosts.conf"
  o=$(env -i PATH="$T/stub:$PATH" HOME="$HOME" GLM_PRINT_CONFIG=1 bash "$T/pub/nccl3/nccl3_world_run.sh" 2>&1)
  check "nccl3_world_run in ops/nccl3 reads ../hosts.conf" 'grep -qx "declare -a HOSTS=(\[0\]=\"svc@192.0.2.1\" \[1\]=\"svc@192.0.2.2\" \[2\]=\"svc@192.0.2.3\")" <<<"$o" && grep -qx "declare -- SOCK=\"eth9\"" <<<"$o"'
  o=$(env -i PATH="$T/stub:$PATH" HOME="$HOME" GLM_PRINT_CONFIG=1 GLM_HOSTS_CONF="$T/missing.conf" bash "$T/pub/nccl3/nccl3_world_run.sh" 2>&1)
  check "nccl3_world_run in ops/nccl3: a named GLM_HOSTS_CONF that is missing still refuses" 'grep -q "cannot read GLM_HOSTS_CONF" <<<"$o"'
fi

# 4. NTFY_BASE set and empty: no ntfy target
o=$(cfg "$H/hosts.conf.example" "$H/glm53-watchdog.sh")
check "empty NTFY_BASE (the example's default): the watchdog has no ntfy URL" 'grep -qx "declare -- NTFY=\"\"" <<<"$o"'
o=$(cfg "$H/hosts.conf.example" "$H/roce-watch/roce-watch.sh")
check "empty NTFY_BASE (the example's default): the roce watch has no ntfy server" 'grep -qx "declare -- NTFY_BASE=\"\"" <<<"$o"'

# 5. the example: it parses, and every name in it is read by some script or unit
check "hosts.conf.example parses" 'bash -n "$H/hosts.conf.example"'
for v in $(grep -oE "^[A-Z0-9_]+=" "$H/hosts.conf.example" | tr -d =); do
  check "hosts.conf.example $v is read somewhere" 'grep -rqs --include="*.sh" --include="*.in" --exclude="test_*" -e "$v" "$H" ${NCCL3:+"$NCCL3"}'
done
check "no host command ran (the stubs saw no call)" '[ ! -s "$T/stub.log" ]'
echo "RESULT: $F failed"
exit "$F"
