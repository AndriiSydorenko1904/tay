#!/bin/sh
set -eu

image=${1:?usage: http_release_contents.sh IMAGE}

docker run --rm --entrypoint /bin/sh "$image" -c '
  set -eu
  test -d /opt/tay/lib/tay-*
  test -d /opt/tay/lib/tay_http-*
  test -d /opt/tay/lib/bandit-*
  test ! -d /opt/tay/lib/tay_dashboard-*
  test ! -d /opt/tay/lib/phoenix-*
  test ! -d /opt/tay/lib/phoenix_live_view-*
  test ! -d /opt/tay/lib/phoenix_pubsub-*
'
