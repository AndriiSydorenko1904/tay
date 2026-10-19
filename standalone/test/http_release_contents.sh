#!/bin/sh
set -eu

image=${1:?usage: http_release_contents.sh IMAGE}

docker run --rm --entrypoint /bin/sh "$image" -c '
  set -eu
  test -d /opt/tay/lib/tay_core-*
  test -d /opt/tay/lib/tay_http-*
  test -d /opt/tay/lib/bandit-*
  test -z "$(find /opt/tay/lib -mindepth 1 -maxdepth 1 -type d -name "tay-*" -print -quit)"
  test ! -d /opt/tay/lib/phoenix-*
  test ! -d /opt/tay/lib/phoenix_live_view-*
  test ! -d /opt/tay/lib/phoenix_pubsub-*
'
