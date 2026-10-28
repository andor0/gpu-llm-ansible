#!/usr/bin/env bash
# Restart running containers labelled $LABEL whose healthcheck reports "unhealthy"
# (Docker restart policies only react to the process exiting), and export container
# health for the node_exporter textfile collector.
set -euo pipefail

: "${LABEL:=autoheal=true}"
: "${TEXTFILE_DIR:=/var/lib/node_exporter/textfile}"
STATE_DIR=/var/lib/container-autoheal

mkdir -p "$TEXTFILE_DIR" "$STATE_DIR"
metrics=$(mktemp "$TEXTFILE_DIR/.container_health.XXXXXX")
trap 'rm -f "$metrics"' EXIT

cat > "$metrics" <<'HELP'
# HELP container_healthy 1 if the container is running and its healthcheck passes (or is still starting), 0 otherwise.
# TYPE container_healthy gauge
# HELP container_autoheal_restarts_total Restarts of unhealthy containers done by container-autoheal.
# TYPE container_autoheal_restarts_total counter
HELP

# `docker ps` lists running, restarting and paused containers; deliberately stopped ones are skipped
for name in $(docker ps --filter "label=$LABEL" --format '{{.Names}}'); do
  read -r state health < <(docker inspect --format \
    '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name")
  restarts=$(cat "$STATE_DIR/$name.restarts" 2>/dev/null || echo 0)
  healthy=1

  if [ "$state" != running ]; then
    healthy=0
  elif [ "$health" = unhealthy ]; then
    healthy=0
    logger -t container-autoheal "restarting unhealthy container $name"
    if docker restart --time 30 "$name" >/dev/null; then
      restarts=$((restarts + 1))
      echo "$restarts" > "$STATE_DIR/$name.restarts"
    else
      logger -t container-autoheal "failed to restart $name"
    fi
  fi

  echo "container_healthy{name=\"$name\"} $healthy" >> "$metrics"
  echo "container_autoheal_restarts_total{name=\"$name\"} $restarts" >> "$metrics"
done

# node_exporter runs as nobody; rename is atomic, so it never reads a half-written file
chmod 0644 "$metrics"
mv "$metrics" "$TEXTFILE_DIR/container_health.prom"
