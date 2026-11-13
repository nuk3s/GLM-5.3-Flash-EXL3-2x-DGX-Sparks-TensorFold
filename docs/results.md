# Measured results

All figures come from this cluster: three GB10 nodes at TP=3, `PARALLEL=8`, a 1,048,576-token window, FP8 KV,
KV sharding on, an 800 GiB spill tier, the kit at `bf5f945` and the image in `image/`. The `image/es/` layer went
live on 2026-11-08; the tables measured before that date ran without it. Before each benchmark the engine was
closed to all other clients, and `/health` showed `requests_running` 0. The items marked "real traffic" under
"Other measurements" come from production traffic. A throughput figure taken while
other requests run measures contention: one such run read 77.9 tok/s against a true 127.9.

## TP=3 against the pair

The same kit on two of the three nodes (6 lanes) and then on all three (8 lanes), 2026-11-05, our decode gate:

| | pair, 6 lanes | TP=3, 8 lanes |
|---|---|---|
| KV pool | 2,867,200 tokens | 7,710,720 tokens (2.69 times; 8,232,960 at 6 lanes) |
| decode, 1 stream | 48 to 50 tok/s | 56.2 tok/s |
| decode, all lanes busy | 96.0 tok/s at 6 | 127.9 tok/s at 8 |
| prefill, 32K and 131K | about 2,000 and 1,950 tok/s | 2,256 and 2,399 tok/s |
| TTFT p50 | | 0.104 s |
| load time | about 4 min | 5.75 min |

`PARALLEL=8` gave the same decode as 6 at 1, 4 and 6 streams, and 11% more with all lanes busy, for a pool 6.3%
smaller.

## Decode on the kit's own harness

The kit's TP=3 tables use sparkDash (`MiaAI-Lab/sparkDash`). The same engine reads differently on different
harnesses, so the decode rows below use sparkDash for both columns. The prefill and TTFT rows mix harnesses:
the kit's figures are sparkDash (prefill from its 4-stream three-Spark table, TTFT from its `PARALLEL=8` table), and
ours come from our gate run of 2026-11-05.

| | kit TP=3, `PARALLEL=8` | this cluster, `COMM=nccl` |
|---|---|---|
| prose, 1 stream | 65.7 tok/s | 69.5 to 69.8 tok/s |
| prose, 8 streams | 166.0 tok/s | 177.2 and 178.0 tok/s |
| code, 8 streams | 211.5 tok/s | 221.4 and 221.6 tok/s |
| KV pool | about 4.0M tokens | about 7.7M tokens |
| prefill, 131K (kit: sparkDash, 4 streams; ours: our gate) | 1,881.7 tok/s | 2,399 tok/s |
| TTFT p50, 1 stream (kit: sparkDash; ours: our gate) | 143 ms | 104 ms |

One stream: sparkDash DecodeBench, 400 tokens forced, temperature 0, thinking off, a 32-token warm-up, streamed,
(n - 1) / (time of the last token - time of the first token), four runs on three starts. Eight streams: the
concurrent wave of sparkDash, 400 tokens a stream, temperature 0, thinking off, two starts; the figure is the
wave's decode tokens over the time from the first token of any stream to the last token of any stream. The kit
states a 2,200 MHz GPU clock cap for its two-node table. This cluster ran at the default clocks (applied limit
2,418 MHz), so part of the difference can be the clock.

Our own decode gate read 55.8 and 55.7 tok/s at one stream in the same window as the 69.5 and 69.7 above. The
gate sends a temperature 0.7 essay, stops at the natural end (about 520 tokens), is not streamed and counts the
time to the first token. Milliseconds a decode round were close on both harnesses (43 on sparkDash, 42 on the
gate). Accepted drafts a round were not (2.00 against 1.37): the drafter accepts more on the greedy explanation
prompt of sparkDash. Formula and streaming mode together add 1 to 2 percent. Do not compare a decode figure from
one harness with a figure from another.

## `COMM=roce` at TP=3

Every kit TP=3 table uses `COMM=nccl`. On 2026-11-07, `COMM=roce` ran at TP=3 against `COMM=nccl` in one window,
each on a fresh start. Three exact prompts gave identical tokens, and accepted drafts a round were identical. The
RoCE start took 158 s and printed no RoCE error.

