#!/usr/bin/env bash
# Install or remove the GLM-5.3 watch on a cluster Spark (idempotent). Run as a sudo-capable user ON the host, from
# a copy of this directory:
#   ./glm53-textfile-apply.sh head      spark1: marker, the glm53-serve unit, /health and the rank container
#   ./glm53-textfile-apply.sh worker    spark2 and spark3 (TP=3 since 2026-11-05): the rank container only (ranks 1 and 2 have no
#                        unit; the head starts them over SSH)
#   ./glm53-textfile-apply.sh remove    stop the timer and delete the files, glm53.prom too
# DRY_RUN=1 prints the commands and the settings file and changes nothing.
#
# The settings file /etc/default/glm53-textfile takes these from the environment (defaults in brackets):
#   GLM_UNIT [glm53-serve.service on head, empty on worker]   GLM_HEALTH_URL [http://127.0.0.1:8888/health on head]
#   GLM_MARKER [$HOME/glm53/GLM_ACTIVE on head, empty on worker]   GLM_CONTAINER [glm53-flash-tf]
#   GLM_START_GRACE_S [2400: sized for loads over NFS, 10-25 min; an NVMe start takes 2.5-6 min plus the kernel build]
#   GLM_MEMGUARD_BIN [$HOME/glm53/bin/memguard.sh]   GLM_MEMGUARD_PID [$HOME/glm53/state/memguard.pid]
#   (every node: glm53-memguard.sh, ops/, starts memguard on each node with these paths)
#
# Order: install on every node before GLM serves. Without the marker every glm53 rule is quiet (glm53_active 0).
# Create the marker on the head (touch GLM_MARKER) when GLM serves. The watch can stay installed: without the marker
# every glm53 rule is quiet. `remove` deletes it.
set -euo pipefail
cd "$(dirname "$0")"
role=${1:-}
d=${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}
conf=/etc/default/glm53-textfile
run() { if [ "${DRY_RUN:-0}" = 1 ]; then printf '+ %s\n' "$*"; else "$@"; fi; }

case "$role" in
  head)   unit=${GLM_UNIT-glm53-serve.service}; health=${GLM_HEALTH_URL-http://127.0.0.1:8888/health}
          marker=${GLM_MARKER-$HOME/glm53/GLM_ACTIVE} ;;
  worker) unit=${GLM_UNIT-}; health=${GLM_HEALTH_URL-}; marker=${GLM_MARKER-} ;;
  remove)
    run sudo systemctl disable --now glm53-textfile.timer || true
    run sudo rm -f /etc/systemd/system/glm53-textfile.service /etc/systemd/system/glm53-textfile.timer \
      /usr/local/bin/glm53-textfile.sh "$conf" "$d/glm53.prom"
    run sudo systemctl daemon-reload
    exit 0 ;;
  *) echo "usage: glm53-textfile-apply.sh head|worker|remove" >&2; exit 2 ;;
esac

[ -d "$d" ] || [ "${DRY_RUN:-0}" = 1 ] || { echo "no $d on $(hostname): node-exporter textfile collector not set up" >&2; exit 1; }
settings=$(cat <<EOT
# written by ops/glm53-textfile-apply.sh $role $(date -u +%FT%TZ); read by glm53-textfile.sh
GLM_UNIT=$unit
GLM_HEALTH_URL=$health
GLM_MARKER=$marker
GLM_CONTAINER=${GLM_CONTAINER:-glm53-flash-tf}
GLM_START_GRACE_S=${GLM_START_GRACE_S:-2400}
GLM_MEMGUARD_BIN=${GLM_MEMGUARD_BIN:-$HOME/glm53/bin/memguard.sh}
GLM_MEMGUARD_PID=${GLM_MEMGUARD_PID:-$HOME/glm53/state/memguard.pid}
EOT
)
if [ "${DRY_RUN:-0}" = 1 ]; then
  echo "+ write $conf:"; printf '%s\n' "$settings"
else
  tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$settings" > "$tmp"
  sudo install -m 0644 "$tmp" "$conf"
fi
run sudo install -m 0755 glm53-textfile.sh      /usr/local/bin/glm53-textfile.sh
run sudo install -m 0644 glm53-textfile.service /etc/systemd/system/glm53-textfile.service
run sudo install -m 0644 glm53-textfile.timer   /etc/systemd/system/glm53-textfile.timer
run sudo systemctl daemon-reload
run sudo systemctl enable --now glm53-textfile.timer
run sudo systemctl start glm53-textfile.service   # first sample now, not at the next tick
[ "${DRY_RUN:-0}" = 1 ] && exit 0
echo "== verify on $(hostname) =="
cat "$d/glm53.prom"
curl -s --max-time 15 http://localhost:9100/metrics | grep -E '^glm53_' || { echo "node-exporter is not serving glm53_*" >&2; exit 1; }
