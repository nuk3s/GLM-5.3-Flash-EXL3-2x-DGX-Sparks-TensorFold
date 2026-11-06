# GLM-5.3-Flash-EXL3 on three DGX Sparks at TP=3

A stripped fork of [MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold),
cut down to the one configuration this lab runs in production: **three GB10 nodes, TP=3, 8 lanes, a
1,048,576-token window, FP8 KV, KV sharding on, vision on, an NVMe spill tier.**

Upstream is the real work. This fork exists because upstream documents every knob for every topology,
and we needed one page describing one deployment, plus the measurements we took on it. Read upstream
first if you want options. Read this if you want numbers from a three-node ring.

Base commit `bf5f945`. `patches/` is **byte-identical to upstream** (verified: zero diff). See
[What changed](#what-changed).

## Measurements from this configuration

All taken with the engine firewalled off from its gateway and `requests_running` confirmed 0 first.
A throughput figure taken while production traffic is in flight is contention, not a measurement: one
such run here read 77.9 tok/s against a true 127.9, a 39% error.

### Where this configuration leads upstream's published three-Spark table

| | upstream TP=3, `PARALLEL=8` | here | delta |
|---|---|---|---|
| KV pool | ~4.0M tokens | **~7.7M tokens** | **+93%** |
| prefill, 131K | 1,881.7 tok/s | **2,399 tok/s** | **+27.5%** |
| TTFT p50, 1 stream | 143 ms | **104 ms** | **-27%** |

Pool varies per boot. Observed across seven boots: 7,649,280 / 7,686,144 / 7,692,288 / 7,710,720 /
7,735,296 / 7,766,016 / 7,778,304. Quote a range, never a single figure.

### Where it does not. Read this before citing anything above

| | upstream TP=3, `PARALLEL=8` | here | delta |
|---|---|---|---|
| prose decode, 1 stream | 65.7 tok/s | 56.2 tok/s | **-14.5%** |
| prose decode, 8 streams | 166.0 tok/s | 128.2 tok/s | **-22.8%** |
| code decode, 8 streams | 211.5 tok/s | 161.2 tok/s | **-23.8%** |

**Decode here is 14 to 24 percent below upstream's published figures on every cell, and the cause is
not isolated.** Our decode lands at roughly upstream's published *two-Spark* level while pool and
prefill gain. Known differences: our GPU clocks are not capped (2,418 MHz applied) where upstream's
table was taken at 2,200 MHz; we run KV sharding and an 800 GiB spill tier, neither of which appears
in any upstream table; and our harness is not upstream's sparkDash. Do not read the pool and prefill
wins as a speed claim.

### Things measured here that had no published number anywhere

**Content moves decode 26 percent, and the usual benchmark hides it.** Same engine, same config, only
the prompt content changed: **code and structured output 161.2 tok/s at 8 streams against prose
128.2.** Per-draft acceptance is 73.2% on code against 49.3% on prose. Any decode figure from a prose
gate understates what agent traffic gets.

**Real-traffic drafter acceptance, over 176,152 decode rounds in a 12-hour window:** 60.0% acceptance
(median 59.7, range 39.3-88.8), **2.28 accepted tokens a round**, 3.79 drafts a round. That sits
between the two synthetic workloads and is a third independent confirmation that DFlash2 performs to
its published curve (predicted 2.314, bench 2.324, real traffic 2.28).

**Prefix cache hit rate on real traffic: 95.75%** (13,003,456 cached of 13,580,849 prompt tokens over
a two-minute window), with TTFT of 0.94 s for a 487,378-token prompt.

**`TF_GLM_MULTI_DEPTH=scale:A`, first measurement anywhere:** +2.3% prose, **-5.9% code**, saturating
between A=1 and A=2. It raises each stream's stop threshold, so rounds draft shorter, higher-confidence
chains. That is free speed when acceptance is low and a loss when it is high, which is why it inverts
by workload.

**`TF_GLM_MULTI_DEPTH=joint` carries all of upstream PR #141's bundle.** Measured individually at
TP=3: `packed` flat, `async` flat, `TF_GLM_EXL3_LOADS=nc2`/`nc4` flat, `TF_GLM_QMM_CLUSTERS=1` a
regression. The full four-setting bundle repeats at **+4.6% at C8** against the author's +4.10%, and
costs 2.1% at one stream. Posted upstream on #141.

**KV sharding costs 3.8% prose and 3.0% code at one stream and buys 2.68x the pool.** Measured as a
direct A/B: pool 7,778,304 sharded against 2,902,016 unsharded, decode 55.6 against 57.8 tok/s. Worth
it here by a wide margin.

## Two things that cost us three windows

**A three-rank cluster needs LAN peer rules in the host firewall, not only the ring interfaces.**
NCCL's out-of-band bootstrap is a ring over each node's LAN netdev on ephemeral ports, not over the
CX7 cables. One node's firewall had no peer rules, so `ncclCommInitRank` hung forever with no error
and no log line. Three engine windows found nothing; a standalone 3-rank NCCL test named the stage in
one three-minute run with no downtime. If a 3-rank bring-up hangs with logs ending at plugin load,
check the firewall before touching the engine.

**`TP`, `COMM` and `SOCKET_IFNAME` must live in `scripts/local.sh`, not in `start-tp3.sh`'s exports.**
A systemd unit that runs `./start.sh` will otherwise silently serve the pair with the third worker
configured and unused. A dry-run compare across 13 settings caught this before it shipped.

**`TF_GLM_KV_SHARD=1` is refused at one lane.** The engine says so plainly:
`TF_GLM_KV_SHARD=1 needs --parallel above 1, two ranks or more, and no TF_GLM_MULTI_LONE`. Sharding
and single-lane are mutually exclusive.

## The configuration

Topology is a switchless triangle: three QSFP DACs, each CX7 with two physical ports showing as two
PCIe halves, so four RoCE devices a node. Cable A joins spark1 p0 to spark2 p0, B joins spark2 p1 to
spark3 p0, C joins spark1 p1 to spark3 p1. RDMA measures 109 Gb/s a plane at MTU 9000. The NCCL
bootstrap rides the LAN netdev.

`scripts/local.sh` carries, with hostnames and addresses redacted:

```sh
TP=3
COMM=nccl
SOCKET_IFNAME=<lan netdev>        # NCCL out-of-band bootstrap; needs the LAN peer firewall rules
PARALLEL=8
HF_CACHE=<local nvme>             # each rank reads its own copy; load ~4 min against ~14 over NFS
WORKER_WEIGHTS=copy
WORKER_WEIGHTS2=copy
SPILL_GIB=800
SPILL_MIN_FREE_GIB=300
SPILL_MIN_TOKENS=4096
SPILL_RELEASE_MIB=1024
TF_GLM_KEPT_BYTES_GIB=4
export TF_GLM_KV_SHARD=1
export TF_GLM_CACHE_SHARE_PCT=50
export TF_GLM_SPILL_READ_BLOCKS=32
export TF_GLM_EXL3_DEC_ORDER=1
export TF_GLM_EXIT_ON_BROKEN=1
export TF_GLM_MULTI_WATCHDOG_EXIT=1
```

Defaults inherited from upstream and depended on here: `DRAFTER=dflash2`, `DRAFT_POLICY=fnc7:0.3`,
`KV=fp8`, `DENSE=q4`, `CONTEXT=1048576`, `VISION=1`, `SPLIT=1`, `KDA_CHUNKED=1`, `COPY=1`,
`TF_GLM_MULTI_WINDOW=64`.

`DRAFT_POLICY` is already at its measured optimum. A third-party five-policy sweep put `fnc7:0.3`
first at 54.7 tok/s with every fixed policy 13-20% slower, and the marginal arithmetic agrees: the
sixth draft returns 0.042 tokens a millisecond against the round's running 0.057, so it loses.
`fnc9` is an invalid value; the noise-aware families cap N at 7.

## What changed

- **`patches/` is untouched.** It cannot be reduced: `scripts/config.sh` hashes every patch file into
  `PATCHES_HASH`, and `scripts/prepare.sh` compares that against the pinned image's label. Delete one
  patch and the kit stops pulling the pinned image and builds locally instead, which must never happen
  on a serving node. All 123 patches stay, verified byte-identical to `bf5f945`.
- Removed upstream branding (two PNGs, 992K), the issue and pull-request templates, the funding file,
  and a Mac Studio qualification document for hardware we do not run.
- Removed 37 of 54 files in `tools/`: per-patch unit harnesses for engine code we never change. The
  13 kept are the gates our runbook actually calls, including the KV-shard and spill-tier correctness
  gates that no upstream benchmark covers.
- Rewrote this README for one configuration. Upstream's is 127 KB and documents every topology.
- 51 files and 8,761 lines removed. Tree 5.0 MB to 3.5 MB, 204 tracked files to 153.

`LICENSE`, `NOTICE`, `CREDITS.md` and `CHANGELOG.md` are kept unchanged. Read `NOTICE` first: it
carries the third-party notices that travel with this code.

## Credit

The engine, the kit and every patch in `patches/` are other people's work. This fork adds
measurements and deletions, nothing more.

- **[MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold)**, Copyright 2026 MiaAI-Lab, Apache-2.0. The kit, its 123 patches and its documentation. Forked at `bf5f945`.
- **[ashhart/TensorFold](https://github.com/ashhart/TensorFold)**, Copyright 2026 TensorFold contributors, Apache-2.0 from 0.6.0. The engine every patch here modifies.
- **[local-inference-lab/b12x](https://github.com/local-inference-lab/b12x)**, Apache-2.0. Its RDMA proxy and CuTe all-gather are the basis of patch 0006.
- **[jayleaton/glm53-tensorfold-spark](https://github.com/jayleaton/glm53-tensorfold-spark)**, Copyright 2026 Jay Leaton, Apache-2.0. Code adapted in patches 0036, 0046, 0047, and patch 0058 is his TensorFold PR #218 unchanged.
- The NVMe spill tier and KV sharding (patches 0088, 0128, 0129) are by **Robert Wojciechowski**, with the block layout of PR #118 by **@BadAd84**.
- **[turboderp-org/exllamav3](https://github.com/turboderp-org/exllamav3)**, MIT. The EXL3 format the routed experts are stored in.
- **[z-lab/dflash](https://github.com/z-lab/dflash)**, MIT. The DFlash2 architecture the drafter ports.
- Contributions through upstream's issues and PRs: patch 0054 (abhicnv007), 0057 (Alexbob0), 0060 (kky42), 0059 (Dorian / SxMShaDoW), 0097 (reported by @jdecker76).

Model weights are not in this repository. They are downloaded from Hugging Face: the checkpoint
`Mia-AiLab/GLM-5.3-Flash-EXL3-4bpw-TensorFold`, derived from `zai-org/GLM-5.3-Flash`, and the drafter
`incoai/GLM-5.3-Flash-DFlash2`. Check each card for its own terms.

Neither MiaAI-Lab, TensorFold nor any author above endorses this fork.
