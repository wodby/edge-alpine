#!/usr/bin/env bash

set -euo pipefail

image="${IMAGE:-wodby/edge-alpine:latest}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/edge-alpine-test.XXXXXX")"
container="edge-alpine-test-$$"

cleanup() {
    status=$?
    if [[ "${status}" -ne 0 ]]; then
        docker logs "${container}" 2>/dev/null || true
    fi
    docker rm -f "${container}" >/dev/null 2>&1 || true
    rm -rf "${test_root}"
    exit "${status}"
}
trap cleanup EXIT

mkdir -p "${test_root}/edge/certificates"

# Keep the runtime test quick while still exercising the persisted-DH-parameter path.
docker run --rm \
    --entrypoint /usr/bin/openssl \
    -v "${test_root}/edge:/edge" \
    "${image}" \
    dhparam -dsaparam -out /edge/dhparam.pem 2048 >/dev/null 2>&1

if docker run --rm \
    -e WODBY_BASE_DOMAIN=example.test \
    -e WODBY_NODE_UUID=test-node \
    -v "${test_root}/edge:/mnt/containers/edge" \
    "${image}" >/dev/null 2>&1; then
    echo "edge container started without the required confd mount" >&2
    exit 1
fi

docker run -d \
    --name "${container}" \
    -e WODBY_BASE_DOMAIN=example.test \
    -e WODBY_NODE_UUID=test-node \
    -p 127.0.0.1::80 \
    -p 127.0.0.1::443 \
    -v "${repo_root}/tests/confd:/opt/wodby/tools/bin/confd:ro" \
    -v "${repo_root}/tests/http-server:/usr/local/bin/test-http-server:ro" \
    -v "${test_root}/edge:/mnt/containers/edge" \
    "${image}" >/dev/null

http_port="$(docker port "${container}" 80/tcp | sed -E 's/.*:([0-9]+)$/\1/' | head -n 1)"
https_port="$(docker port "${container}" 443/tcp | sed -E 's/.*:([0-9]+)$/\1/' | head -n 1)"

http_status=""
for _ in $(seq 1 30); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "${container}")" != "true" ]]; then
        echo "edge container stopped during startup" >&2
        exit 1
    fi

    http_status="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${http_port}/" || true)"
    [[ "${http_status}" == "503" ]] && break
    sleep 1
done

[[ "${http_status}" == "503" ]]
[[ "$(curl -ksS -o /dev/null -w '%{http_code}' "https://127.0.0.1:${https_port}/")" == "503" ]]

docker exec "${container}" /usr/sbin/nginx -t
docker exec "${container}" /usr/sbin/nginx -v 2>&1 | grep -F 'nginx/1.31.3'
docker exec "${container}" /opt/wodby/bin/lego --version | grep -F 'v4.35.2-wodby.1'
docker exec "${container}" /bin/sh -c 'test "$(cat /proc/1/comm)" = s6-svscan'
docker exec "${container}" /bin/sh -c 'pidof nginx >/dev/null && pidof crond >/dev/null'
docker exec "${container}" /bin/sh -c "ps | grep -q '[c]onfd -watch'"
docker exec "${container}" /bin/sh -c '! apk info -e curl && ! apk info -e libcurl && ! apk info -e tar && ! apk info -e wget && ! apk info -e unzip'

docker exec -d "${container}" /bin/busybox nc -l -p 18080 -e /usr/local/bin/test-http-server
sleep 1
docker exec "${container}" /bin/sh -c '. /etc/wodby/functions; printf '\''value=test-payload'\'' >/tmp/test-http-payload; http_request PUT http://127.0.0.1:18080/v2/keys/test /tmp/test-http-payload'
docker exec "${container}" /bin/sh -c 'test "$(cat /tmp/test-http-request)" = "PUT /v2/keys/test HTTP/1.1"'
docker exec "${container}" /bin/sh -c 'test "$(cat /tmp/test-http-body)" = "value=test-payload"'
