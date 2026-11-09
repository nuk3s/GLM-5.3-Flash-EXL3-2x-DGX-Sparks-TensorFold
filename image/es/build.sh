#!/usr/bin/env bash
# Build the expandable_segments thin image on this Spark, from this folder (about 4 kB). Nothing is
# pulled: the base tag must be on this host already (it is the running production image). The RUN
# steps have no network and there are none. Run it on all three Sparks.
#   bash build.sh            # TAG and BASE below; override with TAG=... BASE=...
set -euo pipefail
cd "$(dirname "$0")"
BASE=${BASE:-tensorfold-glm53:v0.6.0-789e8f3bdfa2-p0131m2-20261103}
TAG=${TAG:-tensorfold-glm53:v0.6.0-789e8f3bdfa2-p0131m2-es-20261108}
avail=$(awk '/^MemAvailable:/ {print int($2 / 1048576)}' /proc/meminfo)
echo "build.sh: $(hostname): $BASE -> $TAG; MemAvailable ${avail} GiB"
docker build --pull=false --network=none --build-arg BASE="$BASE" -t "$TAG" . >build.log 2>&1 \
  || { tail -30 build.log >&2; echo "build.sh: docker build failed (build.log)" >&2; exit 1; }
docker image inspect -f 'build.sh: {{index .RepoTags 0}} {{.Id}} lab.env={{index .Config.Labels "lab.env"}}' "$TAG"
docker image inspect -f '{{index .Config.Env}}' "$TAG" | tr " " "\n" | grep PYTORCH_CUDA_ALLOC_CONF
