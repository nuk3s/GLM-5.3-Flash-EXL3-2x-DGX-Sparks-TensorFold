#!/usr/bin/env bash
# nccl3_world_run.sh: run nccl3_world_test.py (beside this file) in a container on each of the three Sparks, with
# the per-rank NCCL environment the kit's nccl_env_n() sets, and print each rank's stage lines. It needs no engine
# downtime: it uses its own container name (nccl3) and port. Extra NCCL settings are KEY=VALUE arguments, applied
# to every rank:
#   nccl3_world_run.sh                          the kit's environment
#   nccl3_world_run.sh NCCL_IB_HCA=rocep1s0f0   one setting changed on every rank
# WAIT (150) bounds the wait for a verdict; CLEANUP=1 removes the containers at the end (they stay up otherwise).
set -u
HERE=$(dirname "$(readlink -f "$0")")
# Cluster values: hosts.conf beside this script (GLM_HOSTS_CONF names another file) overrides the defaults below;
# without it the defaults apply. hosts.conf.example lists every name.
_hc=${GLM_HOSTS_CONF:-$HERE/hosts.conf}
[ -n "${GLM_HOSTS_CONF:-}" ] || [ -r "$_hc" ] || _hc=$HERE/../hosts.conf
[ -z "${GLM_HOSTS_CONF:-}" ] || [ -r "$_hc" ] || { echo "nccl3_world_run: cannot read GLM_HOSTS_CONF=$_hc" >&2; exit 1; }
[ ! -r "$_hc" ] || bash -n "$_hc" 2>/dev/null || { echo "nccl3_world_run: syntax error in $_hc" >&2; exit 1; }
# shellcheck source=/dev/null
[ -r "$_hc" ] && . "$_hc"
IMG=${NCCL3_IMAGE:-tensorfold-glm53:v0.6.0-789e8f3bdfa2-p0131m2-20261103}
MASTER=${GLM_HEAD_LAN:-192.0.2.53}
PORT=${NCCL3_PORT:-29599}
SOCK=${GLM_SOCKET_IFNAME:-enP7s7}
# rank -> ssh target, and each node's RoCE device union (what the kit computes as NODE_HCAS on a triangle)
HOSTS=("${GLM_USER:-user}@$MASTER" "${GLM_WORKER:-user@192.0.2.180}" "${GLM_WORKER2:-user@192.0.2.216}")
HCAS=${NCCL3_HCAS:-rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1}
# GLM_PRINT_CONFIG=1: print the values this run would use and exit (tests/test_hosts_conf.sh)
if [ "${GLM_PRINT_CONFIG:-}" = 1 ]; then for _v in IMG MASTER PORT SOCK HOSTS HCAS; do declare -p "$_v" 2>/dev/null || echo "unset $_v"; done; exit 0; fi
SSHO=(-o BatchMode=yes -o ConnectTimeout=10)

EXTRA=()
for kv in "$@"; do EXTRA+=(-e "$kv"); done

for r in 0 1 2; do
  h=${HOSTS[$r]}
  scp "${SSHO[@]}" -q "$HERE/nccl3_world_test.py" "$h":/tmp/nccl3.py
  ssh "${SSHO[@]}" "$h" "docker rm -f nccl3 >/dev/null 2>&1; \
    setsid nohup docker run --rm --name nccl3 \
      --gpus all --ipc=host --network host --shm-size 2g --device /dev/infiniband \
      --cap-add IPC_LOCK --ulimit memlock=-1 --ulimit stack=67108864 \
      -v /tmp/nccl3.py:/tmp/nccl3.py:ro \
      -e NCCL_SOCKET_IFNAME=$SOCK -e NCCL_IB_HCA=$HCAS -e NCCL_IB_GID_INDEX=3 \
      -e NCCL_CROSS_NIC=1 -e NCCL_IB_SUBNET_AWARE_ROUTING=1 \
      -e NCCL_P2P_DISABLE=1 -e NCCL_SHM_DISABLE=1 \
      -e NCCL_MIN_NCHANNELS=4 -e NCCL_MAX_NCHANNELS=4 \
      -e NCCL_DEBUG=\${NCCL_DEBUG:-WARN} ${EXTRA[*]:-} \
      --entrypoint python3 $IMG /tmp/nccl3.py --rank $r --world 3 --master $MASTER --port $PORT \
      > /tmp/nccl3-rank$r.log 2>&1 < /dev/null &" >/dev/null 2>&1
done
WAIT=${WAIT:-150}
echo "launched 3 ranks, waiting up to ${WAIT} s"
for _ in $(seq 1 $((WAIT/5))); do
  sleep 5
  if ssh "${SSHO[@]}" "${HOSTS[0]}" 'grep -qE "PASS|FAIL|Traceback|Error" /tmp/nccl3-rank0.log 2>/dev/null'; then break; fi
done
echo "(containers are left running on purpose; CLEANUP=1 removes them at the end)"
for r in 0 1 2; do
  echo "===== rank $r (${HOSTS[$r]#*@}) ====="
  ssh "${SSHO[@]}" "${HOSTS[$r]}" "grep -E 'STAGE|PASS|FAIL|env |torch ' /tmp/nccl3-rank$r.log 2>/dev/null | tail -14"
  ssh "${SSHO[@]}" "${HOSTS[$r]}" "cp /tmp/nccl3-rank$r.log /tmp/keep-rank$r.log 2>/dev/null"
done

if [ "${CLEANUP:-0}" = 1 ]; then
  for r in 0 1 2; do ssh "${SSHO[@]}" "${HOSTS[$r]}" 'docker rm -f nccl3 >/dev/null 2>&1'; done
  echo "containers removed"
fi
