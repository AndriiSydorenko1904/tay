# Keep builder and runtime on the same Debian release. Override these pinned
# args together when updating the toolchain.
ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=29.0.3
ARG DEBIAN_VERSION=trixie-20260623-slim
ARG BUILDER_IMAGE=hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}
ARG RUNNER_IMAGE=debian:${DEBIAN_VERSION}

FROM ${BUILDER_IMAGE} AS build-base

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod
WORKDIR /build

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config ./config
COPY apps/tay/mix.exs apps/tay/README.md apps/tay/
COPY apps/tay/mix_helpers apps/tay/mix_helpers
COPY apps/tay_http/mix.exs apps/tay_http/README.md apps/tay_http/
COPY apps/tay_dashboard/mix.exs apps/tay_dashboard/README.md apps/tay_dashboard/
COPY standalone/mix.exs standalone/mix.lock standalone/
COPY standalone/config standalone/config

FROM build-base AS build-core
ENV TAY_STANDALONE_FLAVOR=core
WORKDIR /build/standalone
RUN mix deps.get --only prod --check-locked
WORKDIR /build
COPY apps/tay/lib apps/tay/lib
COPY apps/tay/c_src apps/tay/c_src
COPY standalone/lib/tay/standalone standalone/lib/tay/standalone
WORKDIR /build/standalone
RUN mix compile --warnings-as-errors && mix release tay_standalone

FROM build-base AS build-http
ENV TAY_STANDALONE_FLAVOR=http
WORKDIR /build/standalone
RUN mix deps.get --only prod --check-locked
WORKDIR /build
COPY apps/tay/lib apps/tay/lib
COPY apps/tay/c_src apps/tay/c_src
COPY apps/tay_http/lib apps/tay_http/lib
COPY standalone/lib/tay/standalone standalone/lib/tay/standalone
WORKDIR /build/standalone
RUN mix compile --warnings-as-errors && mix release tay_standalone

FROM build-base AS build-dashboard
ENV TAY_STANDALONE_FLAVOR=dashboard
WORKDIR /build/standalone
RUN mix deps.get --only prod --check-locked
WORKDIR /build
COPY apps/tay/lib apps/tay/lib
COPY apps/tay/c_src apps/tay/c_src
COPY apps/tay_http/lib apps/tay_http/lib
COPY apps/tay_dashboard/lib apps/tay_dashboard/lib
COPY standalone/lib standalone/lib
WORKDIR /build/standalone
RUN mix compile --warnings-as-errors && mix release tay_standalone

FROM ${RUNNER_IMAGE} AS runtime-base

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libsctp1 libstdc++6 libssl3 ncurses-base \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 tay \
    && useradd --system --uid 10001 --gid tay --home-dir /opt/tay --shell /usr/sbin/nologin tay \
    && install -d -o tay -g tay -m 0770 /var/lib/tay /run/tay \
    && install -d -o tay -g tay -m 0700 /tmp/tay

WORKDIR /opt/tay

USER 10001:10001

ENV HOME=/tmp/tay \
    RELEASE_TMP=/tmp/tay \
    ERL_CRASH_DUMP=/tmp/tay/erl_crash.dump \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    ELIXIR_ERL_OPTIONS=+fnu \
    TAY_DATA_DIR=/var/lib/tay \
    TAY_SOCKET_PATH=/run/tay/tay.sock \
    TAY_INITIALIZE_IF_MISSING=false \
    TAY_TERMINAL_RETENTION=24h \
    TAY_ENABLE_DASHBOARD=false \
    TAY_DASHBOARD_HOST=localhost \
    TAY_DASHBOARD_PORT=4000

VOLUME ["/var/lib/tay"]
EXPOSE 4000 8080

# `rpc` is the OTP release command for checking the running BEAM node, not gRPC.
# Recovery has a bounded 15-minute default deadline. Do not mark a large but
# valid Store unhealthy while it is still inside that startup contract.
HEALTHCHECK --interval=5s --timeout=3s --start-period=15m --retries=12 \
  CMD ["bin/tay_standalone", "rpc", "Tay.Standalone.Health.check!()"]

ENTRYPOINT ["/opt/tay/bin/tay_standalone"]
CMD ["start"]

FROM runtime-base AS tay
COPY --from=build-core --chown=tay:tay /build/standalone/_build/prod/rel/tay_standalone ./

FROM runtime-base AS tay_http
COPY --from=build-http --chown=tay:tay /build/standalone/_build/prod/rel/tay_standalone ./

FROM runtime-base AS tay_dashboard
COPY --from=build-dashboard --chown=tay:tay /build/standalone/_build/prod/rel/tay_standalone ./

FROM tay_dashboard AS runtime
