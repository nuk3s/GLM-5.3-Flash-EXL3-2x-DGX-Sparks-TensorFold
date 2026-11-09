#!/bin/bash
# glm53-textfile: the GLM-5.3 cutover (2026-11-02) -> node-exporter textfile. Alert rules:
# the glm53 Prometheus rules. Install: glm53-textfile-apply.sh in this directory (head on spark1, workers on spark2 and spark3).
#
# GLM-5.3-Flash-EXL3 runs on the MiaAI GLM kit, spark1:8888 (job
# glm53 scrapes its /metrics). The kit runs on its defaults: a broken rank pair does NOT exit (TF_GLM_EXIT_ON_BROKEN
# =0); /health answers 200 with "ok": false and "broken". A rank stuck in one step does not exit either
# (TF_GLM_MULTI_WATCHDOG_EXIT=0); /health's iteration_s grows. This script reads what /metrics cannot show:
#   - the switch: the marker file (GLM_MARKER) that says GLM serves on the head. Every glm53 alert rule needs
#     glm53_active;
#   - the glm53-serve unit (head): automatic restarts (NRestarts), the failed state, the start time;
#   - /health (head): HTTP code, "ok", iteration_s, kept_bytes (kit issue #197: kept states that grow in a long
#     agent session), requests running;
#   - the rank container on this node (every node): docker reports it running. A lone rank waits for its peer
#     forever; start.sh's foreground watcher stops rank 0 when rank 1 exits, and this shows either side;
#   - memguard on this node (every node; ops/glm53-memguard.sh): installed (GLM_MEMGUARD_BIN exists) and
#     running (the pid in GLM_MEMGUARD_PID is a memguard process). Not installed = the operator runs GLM without it.
# Settings come from /etc/default/glm53-textfile (glm53-textfile-apply.sh writes it). The worker has no unit, no health URL and no
# marker. Runs as root (docker and systemctl reads).
set -u
CONF=${GLM53_CONF:-/etc/default/glm53-textfile}
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"
DIR=${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}
OUT="$DIR/glm53.prom"
GLM_UNIT=${GLM_UNIT-glm53-serve.service}                          # empty: no unit metrics (worker)
GLM_HEALTH_URL=${GLM_HEALTH_URL-http://127.0.0.1:8888/health}     # empty: no health probe (worker)
GLM_MARKER=${GLM_MARKER-$HOME/glm53/GLM_ACTIVE}            # empty: no marker metric (worker)
GLM_CONTAINER=${GLM_CONTAINER:-glm53-flash-tf}
GLM_START_GRACE_S=${GLM_START_GRACE_S:-2400}  # 40 min, sized for loads over NFS (10-25 min); an NVMe start: 2.5-6 min + kernel build
GLM_MEMGUARD_BIN=${GLM_MEMGUARD_BIN-$HOME/glm53/bin/memguard.sh}   # empty: no memguard metrics
GLM_MEMGUARD_PID=${GLM_MEMGUARD_PID-$HOME/glm53/state/memguard.pid}
NOW=${GLM53_NOW:-$(date +%s)}

tmp=$(mktemp "$DIR/.glm53.XXXXXX") || exit 1
trap 'rm -f "$tmp"' EXIT
num() { [[ $1 =~ ^[0-9]+$ ]] && echo "$((10#$1))" || echo 0; }   # "000" (curl: no answer) -> 0

# --- the rank container on this node ---------------------------------------------------------------------------
rank=0
[ "$(docker inspect -f '{{.State.Running}}' "$GLM_CONTAINER" 2>/dev/null)" = true ] && rank=1

# --- memguard on this node -------------------------------------------------------------------------------------
mg_lines=""
if [ -n "$GLM_MEMGUARD_BIN" ]; then
  mg_inst=0; [ -s "$GLM_MEMGUARD_BIN" ] && mg_inst=1
  mg_up=0; p=$(cat "$GLM_MEMGUARD_PID" 2>/dev/null)
  [[ $p =~ ^[1-9][0-9]*$ ]] && grep -q memguard "/proc/$p/cmdline" 2>/dev/null && mg_up=1
  mg_lines=$(cat <<EOT
# HELP glm53_memguard_installed 1 if memguard is installed for GLM on this node ($GLM_MEMGUARD_BIN).
# TYPE glm53_memguard_installed gauge
glm53_memguard_installed $mg_inst
# HELP glm53_memguard_up 1 if the memguard process of $GLM_MEMGUARD_PID runs.
# TYPE glm53_memguard_up gauge
glm53_memguard_up $mg_up
EOT
)
fi

# --- glm53-serve unit (head) --------------------------------------------------------------------------------------
unit_lines=""; is_active=0; restarts=0; start=0
if [ -n "$GLM_UNIT" ]; then
  declare -A U=()
  while IFS='=' read -r k v; do [ -n "$k" ] && U[$k]=$v; done < <(systemctl show --timestamp=unix \
    -p LoadState,UnitFileState,ActiveState,NRestarts,ExecMainStartTimestamp "$GLM_UNIT" 2>/dev/null)
  loaded=0; [ "${U[LoadState]:-}" = loaded ] && loaded=1
  enabled=0; [ "${U[UnitFileState]:-}" = enabled ] && enabled=1
  st=${U[ActiveState]:-}
  is_active=0; [ "$st" = active ] && is_active=1
  failed=0; [ "$st" = failed ] && failed=1
  restarts=$(num "${U[NRestarts]:-}")
  v=${U[ExecMainStartTimestamp]:-}; start=$(num "${v#@}")
  unit_lines=$(cat <<EOT
# HELP glm53_serve_loaded 1 if systemd knows the GLM unit ($GLM_UNIT).
# TYPE glm53_serve_loaded gauge
glm53_serve_loaded $loaded
# HELP glm53_serve_enabled 1 if the GLM unit is enabled.
# TYPE glm53_serve_enabled gauge
glm53_serve_enabled $enabled
# HELP glm53_serve_active 1 if the GLM unit is active (Type=simple: also while the model loads).
# TYPE glm53_serve_active gauge
glm53_serve_active $is_active
# HELP glm53_serve_failed 1 if the GLM unit is failed (for example the start limit is reached).
# TYPE glm53_serve_failed gauge
glm53_serve_failed $failed
# HELP glm53_serve_restarts systemd automatic restarts of the GLM unit (NRestarts; a manual start resets it).
# TYPE glm53_serve_restarts gauge
glm53_serve_restarts $restarts
# HELP glm53_serve_start_timestamp_seconds Unix time the unit's main process last started (0: never).
# TYPE glm53_serve_start_timestamp_seconds gauge
glm53_serve_start_timestamp_seconds $start
EOT
)
fi

# --- /health (head) -----------------------------------------------------------------------------------------------
health_lines=""; health_up=0
if [ -n "$GLM_HEALTH_URL" ]; then
  hb=$(mktemp)
  code=$(curl -s -m 5 -o "$hb" -w '%{http_code}' "$GLM_HEALTH_URL" 2>/dev/null)
  code=$(num "$code")
  [ "$code" = 200 ] && health_up=1
  # ok: 1 healthy, 0 "ok": false (the broken latch), -1 no JSON body. The numbers are written only when present.
  fields=$(python3 - "$hb" <<'PY' 2>/dev/null
import json, sys
try:
    h = json.load(open(sys.argv[1]))
except Exception:
    h = None
if not isinstance(h, dict):
    print("ok -1")
    sys.exit(0)
print("ok %d" % (0 if h.get("ok") is False else 1))

# Export every scalar /health field, not a whitelist. Extended 2026-11-06: the 2026-11-05 decode
# collapse (engine-wide output fell 88.8 -> 4.11 tok/s for ~6 min) could not be explained afterwards,
# because the only engine numbers recorded were health_ok, iteration_s, kept_bytes, requests_running
# and context_length. The counters that would have localised it (rounds, drafted, accepted, decode
# seconds, pool pressure, prefix hits, spill) are all on /health and were going nowhere. The engine's
# own /metrics does not carry them either, so this file is the only path. Iterating the scalars rather
# than naming them keeps it from going stale when the engine adds a field.
#
# The five original names are preserved exactly, because alerts and dashboards use them:
# iteration_s is still published as iteration_seconds.
RENAME = {"iteration_s": "iteration_seconds"}
for key in sorted(h):
    v = h.get(key)
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        print("%s %s" % (RENAME.get(key, key), v))

# streams is a small dict of lane state: decoding, prefilling, filling, paused, max.
st = h.get("streams")
if isinstance(st, dict):
    for key in sorted(st):
        v = st.get(key)
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            print("streams_%s %s" % (key, v))

# kv_shard.parts is a list, one entry a rank. Publish the count and each part's live rows, because a
# cross-rank gather was the leading untested explanation for the collapse above.
ks = h.get("kv_shard")
if isinstance(ks, dict):
    parts = ks.get("parts")
    if isinstance(parts, list):
        print("kv_shard_parts %d" % len(parts))
        for i, part in enumerate(parts):
            if isinstance(part, dict):
                for key in ("live_rows", "kept_rows", "hold_rows", "free"):
                    v = part.get(key)
                    if isinstance(v, (int, float)) and not isinstance(v, bool):
                        print("kv_shard_part%d_%s %s" % (i, key, v))
    for key in sorted(ks):
        v = ks.get(key)
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            print("kv_shard_%s %s" % (key, v))

# spill: the tier served 2.6% of lookups over seven days, so its counters decide whether raising
# TF_GLM_KEPT_BYTES_GIB helps or the tier is simply not reading.
sp = h.get("spill")
if isinstance(sp, dict):
    for key in sorted(sp):
        v = sp.get(key)
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            print("spill_%s %s" % (key, v))
PY
)
  rm -f "$hb"
  [ -n "$fields" ] || fields="ok -1"
  health_lines=$(cat <<EOT
# HELP glm53_health_code HTTP status of the GLM engine's /health (0: no answer in 5 s).
# TYPE glm53_health_code gauge
glm53_health_code $code
# HELP glm53_health_up 1 if /health answered 200.
# TYPE glm53_health_up gauge
glm53_health_up $health_up
EOT
)
  while read -r k v; do
    case "$k" in
      ok) health_lines+=$'\n# HELP glm53_health_ok /health "ok": 1 healthy, 0 broken (kit default: the engine does not exit), -1 no JSON body.\n# TYPE glm53_health_ok gauge\n'"glm53_health_ok $v" ;;
      *) health_lines+=$'\n'"# HELP glm53_health_$k /health's ${k} (as the engine reports it)."$'\n'"# TYPE glm53_health_$k gauge"$'\n'"glm53_health_$k $v" ;;
    esac
  done <<< "$fields"
