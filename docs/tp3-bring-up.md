# TP=3 bring-up

This page lists what a three-node GB10 cluster needs in addition to the kit's "3 Sparks" section. Each item cost
this cluster at least one failed start. The nodes are spark1 (rank 0, the head), spark2 (rank 1) and spark3
(rank 2). All addresses on this page are documentation addresses: replace them with your own.

## Cabling and addresses

The three Sparks form a switchless triangle of three QSFP DAC cables. Each CX7 card has two ports, and each port
shows as two PCIe halves. Thus each node has four RoCE devices: `rocep1s0f0` and `roceP2p1s0f0` on port 0,
`rocep1s0f1` and `roceP2p1s0f1` on port 1.

| cable | joins | subnets, one for each PCIe half |
|---|---|---|
| A | spark1 port 0 and spark2 port 0 | 198.18.0.0/24, 198.18.1.0/24 |
| B | spark2 port 1 and spark3 port 0 | 198.18.2.0/24, 198.18.3.0/24 |
| C | spark1 port 1 and spark3 port 1 | 198.18.4.0/24, 198.18.5.0/24 |

Cables A and C join ports with the same name. With one subnet for each PCIe half, this layout works with the
kit's NCCL settings (`NCCL_CROSS_NIC=1`, subnet-aware routing). Set the addresses with netplan or another static
method, not with `ip addr`. RDMA measured 104 to 109 Gb/s for each half at MTU 9000, after the firmware step below.
At world 3 the kit pairs each node's devices by subnet, so each pair of ranks gets two stripes, one for each subnet.

## LAN peer rules in the host firewall

NCCL's out-of-band bootstrap is a ring over the LAN netdev of each node (rank 0 to rank 1 to rank 2 to rank 0) on
ephemeral ports. It does not use the CX7 cables. Thus a node with an active host firewall must accept all traffic
from the LAN address of each other node. With ufw, on each node with an active ufw:

```sh
sudo ufw allow from 192.0.2.53  comment 'cluster peer spark1 (NCCL bootstrap ring)'
sudo ufw allow from 192.0.2.180 comment 'cluster peer spark2 (NCCL bootstrap ring)'
sudo ufw allow from 192.0.2.216 comment 'cluster peer spark3 (NCCL bootstrap ring)'
```

Rules for the ring interfaces only are not sufficient. The symptom of a missing rule: `ncclCommInitRank` does not
return, the log of each rank stops after the NCCL plugin loads, and no rank prints an error. This cluster lost
three engine windows to one missing rule on spark3. Two nodes do not show the fault when the head allows the
worker and the worker has no active firewall. A jumbo ping does not prove the path, because ufw accepts ICMP in its
own rules.

Diagnose with the 3-rank NCCL check (`ops/nccl3/`). It runs the same rendezvous and `ncclCommInitRank` as the
engine in a separate container on each node, with its own port. It prints a stage line before each blocking call,
so a hang names its stage. It needs no engine downtime. A missing peer rule shows as "STAGE 1 ... 2/3 clients
joined". With the rules in place, the communicator formed in 0.5 s.

```sh
export GLM_HOSTS_CONF=$GLM_HOME/bin/hosts.conf             # the run reads the nodes from hosts.conf
bash ops/nccl3/nccl3_world_run.sh                          # the kit's NCCL environment
bash ops/nccl3/nccl3_world_run.sh NCCL_DEBUG=INFO          # one setting changed on every rank
CLEANUP=1 bash ops/nccl3/nccl3_world_run.sh                # remove the three containers at the end
```

## The rendezvous address

At TP=3, `MASTER_ADDR` must be an address that every rank reaches. Use the LAN address of the head. The kit takes
it from the head's host name when `MASTER_ADDR` is not set. Do not keep a TP=2 value: the head's address on cable
A is correct for two nodes and wrong for three, because spark3 has no address on that subnet. spark3 then sends
the traffic to its LAN gateway and gets no reply. The kit's check (`ip route get`) passes in this case, because a
default route exists.

## CX7 firmware on an uncabled card

Make sure that the three CX7 cards run the same firmware before the first TP=3 start:

```sh
cat /sys/class/infiniband/rocep1s0f0/fw_ver     # on each node; all three must agree
```

NVIDIA's CX7 firmware manager on DGX OS (`/opt/nvidia/spark-mlnx-firmware-manager/`) checks for a cable before it
acts, and it skips a card with no cable. A node that got an OS update while its CX7 had no cable keeps the older
firmware, and the update reports no error. On this cluster spark3 stayed on 28.45.4028 while the other two moved
to 28.50.1002. Its card sent at 12.8 Gb/s and received at 104 Gb/s. After the update (`install`, then a reboot,
then `verify`) it sent at 104 Gb/s. Measure each cable in both directions with `ib_write_bw` after you connect it.

## HCA pinning when two of the three nodes run

On a triangle, each port faces one peer. When two of the three nodes run a 2-rank engine, an engine that does not
set `NCCL_IB_HCA` lets NCCL use the devices of the port that faces the third node. The first all-gather then fails
(`ncclAllGather: unhandled system error`), about 96 s into the start. This occurred on this cluster with another
TensorFold kit. For a 2-rank run on two of the three nodes, set `NCCL_IB_HCA` (and the engine's RoCE device
setting) to the two devices of the port that joins the pair, for example `rocep1s0f0,roceP2p1s0f0` for cable A.

This kit's TP=2 path already sets `NCCL_IB_HCA` to the devices of the link that it finds (`scripts/nodes.sh`), so
`./start.sh` on two of the three nodes needs no change. A hand-run NCCL test or another engine does. On the full
triangle, do not pin: at TP=3 the kit gives each node every device that faces a peer.

## KV sharding

`TF_GLM_KV_SHARD=1` stores the latent cache of each conversation once, on the rank that owns it. At TP=3 on this
cluster, the pool holds 2.68 times the tokens (7,778,304 against 2,902,016 at `PARALLEL=8`). The decode round is
3.7% longer at one stream (44.4 against 42.8 ms). The kit computes 2.66 times for three nodes. Three rules:

- Set it on every rank. `start.sh` passes each exported `TF_GLM_*` to every rank, so `export TF_GLM_KV_SHARD=1` in
  `scripts/local.sh` is sufficient. The engine refuses ranks that differ.
- It needs `PARALLEL` above 1. The engine refuses it at one lane with "TF_GLM_KV_SHARD=1 needs --parallel above 1,
  two ranks or more, and no TF_GLM_MULTI_LONE".
- It changes the signature of the spill tier, so the states stored before the change are not used again. The
  cache hit rate after the first sharded start is therefore not comparable with the rate before it.

The pool size changes from start to start. Across eleven starts it was 7,649,280 to 7,809,024 tokens. Quote a range.

## TP=3 under systemd

The kit's `FOREGROUND=1 ./start.sh` is the mode for a systemd unit. `./start.sh` reads `TP` from the environment or
from `scripts/local.sh`, and its default is 2. A unit that runs `./start.sh` with `WORKER2` set and no `TP=3`
serves two nodes, and it does not warn. `ops/local.sh` sets `TP=3`, `COMM` and `SOCKET_IFNAME` for this reason.

`./start-tp3.sh` exports `TP=3` and `COMM=${COMM:-nccl}`. The kit gives the environment priority over
`scripts/local.sh`, so a start with `./start-tp3.sh` uses NCCL even when `scripts/local.sh` sets `COMM=roce`. Thus
on this cluster a start by hand with `./start-tp3.sh` does not run the configuration of the unit. Start and stop
with `systemctl` (`docs/operations.md`).
