#!/bin/sh
set -eu

image=${1:?usage: http_only_container_smoke.sh IMAGE}
suffix=$$
data_volume="tay-http-only-data-$suffix"
container="tay-http-only-$suffix"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm "$data_volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker volume create "$data_volume" >/dev/null
docker run -d --name "$container" \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m,uid=10001,gid=10001,mode=0700 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  -e TAY_DATA_DIR=/var/lib/tay/store \
  -e TAY_INITIALIZE_IF_MISSING=true \
  -e TAY_SOCKET_PATH=off \
  -e TAY_HTTP_PORT=8080 \
  -v "$data_volume:/var/lib/tay" \
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

docker exec "$container" /bin/sh -c 'test ! -e /run/tay/tay.sock'
test "$(docker inspect --format '{{.Config.User}}' "$container")" = "10001:10001"
