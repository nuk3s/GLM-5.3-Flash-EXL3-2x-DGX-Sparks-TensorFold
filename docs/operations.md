# Operations

`ops/` holds the supervision stack that this cluster runs around the kit. The head (spark1) runs every unit. The
workers (spark2, spark3) run only their rank container, which the head starts over ssh, and the optional memory
guard and textfile exporter.

## Install

1. Clone this repository to `$GLM_HOME/kit` on the head (`$HOME/glm53/kit` by default). Build the image on every
   node ("The image" below), and put the weights where `GLM_HF_CACHE` points on every node.
2. Copy `ops/hosts.conf.example` to `$GLM_HOME/bin/hosts.conf` and set every value. Each script reads it at run
   time from its own folder (`roce-watch.sh` from `../bin/`, `local.sh` from `kit/scripts/../../bin/`), and
   `GLM_HOSTS_CONF` names another file.
3. From `$GLM_HOME/kit`, copy the scripts and the configuration:

   ```sh
   mkdir -p "$GLM_HOME/bin" "$GLM_HOME/state" "$GLM_HOME/logs"
   install -m 0755 ops/glm53-prestart.sh ops/glm53-memguard.sh ops/glm53-watchdog.sh ops/glm53-units.sh "$GLM_HOME/bin/"
   install -m 0644 ops/*.service.in ops/glm53-watchdog.timer "$GLM_HOME/bin/"
   cp ops/local.sh "$GLM_HOME/kit/scripts/local.sh"
   ```

4. Render and install the units on the head, then enable them:

   ```sh
   bash "$GLM_HOME/bin/glm53-units.sh" render /tmp/glm53-units
   sudo install -m 0644 /tmp/glm53-units/*.service "$GLM_HOME/bin/glm53-watchdog.timer" /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now glm53-serve.service glm53-watchdog.timer
   ```

5. Optional, on every node: the memory guard (below) and the textfile exporter. As `GLM_USER` (the script calls
   sudo itself): `bash ops/glm53-textfile-apply.sh head` on the head, `bash ops/glm53-textfile-apply.sh worker` on
   the workers. It needs the textfile collector of node-exporter in `/var/lib/node_exporter/textfile`.

The unit runs as `GLM_USER`. That user needs the docker group and a key-based ssh login to both workers.

## The image

