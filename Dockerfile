ARG GO_IMAGE=golang:1.26.5-alpine3.23@sha256:622e56dbc11a8cfe87cafa2331e9a201877271cbff918af53d3be315f3da88cc
ARG NGINX_IMAGE=wodby/nginx:1.31-5.48.5@sha256:a64c5eb7736a0c5ab6af75ae1b454c6b6b093d99b5878250f3fa671dce43d947

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS lego-build

ARG LEGO_VERSION=v4.35.2
ARG LEGO_COMMIT=537f2ed0b7946b30bcfa81c5256e7c99ba6286bb
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
    go mod tidy; \
    go mod verify; \
    CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" go build -p 2 -trimpath \
        -ldflags "-X main.version=${LEGO_VERSION}-wodby.1" \
        -o dist/lego ./cmd/lego/

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

COPY --from=lego-build /src/dist/lego /opt/wodby/bin/lego
COPY rootfs /

EXPOSE 80 443

ENTRYPOINT ["/init"]
CMD []
