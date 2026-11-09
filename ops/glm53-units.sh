#!/usr/bin/env bash
# glm53-units.sh render OUT_DIR [HOSTS_CONF]: write this cluster's systemd units. Each *.service.in beside this script
# becomes OUT_DIR/<name>.service, its @NAME@ fields filled from hosts.conf (beside this script by default). The
# *.timer files and glm53-textfile.service have no fields: install them as they are. Install on the head:
#   sudo install -m 0644 OUT_DIR/*.service glm53-watchdog.timer /etc/systemd/system/ && sudo systemctl daemon-reload
# Fields: @GLM_USER@ @GLM_USER_HOME@ @GLM_HOME@ @GLM_WORKER@ @GLM_WORKER2@, and @GLM_WORKER_HOST@ (GLM_WORKER
# without its user@). A field left in the output, or a name hosts.conf does not set, refuses.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
[ "${1:-}" = render ] && [ -n "${2:-}" ] || { echo "usage: glm53-units.sh render OUT_DIR [HOSTS_CONF]" >&2; exit 2; }
out=$2
hc=${3:-${GLM_HOSTS_CONF:-$here/hosts.conf}}
[ -r "$hc" ] || { echo "glm53-units.sh: cannot read $hc (copy hosts.conf.example to hosts.conf and set it)" >&2; exit 2; }
# shellcheck source=/dev/null
. "$hc"
for v in GLM_USER GLM_USER_HOME GLM_HOME GLM_WORKER GLM_WORKER2; do
  [ -n "${!v:-}" ] || { echo "glm53-units.sh: $hc does not set $v" >&2; exit 2; }
  case ${!v} in *[[:space:]\"\'\\%\$]*) echo "glm53-units.sh: $v has a space, quote, backslash, % or \$ that a unit line cannot carry" >&2; exit 2;; esac
done
# shellcheck disable=SC2034  # read through ${!v} below
GLM_WORKER_HOST=${GLM_WORKER#*@}
shopt -u patsub_replacement 2>/dev/null || true   # bash 5.2+: '&' in a replacement must stay a literal '&'
mkdir -p "$out"
n=0
for f in "$here"/*.service.in; do
  [ -e "$f" ] || continue
  t=$(cat "$f"; printf x); t=${t%x}               # keep the file's exact bytes, final newline included
  for v in GLM_USER_HOME GLM_USER GLM_HOME GLM_WORKER_HOST GLM_WORKER2 GLM_WORKER; do
    t=${t//@$v@/${!v}}
  done
  if [[ $t =~ @GLM_[A-Z0-9_]+@ ]]; then
    echo "glm53-units.sh: $f has a field no value fills: ${BASH_REMATCH[0]}" >&2; exit 2
  fi
  dst="$out/$(basename "$f" .in)"
  printf '%s' "$t" > "$dst"
  echo "glm53-units.sh: wrote $dst"; n=$((n + 1))
done
[ "$n" -gt 0 ] || { echo "glm53-units.sh: no *.service.in beside $0" >&2; exit 2; }
