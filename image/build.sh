#!/usr/bin/env bash
# Build the 0131 + MALLOC_ARENA_MAX=2 thin image on this Spark, from this folder (about 0.2 MB). Nothing is pulled: the base tag must be
# on this host already, with tf.patches=789e8f3bdfa2. The RUN steps have no network. Run it on every Spark that runs a rank.
#   bash build.sh            # TAG and BASE below; override with TAG=... BASE=...
set -euo pipefail
cd "$(dirname "$0")"
BASE=${BASE:-tensorfold-glm53:v0.6.0}
TAG=${TAG:-tensorfold-glm53:v0.6.0-789e8f3bdfa2-p0131m2-20261103}
sha256sum --quiet --strict -c SHA256SUMS
label=$(docker image inspect -f '{{index .Config.Labels "tf.patches"}}' "$BASE" 2>/dev/null) \
  || { echo "build.sh: no image $BASE on $(hostname); load the kit's tar first (nothing is pulled)" >&2; exit 1; }
[[ "$label" == 789e8f3bdfa2 ]] || { echo "build.sh: $BASE has tf.patches=$label, not 789e8f3bdfa2" >&2; exit 1; }
avail=$(awk '/^MemAvailable:/ {print int($2 / 1048576)}' /proc/meminfo)
echo "build.sh: $(hostname): $BASE (tf.patches $label) -> $TAG; MemAvailable ${avail} GiB"
docker build --pull=false --network=none --build-arg BASE="$BASE" -t "$TAG" . >build.log 2>&1 \
  || { tail -30 build.log >&2; echo "build.sh: docker build failed (build.log)" >&2; exit 1; }
docker image inspect -f 'build.sh: {{index .RepoTags 0}} {{.Id}} tf.patches={{index .Config.Labels "tf.patches"}} lab.patches={{index .Config.Labels "lab.patches"}}' "$TAG"
