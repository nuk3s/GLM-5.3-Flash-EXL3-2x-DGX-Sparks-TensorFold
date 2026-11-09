# shellcheck shell=bash disable=SC2034  # sourced by the kit's scripts/config.sh
# Setup for GLM-5.3-Flash-EXL3 on TensorFold: tune 2 (2026-11-03), on top of the first tuning restart.
# Copy this file to $HOME/glm53/kit/scripts/local.sh on spark1 (the kit at bf5f945).
# Four changes from the cutover (operator 2026-11-02: stability, then concurrency, 1M context, latency):
#   1. local weights: both ranks read their own NVMe copy of the checkpoint and the drafter (the same HF cache layout,
#      every file sha256-checked). No network read at a start.
#   2. the spill tier: kept prompt states on each node's NVMe (800 GiB a rank).
#   3. PARALLEL 6 (kit default 4). The kit then sets a 64-row verify window, TF_ROCE_MAX_KB 1024 and
#      MEMORY_RESERVE_GIB 17.7 (14.5 + 0.95 x 2 + 0.04 x 32), so the pool shrinks and the free-memory floor stays.
#   4. a cap on the kept states' own device memory (kit issues #197 and #143).
# Cluster values: hosts.conf in the ops tree's bin/ (kit/scripts/../../bin/hosts.conf; GLM_HOSTS_CONF names another
# file) overrides the value after each ":-" below. hosts.conf.example lists every name.
_glm53_hc=${GLM_HOSTS_CONF:-$(dirname "${BASH_SOURCE[0]}")/../../bin/hosts.conf}
[ -z "${GLM_HOSTS_CONF:-}" ] || [ -r "$_glm53_hc" ] || { echo "local.sh: cannot read GLM_HOSTS_CONF=$_glm53_hc" >&2; return 1; }
# shellcheck source=/dev/null
[ -r "$_glm53_hc" ] && . "$_glm53_hc"
unset _glm53_hc
WORKER=${GLM_WORKER:-user@192.0.2.180}          # spark2 over the LAN
# REVERTED 2026-11-04 00:05Z. LAN FABRIC_PEERs made all three ranks agree on --master 192.0.2.53,
# and that was a REGRESSION: py-spy showed the hang move EARLIER, from comm.py:66
# (ncclCommInitRank) to comm.py:56 (the TCPStore itself). With the kit's per-link fabric addresses
# the rendezvous SUCCEEDS and the ranks exchange the NCCL unique id, so the three different
# --master strings are the kit's design and are not the bug. The real blocker is
# ncclCommInitRank. History of the idea, kept so nobody retries it:
# TP=3 rendezvous consistency. start.sh:342 gives each worker --master "${LINK_HEAD_ADDR[i]}",
# derived from FABRIC_PEER<i>, while start.sh:357 gives rank 0 --master "$MASTER_ADDR". With fabric
# FABRIC_PEERs that produced THREE different host strings for ONE PyTorch TCPStore (rank 0
# 192.0.2.53, rank 1 198.18.0.53, rank 2 198.18.4.53) and all three ranks spun forever in the
# TCPStore constructor at tensorfold/cuda/comm.py:66 (py-spy, 2026-11-04 23:51Z).
# LAN FABRIC_PEERs make LINK_HEAD_ADDR resolve to spark1's LAN address on both links, so every rank
# gets the same --master. This moves only the rendezvous: NODE_HCAS comes from pair_links by RoCE
# subnet and is untouched, so the data plane stays on the CX7 devices via NCCL_IB_HCA.
FABRIC_PEER=${GLM_FABRIC_PEER:-198.18.0.189}         # spark2 on cable A. KEEP THIS: see the note above.
# MASTER_ADDR at TP=3 must be an address EVERY rank reaches. 198.18.0.53 is spark1 on ring cable A,
# which is correct at TP=2 because spark2 shares that subnet, and wrong at TP=3 because spark3 does not:
# it routes 198.18.0.53 out the LAN gateway and gets 100 % loss. Both ranks then hang in the NCCL
# bootstrap rendezvous with their logs ending at plugin load and no error (window 2026-11-04 23:02Z).
# The kit's own "no route to MASTER_ADDR" check passes, because a default route exists even though
# nothing answers. Use spark1's LAN address; the bootstrap is control plane only and the data plane
# still runs on the RoCE devices through NCCL_IB_HCA.
MASTER_ADDR=${GLM_HEAD_LAN:-192.0.2.53}             # spark1 LAN: the one address all three ranks reach
PORT=8888
IMAGE=tensorfold-glm53:v0.6.0-789e8f3bdfa2-p0131m2-es-20261108     # image/build.sh, then image/es/build.sh, build this tag (p0131m2 + expandable_segments, kit #143 / PR #189)
# 1. Local weights. The head mounts HF_CACHE; WORKER_WEIGHTS=copy makes rank 1 mount WORKER_HF_CACHE on spark2.
#    The unit runs PREPARE=0, so prepare.sh does not run and copies nothing.
HF_CACHE=${GLM_HF_CACHE:-$HOME/models/hf-cache}
WORKER_WEIGHTS=copy
WORKER_HF_CACHE=${GLM_HF_CACHE:-$HOME/models/hf-cache}
# 2. Spill tier (patches 0088 and 0128). The same absolute path on both nodes (start.sh makes it; mounted at /spill).
#    O_DIRECT writes. 300 GiB stays free on the file system.
#    SPILL_RELEASE_MIB: at most 1 GiB of host memory for rows freed before their write (kit default: an eighth of
#    the reserve, 2.2 GiB here), so the tier cannot take more than 1 GiB off the head's free-memory floor.
SPILL_GIB=800
SPILL_DIR=${GLM_SPILL_DIR:-$HOME/models/glm53-spill}
SPILL_MIN_FREE_GIB=300
SPILL_RELEASE_MIB=1024
# 3. Concurrency. MEMORY_RESERVE_GIB, TF_GLM_MULTI_WINDOW and TF_ROCE_MAX_KB stay the kit's values for 6 streams.
PARALLEL=8
# 4. Kept states: at most 4 GiB of device memory outside the pool (the option author's value). Each kept state of
#    8,192 tokens or more is on disk already (the spill tier writes it when kept), so a dropped one comes back from disk.
TF_GLM_KEPT_BYTES_GIB=4
# 5. Tune 2 (2026-11-03). Stability first, then the kept-state count. The image adds MALLOC_ARENA_MAX=2 (kit #154:
#    rank-0 RSS growth with vision traffic; the head's MemAvailable fell ~0.8 GiB/h on the first tuned config).
#    start.sh passes only exported TENSORFOLD_*, TF_GLM_* and TF_ROCE_* variables, so these are exported.
#    The exit switches (the kit README at bf5f945, lines 728-729): a latched broken pair or a step stuck TF_GLM_MULTI_WATCHDOG_S (300 s)
#    exits the rank at once, and glm53-serve restarts it (kit #153, #163 wedges become bounded outages).
export TF_GLM_EXIT_ON_BROKEN=1
export TF_GLM_MULTI_WATCHDOG_EXIT=1
#    Kept states: the count is also a memory share (patch 0097, kit #84); 50 % gives ~42 states instead of the fixed
#    32, which pinned at 32 while the pool had room. The 4 GiB byte cap above still holds.
export TF_GLM_CACHE_SHARE_PCT=50
#    Spill restores read 32 blocks ahead (a 260K restore 0.85 -> 0.47 s, the kit README at bf5f945, line 723), and kept states from
#    4,096 tokens are written (62 shorter ones were dropped as unwritten_short on the first tuned config).
export TF_GLM_SPILL_READ_BLOCKS=32
SPILL_MIN_TOKENS=4096
#    The decode expert kernel's block launch order (patch 0090): the same output bit for bit, +2.2 % on one request.
export TF_GLM_EXL3_DEC_ORDER=1
# 6. KV sharding (patch 0129, window 2026-11-04). Each conversation's latent cache is stored once, on the rank that
#    owns it, instead of on every rank. The patch header claims ~1.88x the tokens in the same memory at two ranks;
#    the baseline pool is 1,593,344 tokens, so expect ~3.0M. The author states the bits are the same as unsharded,
#    so the needle and replay gates must still pass byte for byte.
#    Two things to know before a restart:
#      - it must be set alike on EVERY rank (the engine gathers it and refuses an odd rank). start.sh exports
#        TF_GLM_* to both containers, so this line covers both.
#      - it changes the spill store's signature: block names gain the part the rows lie in (``in_part``), so the
#        313.79 GiB already stored is not reusable and the tier refills. The cache hit rate right after a restart is
#        therefore NOT comparable to the 95.8 % measured before this change. Pool size is the clean measurement.
#    Rollback: drop this line, copy the file to spark1 and restart glm53-serve.
export TF_GLM_KV_SHARD=1
# 7. TP=3 TRIAL (window 2026-11-04). The ring is cabled and addressed; ./start-tp3.sh sets TP=3 and COMM=nccl.
#    The TP-N engine is kit patches 0066-0068, already in the p0131m2 image, so no rebuild is needed.
#    Rank 2 reads its own NVMe copy (165.83 GiB, every file sha256-checked).
#    WORKER_WEIGHTS2=nfs would instead make the worker mount the HEAD's hf-cache over NFS, which needs an
#    export on the head.
#    Remove this whole block to go back to the pair. start.sh reads TP, so a leftover TP=3 starts 3 ranks.
# The systemd unit runs ./start.sh, not ./start-tp3.sh, so the two TP=3 switches that start-tp3.sh
# would have exported must live here or a unit restart silently serves a different configuration.
# config.sh sources local.sh BEFORE its own defaults, so these win:
#   COMM=roce         ADOPTED 2026-11-07 (window k8, operator decision). start-tp3.sh's default is
#                     nccl, so this line must stay. Measured against nccl on the same window, identical
#                     tokens: -9.0% ms/round at one stream, -2.0% / -1.1% at 8 streams (docs/results.md,
#                     "COMM=roce at TP=3"). It has no fallback: a RoCE setup error ends the boot. A 48 h
#                     watch on spark1 (ops/roce-watch/) rolls back to nccl on a RoCE error, a
#                     stall, an unplanned restart or a broken pair. Rollback by hand: COMM=nccl here,
#                     copy the file to spark1, restart glm53-serve.
#   SOCKET_IFNAME     NCCL's out-of-band bootstrap netdev. On a triangle no CX7 netdev reaches both
#                     peers, so the OOB must ride the LAN. It also needs the cluster-peer ufw rules
#                     in docs/tp3-bring-up.md ("LAN peer rules"): without them ncclCommInitRank hangs
#                     forever with no error.
#   TP=3             start-tp3.sh exports this. Without it ./start.sh serves the PAIR with WORKER2
#                     configured but unused, which a dry-run compare caught on 2026-11-05: the unit
#                     would have silently dropped TP=3 back to TP=2 on any restart.
TP=3
COMM=roce
SOCKET_IFNAME=${GLM_SOCKET_IFNAME:-enP7s7}
WORKER2=${GLM_WORKER2:-user@192.0.2.216}          # spark3, rank 2
FABRIC_PEER2=${GLM_FABRIC_PEER2:-198.18.4.216}        # spark3 on cable C. KEEP THIS: see the note above.
WORKER_WEIGHTS2=copy
WORKER_HF_CACHE2=${GLM_HF_CACHE:-$HOME/models/hf-cache}
