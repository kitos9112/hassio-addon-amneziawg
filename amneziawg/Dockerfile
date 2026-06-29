# shellcheck disable=SC2154
ARG BUILD_FROM=ghcr.io/hassio-addons/base:19.0.0

# ---------------------------------------------------------------------------
# Build stage: compile the userspace AmneziaWG implementation + tools.
# Uses a dedicated Go image so the add-on base image's Go version (if any)
# can never break the compile. Produces static-ish binaries copied below.
# ---------------------------------------------------------------------------
FROM golang:1.26-alpine AS build

ARG AWG_GO_REF=v0.2.19
ARG AWG_TOOLS_REF=v1.0.20260618-2

RUN apk add --no-cache git make build-base linux-headers bash

WORKDIR /src

# amneziawg-go: userspace WireGuard fork (TUN + CAP_NET_ADMIN, no kernel module)
RUN git clone --depth 1 --branch "${AWG_GO_REF}" \
        https://github.com/amnezia-vpn/amneziawg-go.git \
    && make -C amneziawg-go \
    && install -Dm755 amneziawg-go/amneziawg-go /out/usr/bin/amneziawg-go

# amneziawg-tools: provides `awg` (C) and `awg-quick` (shell)
RUN git clone --depth 1 --branch "${AWG_TOOLS_REF}" \
        https://github.com/amnezia-vpn/amneziawg-tools.git \
    && make -C amneziawg-tools/src \
    && make -C amneziawg-tools/src install DESTDIR=/out \
        WITH_BASHCOMPLETION=no WITH_SYSTEMDUNITS=no WITH_WGQUICK=yes

# ---------------------------------------------------------------------------
# Final stage: the Home Assistant add-on image.
# ---------------------------------------------------------------------------
FROM ${BUILD_FROM}

# Runtime dependencies only (no toolchain).
# hadolint ignore=DL3018
RUN apk add --no-cache \
        bash \
        iptables \
        ip6tables \
        iproute2 \
        libqrencode-tools \
        openresolv \
        jq

# Userspace AmneziaWG binaries from the build stage.
COPY --from=build /out/usr/bin/amneziawg-go /usr/bin/amneziawg-go
COPY --from=build /out/usr/bin/awg /usr/bin/awg
COPY --from=build /out/usr/bin/awg-quick /usr/bin/awg-quick

# Add-on rootfs (s6 service scripts + libraries).
COPY rootfs /

RUN chmod +x /etc/services.d/amneziawg/run \
             /etc/services.d/amneziawg/finish

# awg-quick uses the userspace implementation; run as root inside the container.
ENV WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go \
    WG_SUDO=0

# Build metadata
ARG BUILD_ARCH
ARG BUILD_VERSION
LABEL \
    io.hass.name="AmneziaWG Server" \
    io.hass.type="addon" \
    io.hass.arch="${BUILD_ARCH}" \
    io.hass.version="${BUILD_VERSION}"
