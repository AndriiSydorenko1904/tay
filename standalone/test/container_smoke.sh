#!/bin/sh
set -eu

image=${1:?usage: container_smoke.sh IMAGE}
worker_image=${2:-}
suffix=$$
data_volume="tay-standalone-data-$suffix"
socket_volume="tay-standalone-socket-$suffix"
container="tay-standalone-$suffix"
worker_container="tay-standalone-worker-$suffix"

cleanup() {
  exit_status=$?
  if test "$exit_status" -ne 0; then
    docker logs "$container" >&2 2>/dev/null || true
    docker logs "$worker_container" >&2 2>/dev/null || true
  fi
  docker rm -f "$worker_container" >/dev/null 2>&1 || true
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm "$data_volume" "$socket_volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker volume create "$data_volume" >/dev/null
docker volume create "$socket_volume" >/dev/null
docker run -d --name "$container" \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m,uid=10001,gid=10001,mode=0700 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  -e TAY_DATA_DIR=/var/lib/tay/store \
  -e TAY_INITIALIZE_IF_MISSING=true \
  -v "$data_volume:/var/lib/tay" \
  -v "$socket_volume:/run/tay" \
  "$image" >/dev/null

attempt=0
until test "$(docker inspect --format '{{.State.Health.Status}}' "$container")" = healthy; do
  attempt=$((attempt + 1))
  if test "$attempt" -ge 60; then
    docker logs "$container" >&2
    exit 1
  fi
  sleep 1
done

test "$(docker inspect --format '{{.Config.User}}' "$container")" = "10001:10001"

docker exec "$container" bin/tay_standalone rpc '
  case {
    Process.whereis(Tay.Dashboard.Standalone.Endpoint),
    Process.whereis(Tay.Dashboard.Standalone.PubSub)
  } do
    {nil, nil} -> :ok
    processes -> raise "dashboard started while disabled: #{inspect(processes)}"
  end
' >/dev/null

job_id=
worker_started=
if test -n "$worker_image"; then
  docker run -d --name "$worker_container" \
    -v "$socket_volume:/run/tay:ro" \
    "$worker_image" >/dev/null

  worker_started=$(docker inspect --format '{{.State.StartedAt}}' "$worker_container")
  job_id=$(docker run --rm \
    -v "$socket_volume:/run/tay:ro" \
    "$worker_image" python /app/smoke_client.py)
  test -n "$job_id"
fi

docker stop --time 30 "$container" >/dev/null
docker rm "$container" >/dev/null
# Keep the worker running to verify reconnect to the replacement listener.
docker run -d --name "$container" \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m,uid=10001,gid=10001,mode=0700 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  -e TAY_DATA_DIR=/var/lib/tay/store \
  -e TAY_INITIALIZE_IF_MISSING=false \
  -v "$data_volume:/var/lib/tay" \
  -v "$socket_volume:/run/tay" \
  "$image" >/dev/null

attempt=0
until test "$(docker inspect --format '{{.State.Health.Status}}' "$container")" = healthy; do
  attempt=$((attempt + 1))
  if test "$attempt" -ge 60; then
    docker logs "$container" >&2
    exit 1
  fi
  sleep 1
done

if test -n "$job_id"; then
  docker run --rm \
    -v "$socket_volume:/run/tay:ro" \
    "$worker_image" python /app/smoke_client.py "$job_id" >/dev/null

  # This must be a new submission: recovered results alone do not prove that
  # the still-running worker reconnected and registered its tasks again.
  docker run --rm \
    -v "$socket_volume:/run/tay:ro" \
    "$worker_image" python /app/smoke_client.py --enqueue "after-restart-$suffix" >/dev/null
  test "$(docker inspect --format '{{.State.StartedAt}}' "$worker_container")" = "$worker_started"
fi
