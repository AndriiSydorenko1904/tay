#!/bin/sh
set -eu

image=${1:?usage: container_smoke.sh IMAGE}
suffix=$$
data_volume="tay-dashboard-data-$suffix"
socket_volume="tay-dashboard-socket-$suffix"
container="tay-dashboard-$suffix"
secret=smoke-test-secret-key-base-0000000000000000000000000000000000000000

cleanup() {
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
  -e ENABLE_DASHBOARD=true \
  -e TAY_DASHBOARD_SECRET_KEY_BASE="$secret" \
  -p 127.0.0.1::4000 \
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

port=$(docker port "$container" 4000/tcp | sed -n 's/.*://p')
test -n "$port"
html=$(curl --fail --silent "http://127.0.0.1:$port/tay")
printf '%s' "$html" | grep -q "Tay Dashboard"
printf '%s' "$html" | grep -q '/assets/phoenix_live_view.min.js'
curl --fail --silent "http://127.0.0.1:$port/assets/phoenix.min.js" >/dev/null
curl --fail --silent "http://127.0.0.1:$port/assets/phoenix_live_view.min.js" >/dev/null
test "$(docker inspect --format '{{.Config.User}}' "$container")" = "10001:10001"
