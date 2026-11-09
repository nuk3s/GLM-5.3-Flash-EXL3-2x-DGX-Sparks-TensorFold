# GLM-5.3-Flash-EXL3 on three DGX Sparks at TP=3

This repository is the TP=3 configuration of one three-node GB10 cluster: the MiaAI-Lab GLM-5.3-Flash-EXL3
TensorFold kit at its commit `bf5f945`, cut to one configuration, plus the supervision stack, the image and the
measurements of the cluster. It is a fork of
[MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold).
The kit's README now names a successor recipe for two nodes. This repository stays on the kit at `bf5f945`,
because the successor does not serve three nodes.

## The configuration

- Three GB10 nodes (spark1, spark2, spark3) in a switchless triangle of QSFP DAC cables. DGX OS 7.6.0 (OTA2610),
  kernel `7.0.0-1019-nvidia`, driver `580.178.04`, CX7 firmware `28.50.1002` on all three.
- TP=3, `PARALLEL=8`, a 1,048,576-token window, FP8 KV, KV sharding on, an 800 GiB NVMe spill tier, each rank
  reads its own NVMe copy of the weights, `COMM=roce` (adopted 2026-11-07, back to NCCL on 2026-11-08 after a
  memory-guard kill that was not a RoCE fault, adopted again the same day: [docs/results.md](docs/results.md)).
- The kit defaults that this configuration depends on: `DRAFTER=dflash2`, `DRAFT_POLICY=fnc7:0.3`, `KV=fp8`,
  `DENSE=q4`, `CONTEXT=1048576`, `VISION=1`, `SPLIT=1`, `KDA_CHUNKED=1`, `COPY=1`, `TF_GLM_MULTI_WINDOW=64`.
