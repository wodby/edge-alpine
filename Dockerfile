ARG GO_IMAGE=golang:1.26.11-alpine3.23@sha256:db99415e2625ce0ee03eed09edf7f32ae8c58dc399f28cc602a87fe7238119e4
ARG NGINX_IMAGE=wodby/nginx:1.31-r22@sha256:e824e071d13c216f1cab792923a395c49b16b00ddf837392d7ac18dfa4f1efc8

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS lego-build

ARG LEGO_VERSION=v5.6.0
ARG LEGO_COMMIT=226c09fbe704ea412bea76cb268414f67686be1d
# Space-separated module@version overrides, raised above lego's own requirements
# only while the release scan reports a fixable vulnerability in that module.
ARG LEGO_GO_MODULES=""
ARG TARGETOS
ARG TARGETARCH

RUN set -eux; \
    apk add --no-cache git; \
    git clone --branch "${LEGO_VERSION}" --depth=1 https://github.com/go-acme/lego.git /src; \
    test "$(git -C /src rev-parse HEAD)" = "${LEGO_COMMIT}"

# Edge solves DNS-01 only through the exec provider, so the build links that
# provider alone. The other tags are lego's own dead-code elimination tags.
RUN set -eux; \
    cd /src; \
    if [ -n "${LEGO_GO_MODULES}" ]; then \
        go get ${LEGO_GO_MODULES}; \
        go mod tidy; \
    fi; \
    go mod verify; \
    CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" go build -p 2 -trimpath \
        -tags 'urfave_cli_no_template,grpcnotrace,validator_novalidatefn,ozzo_validation_no_template,lego_dnslight,lego_dns_exec' \
        -ldflags "-X main.version=${LEGO_VERSION}-wodby.1" \
        -o dist/lego .

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS confd-build

# Wodby's confd fork: the etcd v3 backend with maintained dependencies.
ARG CONFD_VERSION=v0.17.0
ARG CONFD_COMMIT=af032dce7c5954bd41c0f8bf221ce67c190f117f
ARG TARGETOS
ARG TARGETARCH

RUN set -eux; \
    apk add --no-cache git; \
    git clone --branch "${CONFD_VERSION}" --depth=1 https://github.com/wodby/confd.git /src; \
    test "$(git -C /src rev-parse HEAD)" = "${CONFD_COMMIT}"

RUN set -eux; \
    cd /src; \
    go mod verify; \
    CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" go build -p 2 -trimpath \
        -ldflags "-s -w -X main.Version=${CONFD_VERSION#v} -X main.GitSHA=${CONFD_COMMIT}" \
        -o /confd .

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS gotpl-build

ARG GOTPL_COMMIT=c204bb00fa34bb99a028a2b345fe4c416184ce8e
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
COPY --from=confd-build /confd /opt/wodby/tools/bin/confd
COPY --from=gotpl-build /gotpl /usr/local/bin/gotpl
COPY rootfs /

EXPOSE 80 443

ENTRYPOINT ["/init"]
CMD []
