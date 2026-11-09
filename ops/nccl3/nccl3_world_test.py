#!/usr/bin/env python3
"""Minimal 3-rank NCCL communicator test, mirroring tensorfold/cuda/comm.py exactly.

Isolates "can NCCL form a world=3 communicator on this switchless triangle" from anything the
engine does. Same TCPStore rendezvous, same ncclGetUniqueId / ncclCommInitRank via ctypes, then one
tiny all-gather to prove the comm actually works.

  rank 0:  nccl3.py --rank 0 --world 3 --master <addr> --port 29599
  rank i:  nccl3.py --rank i --world 3 --master <addr> --port 29599

Exits 0 on a working comm, 1 on an NCCL error, and prints a stage line before each blocking call so
a hang names its own stage.
"""
import argparse, ctypes, os, sys, time

def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] rank {os.environ.get('R','?')}: {msg}", flush=True)

class _UniqueId(ctypes.Structure):
    _fields_ = [("internal", ctypes.c_byte * 128)]

def library():
    for path in ("libnccl.so.2", "libnccl.so"):
        try:
            return ctypes.CDLL(path)
        except OSError:
            continue
    raise RuntimeError("libnccl not found")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rank", type=int, required=True)
    ap.add_argument("--world", type=int, default=3)
    ap.add_argument("--master", required=True)
    ap.add_argument("--port", type=int, default=29599)
    ap.add_argument("--store-timeout", type=int, default=120)
    a = ap.parse_args()
    os.environ["R"] = str(a.rank)

    import torch
    from datetime import timedelta
    from torch.distributed import TCPStore

    log(f"torch {torch.__version__}, cuda device count {torch.cuda.device_count()}")
    for k in sorted(os.environ):
        if k.startswith("NCCL_"):
            log(f"  env {k}={os.environ[k]}")

    lib = library()
    lib.ncclGetErrorString.restype = ctypes.c_char_p
    lib.ncclGetErrorString.argtypes = [ctypes.c_int]
    lib.ncclGetUniqueId.argtypes = [ctypes.POINTER(_UniqueId)]
    lib.ncclCommInitRank.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.c_int, _UniqueId, ctypes.c_int]
    lib.ncclAllGather.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                                  ctypes.c_void_p, ctypes.c_void_p]

    def check(code, what):
        if code != 0:
            log(f"FAIL {what}: NCCL error {code}: {lib.ncclGetErrorString(code).decode()}")
            sys.exit(1)

    log(f"STAGE 1 TCPStore({a.master}, {a.port}, world={a.world}, is_master={a.rank == 0})")
    store = TCPStore(a.master, a.port, a.world, a.rank == 0, timeout=timedelta(seconds=a.store_timeout))
    log("STAGE 1 ok: store formed")

    uid = _UniqueId()
    if a.rank == 0:
        check(lib.ncclGetUniqueId(ctypes.byref(uid)), "ncclGetUniqueId")
        store.set("uid", bytes(uid.internal))
        log("STAGE 2 ok: uid published")
    else:
        raw = store.get("uid")
        ctypes.memmove(ctypes.addressof(uid), raw, 128)
        log("STAGE 2 ok: uid received")

    torch.cuda.set_device(0)
    torch.cuda.current_device()
    log("STAGE 3 cuda context ready")

    comm = ctypes.c_void_p()
    log(f"STAGE 4 ncclCommInitRank(world={a.world}, rank={a.rank})  <-- the call that hangs in the engine")
    t0 = time.time()
    check(lib.ncclCommInitRank(ctypes.byref(comm), a.world, uid, a.rank), "ncclCommInitRank")
    log(f"STAGE 4 ok: communicator formed in {time.time()-t0:.1f}s")

    send = torch.full((4,), float(a.rank), device="cuda", dtype=torch.float32)
    recv = torch.zeros(4 * a.world, device="cuda", dtype=torch.float32)
    log("STAGE 5 all_gather")
    check(lib.ncclAllGather(send.data_ptr(), recv.data_ptr(), send.numel(), 7, comm,
                            torch.cuda.current_stream().cuda_stream), "ncclAllGather")
    torch.cuda.synchronize()
    got = recv.tolist()
    want = [float(r) for r in range(a.world) for _ in range(4)]
    log(f"STAGE 5 ok: {got}")
    if got != want:
        log(f"FAIL all_gather mismatch, want {want}")
        sys.exit(1)
    log("PASS: world=3 communicator works and all_gather is correct")

if __name__ == "__main__":
    main()