| | `COMM=nccl` | `COMM=roce` | ms a round | noise |
|---|---|---|---|---|
| prose, 1 stream, sparkDash | 69.81 tok/s | 76.74 tok/s | -9.0% | 0.63% |
| prose, 1 stream, our gate | 56.10 tok/s | 61.40 tok/s | -8.7% | 0.49% |
| prose, 8 streams, sparkDash | 178.01 tok/s | 181.97 tok/s | -2.0% | 0.26% |
| code, 8 streams, sparkDash | 221.57 tok/s | 225.07 tok/s | -1.1% | 0.79% |

The all-gathers of a decode round are small, and their cost is latency. The kit measured a 16 KiB all-gather at
11 us over RoCE against 45 us on NCCL. The gain is largest at one stream (43 ms a round) and smaller at 8 streams
(127 ms a round). At world 3 each pair of ranks gets two stripes, one for each subnet, and GID index 3 on all 12
devices. This cluster adopted `COMM=roce` on 2026-11-07 under a 48-hour watch that returns to NCCL on a RoCE error
line, a stall, an unplanned restart or the broken latch (`ops/roce-watch/`). On 2026-11-08 the watch returned to
NCCL after an unplanned restart that was not a RoCE fault: the memory guard on spark3 killed rank 2 at its 2.5 GiB
floor, because device memory grew with traffic (kit issue #143). The engine logged 0 RoCE errors in the whole watch.
With the expandable_segments layer (operations.md, "The image") the growth stopped: +2.43 GiB over ten 77K-token
turns of new kept states, then flat. `COMM=roce` was then adopted again under a new 48-hour watch. That watch
passed on 2026-11-10. It found no RoCE error line, stall, unplanned restart or broken latch. `COMM=roce` is kept. A
RoCE setup error or an all-gather timeout ends the rank; the engine does not change to NCCL by itself. `COMM=roce`
with `TF_GLM_HC_SPLIT=1` is also the environment of kit issue #163, a TP=2 wedge that is still open.

## KV sharding

One start for each arm, the same window, our decode gate, 2026-11-06:

| arm | KV pool | prose, 1 stream | code, 1 stream | ms a round |
|---|---|---|---|---|
| `TF_GLM_KV_SHARD=1`, 8 lanes | 7,778,304 | 55.6 / 55.7 tok/s | 80.2 tok/s | 44.4 |
| `TF_GLM_KV_SHARD=0`, 8 lanes | 2,902,016 | 57.8 / 57.8 tok/s | 82.6 tok/s | 42.8 |
| `TF_GLM_KV_SHARD=0`, 1 lane | | 58.5 / 59.9 tok/s | 84.9 tok/s | 41.7 |

Sharding costs 3.8% prose and 3.0% code at one stream, and it gives 2.68 times the pool. The engine refuses
sharding at one lane.

## Other measurements

- Content changes decode by 26%. The same engine and settings, only the prompt content changed: code and
  structured output 161.2 tok/s at 8 streams (a code concurrency driver), prose 128.2 (our gate). Acceptance
  for each draft is 73.2% on code
  and 49.3% on prose. A decode figure from a prose gate is low for agent traffic.
- Drafter acceptance, real traffic, 176,152 decode rounds in 12 hours: 60.0% acceptance (median 59.7, range
  39.3 to 88.8), 2.28 accepted tokens a round, 3.79 drafts a round. The DFlash2 curve predicts 2.314, and a bench
  read 2.324.
- Prefix cache, real traffic: 95.75% of prompt tokens came from the cache (13,003,456 of 13,580,849 over the
  measurement window).
- `DRAFT_POLICY=fnc7:0.3` (the kit default) is the best measured value. A five-policy sweep by another user put it
  first at 54.7 tok/s, with every fixed policy 13 to 20% slower. The sixth draft returns 0.042 tokens a
  millisecond against the round's 0.057, so it costs more than it gives.
- `TF_GLM_MULTI_DEPTH=scale:A`: +2.3% prose and -5.9% code, flat between A=1 and A=2. It raises the stop
  threshold of each stream, so rounds draft shorter chains. That helps when acceptance is low and costs when it
  is high.
- `TF_GLM_MULTI_DEPTH=joint` carries all of the gain of kit PR #141. At TP=3, `packed`, `async` and
  `TF_GLM_EXL3_LOADS=nc2` or `nc4` were flat, and `TF_GLM_QMM_CLUSTERS=1` was slower. The full four-setting set
  gave +4.6% at 8 streams (the author measured +4.10%) and cost about 2% at one stream (1.7% with all four
  settings, 2.5% with three of them). This cluster does not use it.