`image/` is the build context of the production image: the kit's published image (`tf.patches=789e8f3bdfa2`)
plus one patch, `0131-glm-stream-tool-calls` (tool-call arguments stream while they decode; the same code as kit
PR #244, numbered 0132 there), plus `MALLOC_ARENA_MAX=2` (kit issue #154). It copies two changed engine files only,
checks the base files and the new files by sha256, and builds with no network. On every node:

```sh
docker image inspect -f '{{index .Config.Labels "tf.patches"}}' tensorfold-glm53:v0.6.0   # must print 789e8f3bdfa2
bash image/build.sh       # tag tensorfold-glm53:v0.6.0-789e8f3bdfa2-p0131m2-20261103, the base of the next step
bash image/es/build.sh    # tag tensorfold-glm53:v0.6.0-789e8f3bdfa2-p0131m2-es-20261108, the IMAGE line of ops/local.sh
```

`image/es/` adds one setting to that image: `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` (kit issue #143, PR
#189). TensorFold sets it for its Qwen families but not for `glm5_next`. Without it the caching allocator keeps and
fragments device memory under traffic. On GB10 that memory shows only as falling host `MemAvailable`, so the memory
guard kills a rank after hours of traffic. The layer copies no files and changes no kernel.

## Start, stop and restart

Use `systemctl` only. A start by hand with `./start-tp3.sh` does not run the configuration of the unit
(`docs/tp3-bring-up.md`, "TP=3 under systemd").

```sh
sudo systemctl restart glm53-serve       # about 6 minutes with the weights on each node's NVMe
curl -s localhost:8888/health | python3 -c 'import json,sys; h=json.load(sys.stdin); print(h["ok"], h.get("requests_running"))'
sudo systemctl stop glm53-serve          # stops all three ranks
```

Before the unit starts the engine, `glm53-prestart.sh` waits up to 300 s for ssh on both workers. It refuses when a
rank 0 container already runs. It stops a rank that runs alone on a worker (the state after a head hang and a
power cycle, kit issue #159). It refuses when a node has less than 95 GiB `MemAvailable` at TP=3, also after one
page-cache drop. Then `glm53-memguard.sh start` starts the guard on all three nodes, when it is installed. When
the unit stops, `ExecStopPost` stops the rank container on each node, as a backstop for `stop.sh`.

## Watchdog

`glm53-watchdog.timer` runs one tick every 2 minutes. A tick does nothing when the unit is not enabled, when the
marker `$GLM_HOME/state/HOLD` exists, or in the 40 minutes after a start. Otherwise it reads `/health` (10 s). It
restarts the engine at once on the broken latch (`"ok": false`). It counts a failed tick for no answer, a step
older than 360 s, a rank container that does not run (all three at TP=3), or a failed 8-token chat probe (120 s)
when no request runs. Two failed ticks in a row restart the engine. At most three restarts in an hour; after that
the tick holds and sends one ntfy message an hour. A unit that systemd marked failed is never restarted; the tick
sends one message an hour. Set `NTFY_BASE` and `NTFY_TOPIC_CRIT` in `hosts.conf` for the messages; an empty
`NTFY_BASE` sends none.

To stop the watchdog for planned work: `touch $GLM_HOME/state/HOLD`. Remove the file after the work.

## Memory guard

A GB10 can stop responding before the kernel's OOM killer acts. `glm53-memguard.sh` starts a guard on each node
that kills the rank container when `MemAvailable` stays under 2.5 GiB for 4 s, or falls under 1 GiB in two samples.
A kill ends the rank, `start.sh` exits, and systemd restarts the unit. The guard is optional by installation:
without `$GLM_HOME/bin/memguard.sh` the unit starts with no guard. When the file is installed, a guard that fails
to start on any node fails the start.

Install the guard script from MiaAI-Lab's DeepSeek V4.1 kit (Apache-2.0) on every node:

```sh
curl -fsSL -o "$GLM_HOME/bin/memguard.sh" \
  https://raw.githubusercontent.com/MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks/31457d05f8917301bbf609c3d12c7f364af8a4a6/scripts/memguard.sh
echo "9797d0f3aa4ee758183e9f94e00b0a43b5ca3e5761d724895070845c34f079d4  $GLM_HOME/bin/memguard.sh" | sha256sum -c
```

This cluster runs a copy of that script from a local merge of that kit's pull requests. It adds a memory log line,
and it has the same command line.

## The RoCE watch

`ops/roce-watch/roce-watch.sh` watched the adoption of `COMM=roce` for 48 hours, with one automatic return to
NCCL. It runs on the head from a transient systemd timer, one poll a minute. It reads the head and the two workers
over ssh only. Four triggers start the return: a RoCE error line from the engine's error set in any rank's log; a
stalled step (`/health` `iteration_s` over 120 s for 60 s, or 180 s once); an unplanned restart of `glm53-serve`
(a new InvocationID, `NRestarts`, an automatic restart, the failed state or a watchdog restart); the broken latch.
The return copies the staged NCCL `local.sh` back (sha256-checked), restarts once, waits for a new engine and sends
a message. A clean pass keeps RoCE and sends one message.

To install it: copy `roce-watch.sh` to `$GLM_HOME/roce-watch/`, copy the NCCL `local.sh` to
`$GLM_HOME/roce-watch/local.sh.baseline` (mode 444), then, when the RoCE engine serves:

```sh
bash $GLM_HOME/roce-watch/roce-watch.sh check --base-sha <sha256 of the NCCL local.sh> --roce-sha <sha256 of the RoCE local.sh>
bash $GLM_HOME/roce-watch/roce-watch.sh start --base-sha <sha256 of the NCCL local.sh> --roce-sha <sha256 of the RoCE local.sh>
```

Before a planned restart or reboot, pause it, and resume when the engine serves again. A stop of the timer is not
a pause: a restart in the gap counts as unplanned.

```sh
bash $GLM_HOME/roce-watch/roce-watch.sh pause kernel update
sudo systemctl restart glm53-serve
bash $GLM_HOME/roce-watch/roce-watch.sh resume
bash $GLM_HOME/roce-watch/roce-watch.sh status
```

`resume` checks the engine again and takes a new baseline; the paused time extends the deadline. `stop` ends the
watch with no return. After a reboot of the head, run `start` again: the state survives a reboot and the transient
timer does not.

## Return to NCCL by hand

```sh
bash $GLM_HOME/roce-watch/roce-watch.sh stop return by hand    # when the watch runs
cp $GLM_HOME/roce-watch/local.sh.baseline $GLM_HOME/kit/scripts/local.sh.tmp
sha256sum < $GLM_HOME/kit/scripts/local.sh.tmp                 # must be the NCCL sha
mv $GLM_HOME/kit/scripts/local.sh.tmp $GLM_HOME/kit/scripts/local.sh
sudo systemctl reset-failed glm53-serve; sudo systemctl restart glm53-serve
docker logs glm53-flash-tf 2>&1 | grep -c 'over RoCE'          # must print 0 on the new engine
```

Without a staged copy, set `COMM=nccl` in `scripts/local.sh` and restart.

## Tests

The tests use stub commands and touch no host:

```sh
bash ops/tests/test_glm53_watchdog.sh          # the watchdog and the pre-start checks
bash ops/tests/test_hosts_conf.sh              # hosts.conf: values, the environment, refusals
bash ops/tests/test_units_render.sh            # glm53-units.sh
bash ops/roce-watch/tests/test_roce_watch.sh   # every path of the RoCE watch
```
