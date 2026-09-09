ARG GO_IMAGE=golang:1.26.8-alpine3.23@sha256:33ce311e5eecedee48ec1b84419c1306e9fbd71009f0d5c3f2a6904b579c1ecc
ARG NGINX_IMAGE=wodby/nginx:1.31-5.48.12@sha256:8ae7f7ba95bb5b30ac6b6824d00737832dcfc8526857e18f53fa5c7d2e2e6cbc

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS lego-build

ARG LEGO_VERSION=v4.35.2
ARG LEGO_COMMIT=537f2ed0b7946b30bcfa81c5256e7c99ba6286bb
ARG GO_CRYPTO_VERSION=v0.56.0
ARG GO_NET_VERSION=v0.58.0
ARG GO_GRPC_VERSION=v1.83.2
ARG TARGETOS
ARG TARGETARCH

RUN set -eux; \
    apk add --no-cache git; \
    git clone --branch "${LEGO_VERSION}" --depth=1 https://github.com/go-acme/lego.git /src; \
    test "$(git -C /src rev-parse HEAD)" = "${LEGO_COMMIT}"

COPY patches/lego-security.patch /tmp/lego-security.patch

RUN set -eux; \
    cd /src; \
    git apply --unidiff-zero /tmp/lego-security.patch; \
    go get \
        "golang.org/x/crypto@${GO_CRYPTO_VERSION}" \
        "golang.org/x/net@${GO_NET_VERSION}" \
        "google.golang.org/grpc@${GO_GRPC_VERSION}"; \
    go mod tidy; \
    go mod verify; \
    CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" go build -p 2 -trimpath \
        -ldflags "-X main.version=${LEGO_VERSION}-wodby.1" \
        -o dist/lego ./cmd/lego/

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS confd-build

ARG CONFD_COMMIT=919444eb6cf721d198b2bb18581d0f0b3734d107
ARG ETCD_CLIENT_VERSION=v3.6.14
ARG GO_CRYPTO_VERSION=v0.56.0
ARG GO_NET_VERSION=v0.58.0
ARG GO_GRPC_VERSION=v1.83.2
ARG TARGETOS
ARG TARGETARCH

RUN set -eux; \
    apk add --no-cache git; \
    git clone https://github.com/kelseyhightower/confd.git /src; \
    git -C /src checkout "${CONFD_COMMIT}"; \
    test "$(git -C /src rev-parse HEAD)" = "${CONFD_COMMIT}"

COPY build/confd/client.go /src/backends/client.go

RUN set -eux; \
    cd /src; \
    go get "go.etcd.io/etcd/client/v3@${ETCD_CLIENT_VERSION}"; \
    go get \
        "golang.org/x/crypto@${GO_CRYPTO_VERSION}" \
        "golang.org/x/net@${GO_NET_VERSION}" \
        "google.golang.org/grpc@${GO_GRPC_VERSION}"; \
    go mod tidy; \
    go mod verify; \
    CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" go build -mod=mod -p 2 -trimpath \
        -ldflags "-s -w" \
        -o /confd .

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS gotpl-build

ARG GOTPL_COMMIT=bfc4b3b915640f1ef74953d2a30d0d5dd9a16b9f
ARG TARGETOS
ARG TARGETARCH

RUN set -eux; \
    apk add --no-cache git; \
    git clone https://github.com/wodby/gotpl.git /src; \
    git -C /src checkout "${GOTPL_COMMIT}"; \
    test "$(git -C /src rev-parse HEAD)" = "${GOTPL_COMMIT}"

RUN set -eux; \
    cd /src; \
    go mod verify; \
    CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" go build -p 2 -trimpath \
        -ldflags "-s -w" \
        -o /gotpl .

FROM ${NGINX_IMAGE}

ARG S6_OVERLAY_VERSION=3.2.3.2
ARG TARGETARCH

ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_KEEP_ENV=1 \
    S6_LOGGING=0 \
    WODBY_USER=wodby \
    WODBY_GROUP=wodby \
    WODBY_GUID=41532 \
    WODBY_HOME=/srv \
    WODBY_OPT=/opt/wodby \
    WODBY_REPO=/srv/repo \
    WODBY_FILES=/srv/files \
    WODBY_BACKUPS=/srv/backups \
    WODBY_LOGS=/srv/logs \
    WODBY_CONF=/srv/conf \
    WODBY_BUILD=/srv/.build \
    WODBY_DOCROOT=/srv/repo/static \
    WODBY_BIN=/opt/wodby/bin

USER root

RUN set -eux; \
    apk upgrade --no-cache; \
    apk del .tools; \
    apk add --no-cache openssl; \
    apk add --no-cache --virtual .edge-build-deps xz; \
    case "${TARGETARCH:-$(apk --print-arch)}" in \
        amd64|x86_64) s6_arch=x86_64 ;; \
        arm64|aarch64) s6_arch=aarch64 ;; \
        *) echo "Unsupported architecture: ${TARGETARCH:-$(apk --print-arch)}" >&2; exit 1 ;; \
    esac; \
    cd /tmp; \
    for archive in s6-overlay-noarch.tar.xz "s6-overlay-${s6_arch}.tar.xz"; do \
        url="https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/${archive}"; \
        curl -fsSLO "${url}"; \
        curl -fsSLO "${url}.sha256"; \
        sha256sum -c "${archive}.sha256"; \
        tar -C / -Jxpf "${archive}"; \
    done; \
    install -d /etc/wodby /mnt/containers/edge /opt/wodby/bin; \
    apk del .edge-build-deps; \
    apk del 7zip curl gzip tar unzip wget; \
    rm -rf /tmp/* /var/cache/apk/*

# Record a whiteout so layer-aware scanners discard the inherited vulnerable binary.
RUN rm /usr/local/bin/gotpl

COPY --from=lego-build /src/dist/lego /opt/wodby/bin/lego
COPY --from=confd-build /confd /opt/wodby/tools/bin/confd
COPY --from=gotpl-build /gotpl /usr/local/bin/gotpl
COPY rootfs /

EXPOSE 80 443

ENTRYPOINT ["/init"]
CMD []