- The image: the kit's published image (`v0.6.0-789e8f3bdfa2`, 123 patches) plus patch
  `0131-glm-stream-tool-calls` (the same code as kit PR #244) and `MALLOC_ARENA_MAX=2`, then one layer that sets
  `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` (kit issue #143, PR #189).
- All settings: [`ops/local.sh`](ops/local.sh). The cluster's addresses: one file, `hosts.conf`
  ([`ops/hosts.conf.example`](ops/hosts.conf.example)).

## Results

| | kit TP=3, `PARALLEL=8` | this cluster |
|---|---|---|
| KV pool | about 4.0M tokens | 7.6M to 7.8M tokens |
| prefill, 131K (kit: sparkDash, 4 streams; ours: our gate) | 1,881.7 tok/s | 2,399 tok/s |
| TTFT p50, 1 stream (kit: sparkDash; ours: our gate) | 143 ms | 104 ms |
| prose decode, 1 stream, sparkDash | 65.7 tok/s | 69.5 to 69.8 tok/s (`COMM=nccl`), 76.74 (`COMM=roce`) |
| prose decode, 8 streams, sparkDash | 166.0 tok/s | 178.0 tok/s (`COMM=nccl`), 181.97 (`COMM=roce`) |
| code decode, 8 streams, sparkDash | 211.5 tok/s | 221.6 tok/s (`COMM=nccl`), 225.07 (`COMM=roce`) |

The decode rows use the kit's own harness on both sides. The method, the RoCE A/B, the KV-sharding A/B and the
other figures are in [docs/results.md](docs/results.md).

## Contents

| path | what |
|---|---|
| `ops/` | the systemd units (templates), the pre-start checks, the watchdog, the memory-guard wrapper, the textfile exporter, the RoCE watch, the 3-rank NCCL check, `local.sh`, `hosts.conf.example`, and their tests |
| `image/` | the build context of the production image: patch 0131 and `MALLOC_ARENA_MAX=2` on the kit's image, and the expandable_segments layer in `image/es/` |
| `docs/tp3-bring-up.md` | what a three-node bring-up needs: LAN peer rules, the rendezvous address, CX7 firmware on an uncabled card, HCA pinning on a run of two of the three nodes, KV sharding, TP=3 under systemd |
| `docs/results.md` | the measurements |
| `docs/operations.md` | install, start and stop, the watchdog, the memory guard, the RoCE watch, the return to NCCL, the tests |
| everything else | the kit at `bf5f945`, cut to one configuration (below) |

## What changed from the kit

- `patches/` is identical to the kit at `bf5f945`. `scripts/prepare.sh` sets `PATCHES_HASH` from `image_hash` in
  `scripts/config.sh`, a hash over every patch file and `IMAGE_EXTRAS`, and compares it with the label of the
  pinned image. A removed patch makes
  the kit build locally instead of pulling the image.
- Removed: the kit's branding images, its issue and pull-request templates, its funding file, a Mac Studio
  qualification document, `tests/test_hermes_benchmark.py`, and 41 of the 54 files in `tools/` (unit harnesses for engine code this cluster does
  not change). The 13 kept files are the gates the cluster runs, including the KV-shard and spill-tier gates.
- This README replaces the kit's README. Read the kit's README for every option and topology.
- Added: `ops/`, `image/` and the three pages in `docs/`.

`image/tensorfold/cuda/server.py` and `image/tensorfold/cuda/reply_text.py` are TensorFold source files
(Apache License 2.0, as in the kit's `LICENSE` and `NOTICE`) with the kit's patches and patch 0131 applied; nuk3s
changed them in 2026-11. The patch file `image/0131-glm-stream-tool-calls.patch` quotes TensorFold source as context.

`LICENSE`, `NOTICE`, `CREDITS.md` and `CHANGELOG.md` are the kit's, unchanged. `NOTICE` carries the third-party
notices that apply to this code.

## Credit

The engine, the kit and every patch in `patches/` are the work of other people.

- [MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold), Copyright 2026 MiaAI-Lab, Apache-2.0: the kit, its 123 patches and its documentation. Forked at `bf5f945`.
- [ashhart/TensorFold](https://github.com/ashhart/TensorFold), Copyright 2026 TensorFold contributors, Apache-2.0 from 0.6.0: the engine that every patch changes.
- [local-inference-lab/b12x](https://github.com/local-inference-lab/b12x), Apache-2.0: its RDMA proxy and CuTe all-gather are the base of patch 0006.
- [jayleaton/glm53-tensorfold-spark](https://github.com/jayleaton/glm53-tensorfold-spark), Copyright 2026 Jay Leaton, Apache-2.0: code adapted in patches 0036, 0046 and 0047; patch 0058 is his TensorFold PR #218 unchanged.
- The NVMe spill tier and KV sharding (patches 0088, 0128 and 0129) are by Robert Wojciechowski, with the block layout of PR #118 by @BadAd84.
- [turboderp-org/exllamav3](https://github.com/turboderp-org/exllamav3), MIT: the EXL3 format of the routed experts.
- [z-lab/dflash](https://github.com/z-lab/dflash), MIT: the DFlash2 architecture that the drafter ports.
- [MiaAI-Lab/sparkDash](https://github.com/MiaAI-Lab/sparkDash), Apache-2.0: the decode harness of the results.
- [MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks](https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks), Apache-2.0: `scripts/memguard.sh`, which the memory guard runs (`docs/operations.md`; not copied here).
- Contributions through the kit's issues and PRs: patch 0054 (abhicnv007), 0057 (Alexbob0), 0060 (kky42), 0059 (Dorian / SxMShaDoW), 0097 (reported by @jdecker76).

The model weights are not in this repository. Download them from Hugging Face: the checkpoint
`Mia-AiLab/GLM-5.3-Flash-EXL3-4bpw-TensorFold`, derived from `zai-org/GLM-5.3-Flash`, and the drafter
`incoai/GLM-5.3-Flash-DFlash2`. Each card has its own terms.

MiaAI-Lab, TensorFold and the authors above do not endorse this repository.
