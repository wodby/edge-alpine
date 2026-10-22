ARG GO_IMAGE=golang:1.26.10-alpine3.23@sha256:107301490755aa2ea1b0b43788b6e62cff2faae45a538028b193becc06aaffba
ARG NGINX_IMAGE=wodby/nginx:1.31-r13@sha256:fdc6aa4fdac1dfc0f331b8ecaae7000b6f5936fd8d1ffa07e3c52550ec0d54ce

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS lego-build

ARG LEGO_VERSION=v4.35.2
ARG LEGO_COMMIT=537f2ed0b7946b30bcfa81c5256e7c99ba6286bb
ARG GO_CRYPTO_VERSION=v0.58.0
ARG GO_NET_VERSION=v0.61.0
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

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS gotpl-build

ARG GOTPL_COMMIT=0e0ac258502ca3ac01fa5b4d0cfa12d42ce0da5e
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
    # Edge does not use the dynamic image filter; drop its image decoding libraries.
    apk add --no-cache --virtual .edge-dependency-tools pax-utils; \
    rm /usr/lib/nginx/modules/ngx_http_image_filter_module.so \
        /usr/share/nginx/modules/ngx_http_image_filter_module.so; \
    run_deps="$(scanelf --needed --nobanner --format '%n#p' \
        /usr/sbin/nginx /usr/lib/nginx/modules/*.so \
        | tr ',' '\n' | sort -u | sed 's/^/so:/')"; \
    apk add --no-cache --virtual .edge-nginx-rundeps $run_deps; \
    apk del .nginx-rundeps .edge-dependency-tools; \
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
COPY --from=gotpl-build /gotpl /usr/local/bin/gotpl
COPY rootfs /

EXPOSE 80 443

ENTRYPOINT ["/init"]
CMD []
