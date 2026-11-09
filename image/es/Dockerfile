# PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True on the production GLM-5.3 image: kit issue #143
# (open) - TensorFold sets expandable_segments for its Qwen families via _set_allocator_settings but
# never for glm5_next, so the caching allocator retains and fragments device memory under traffic
# (three independent confirmations in #143; open PR #189 proposes this exact default). On GB10 a
# plain cudaMalloc is charged to neither the process nor its cgroup (NVIDIA forum t/387182), so the
# growth shows only in host MemAvailable. It copies no files: one ENV on the production image
# (tensorfold-glm53:v0.6.0-789e8f3bdfa2-p0131m2-20261103). Build it with build.sh on each Spark:
# from the local production tag, --pull=false, --network=none.
ARG BASE=tensorfold-glm53:v0.6.0-789e8f3bdfa2-p0131m2-20261103
FROM ${BASE}
# start.sh passes only TENSORFOLD_*, TF_GLM_* and TF_ROCE_* into the containers, so it is set here
# (the same reason MALLOC_ARENA_MAX=2 lives in the p0131m2 image).
ENV PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
# tf.patches and lab.patches stay the base's: start.sh keys the compiled-kernel cache on tf.patches,
# and this change alters no kernel and no file - allocator mode only.
LABEL lab.env="MALLOC_ARENA_MAX=2, PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True" \
      lab.base="tensorfold-glm53:v0.6.0-789e8f3bdfa2-p0131m2-20261103" \
      lab.es="kit #143 / PR #189, expandable_segments for glm5_next"