fi

# Starting = a planned start that is still loading: the unit is active, systemd has not restarted it on its own, it
# started less than GLM_START_GRACE_S ago and /health does not answer 200 yet. GLMEngineDown waits for it.
starting=0
if [ -n "$GLM_UNIT" ] && [ -n "$GLM_HEALTH_URL" ] && [ "$is_active" = 1 ] && [ "$restarts" = 0 ] &&
   (( start > 0 && NOW - start < GLM_START_GRACE_S )) && [ "$health_up" = 0 ]; then
  starting=1
fi

{
  if [ -n "$GLM_MARKER" ]; then
    active=0; [ -e "$GLM_MARKER" ] && active=1
    echo '# HELP glm53_active 1 while the GLM marker file exists (GLM-5.3 is the active engine).'
    echo '# TYPE glm53_active gauge'
    echo "glm53_active $active"
  fi
  echo "# HELP glm53_rank_running 1 if this node's GLM rank container ($GLM_CONTAINER) runs."
  echo '# TYPE glm53_rank_running gauge'
  echo "glm53_rank_running $rank"
  [ -z "$mg_lines" ] || echo "$mg_lines"
  [ -z "$unit_lines" ] || echo "$unit_lines"
  [ -z "$health_lines" ] || echo "$health_lines"
  if [ -n "$GLM_UNIT" ] && [ -n "$GLM_HEALTH_URL" ]; then
    echo '# HELP glm53_engine_starting 1 while a planned start loads (active, no auto restart, inside the grace, /health not 200).'
    echo '# TYPE glm53_engine_starting gauge'
    echo "glm53_engine_starting $starting"
  fi
  echo '# HELP glm53_scan_timestamp_seconds Unix time of the last glm53-textfile run.'
  echo '# TYPE glm53_scan_timestamp_seconds gauge'
  echo "glm53_scan_timestamp_seconds $NOW"
} > "$tmp"
chmod 644 "$tmp" && mv "$tmp" "$OUT" && trap - EXIT
