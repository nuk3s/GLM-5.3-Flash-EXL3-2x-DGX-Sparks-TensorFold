# Lab patch 0131 + MALLOC_ARENA_MAX=2 on the kit's GLM-5.3 image: TensorFold v0.6.0 with the kit's 123 patches (tf.patches 789e8f3bdfa2,
# GHCR digest sha256:99fe7496...), plus 0131 (GLM tool calls stream while they decode). It copies the two changed
# files only. Build it with build.sh on each Spark: from the local base tag, --pull=false, --network=none.
# No "# syntax=" line on purpose: that line makes BuildKit fetch a frontend image.
ARG BASE=tensorfold-glm53:v0.6.0
FROM ${BASE}
ARG PKG=/usr/local/lib/python3.12/dist-packages/tensorfold
COPY base.sha256 new.sha256 /opt/tf-0131/
# the base must hold the kit's engine at PKG: the two files 0131 replaces, byte for byte as v0.6.0-789e8f3bdfa2 has them
RUN cd "${PKG}" && sha256sum --strict -c /opt/tf-0131/base.sha256
COPY tensorfold/cuda/reply_text.py tensorfold/cuda/server.py ${PKG}/cuda/
COPY 0131-glm-stream-tool-calls.patch /opt/tf-patches/
# the new files, and the server modules import (no GPU, no Torch; nothing written: -B)
RUN cd "${PKG}" && sha256sum --strict -c /opt/tf-0131/new.sha256 && \
    PYTHONDONTWRITEBYTECODE=1 python -B -c "import tensorfold.cuda.server, tensorfold.cuda.http, tensorfold.server.anthropic, tensorfold.families.glm5_next.cuda.app"
# glibc malloc arenas: 2, not 8 x cores (kit issue #154: rank-0 RSS grew 450-560 MiB/h with vision traffic, 5 MiB/h
# with MALLOC_ARENA_MAX=2 over 44 h). start.sh passes only TENSORFOLD_*, TF_GLM_* and TF_ROCE_* to the containers, so
# it is set here.
ENV MALLOC_ARENA_MAX=2
# tf.patches stays the base's: start.sh keys the compiled-kernel cache on it, and 0131 changes no kernel
LABEL tf.patches=789e8f3bdfa2 \
      lab.patches="0131-glm-stream-tool-calls" \
      lab.env="MALLOC_ARENA_MAX=2" \
      lab.patch.0131.sha256="5b6211db564813c0f63e5eb39b22d04cbf53420b0b4aa3aefff413fcb282e344" \
      lab.base="tensorfold-glm53:v0.6.0 (tf.patches 789e8f3bdfa2)"
