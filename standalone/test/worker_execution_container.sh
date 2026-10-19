#!/bin/sh
set -eu

core_image=${1:?usage: worker_execution_container.sh CORE_IMAGE HTTP_IMAGE WORKER_IMAGE}
http_image=${2:?usage: worker_execution_container.sh CORE_IMAGE HTTP_IMAGE WORKER_IMAGE}
worker_image=${3:?usage: worker_execution_container.sh CORE_IMAGE HTTP_IMAGE WORKER_IMAGE}
suffix=$$
container="tay-worker-execution-$suffix"
data_volume="tay-worker-execution-data-$suffix"
socket_volume="tay-worker-execution-socket-$suffix"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm "$data_volume" "$socket_volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

wait_healthy() {
  attempt=0
  until test "$(docker inspect --format '{{.State.Health.Status}}' "$container")" = healthy; do
    attempt=$((attempt + 1))
    if test "$attempt" -ge 60; then
      docker logs "$container" >&2
      exit 1
    fi
    sleep 1
  done
}

assert_ready() {
  docker exec "$container" bin/tay_standalone rpc '
    case Tay.status() do
      %{state: :ready, active_jobs: 0, running_executions: 0, unsettled_executions: 0} -> :ok
      status -> raise "unexpected Tay status: #{inspect(status)}"
    end
  ' >/dev/null
}

docker volume create "$data_volume" >/dev/null
docker volume create "$socket_volume" >/dev/null
docker run -d --name "$container" \
  -e TAY_DATA_DIR=/var/lib/tay/store \
  -e TAY_INITIALIZE_IF_MISSING=true \
  -v "$data_volume:/var/lib/tay" \
  -v "$socket_volume:/run/tay" \
  "$core_image" >/dev/null
wait_healthy
docker run --rm \
  -v "$socket_volume:/run/tay" \
  "$worker_image" python /app/volatile_execution.py socket /run/tay/tay.sock
assert_ready

docker rm -f "$container" >/dev/null
docker volume rm "$data_volume" "$socket_volume" >/dev/null
docker volume create "$data_volume" >/dev/null
docker run -d --name "$container" \
  -e TAY_DATA_DIR=/var/lib/tay/store \
  -e TAY_INITIALIZE_IF_MISSING=true \
  -e TAY_SOCKET_PATH=off \
  -e TAY_HTTP_PORT=8080 \
  -v "$data_volume:/var/lib/tay" \
  "$http_image" >/dev/null
wait_healthy
docker run --rm --network "container:$container" \
  "$worker_image" python /app/volatile_execution.py http http://127.0.0.1:8080
assert_ready
