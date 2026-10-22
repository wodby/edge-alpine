#!/usr/bin/env bash

set -euo pipefail

image="${IMAGE:-wodby/edge-alpine:latest}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/edge-alpine-test.XXXXXX")"
container="edge-alpine-test-$$"
render_etcd="${container}-render-etcd"
network="${container}-network"
override_container="${container}-override"

cleanup() {
    exit_status=$?
    if [[ "${exit_status}" -ne 0 ]]; then
        docker logs "${container}" || true
        docker logs "${override_container}" || true
    fi
    docker rm -f "${container}" >/dev/null 2>&1 || true
    docker rm -f "${override_container}" >/dev/null 2>&1 || true
    docker rm -f "${render_etcd}" >/dev/null 2>&1 || true
    docker network rm "${network}" >/dev/null 2>&1 || true
    rm -rf "${test_root}"
    exit "${exit_status}"
}
trap cleanup EXIT

mkdir -p "${test_root}/edge/certificates"

# Keep the runtime test quick while still exercising the persisted-DH-parameter path.
docker run --rm \
    --entrypoint /usr/bin/openssl \
    -v "${test_root}/edge:/edge" \
    "${image}" \
    dhparam -dsaparam -out /edge/dhparam.pem 2048 >/dev/null 2>&1

# Exercise the installer-provided binary and the exact legacy etcd release.
confd_url=https://s3.amazonaws.com/wodby-releases/confd/v1.0.0/confd
curl -fsSL "${confd_url}" -o "${test_root}/confd"
printf '%s  %s\n' 2274b7cf4286745ef34179a0fe47a964bf2a258f5bfbd94b106f06f8f208b68f "${test_root}/confd" | shasum -a 256 -c -
chmod +x "${test_root}/confd"
curl -fsSL https://github.com/etcd-io/etcd/releases/download/v2.3.7/etcd-v2.3.7-linux-amd64.tar.gz -o "${test_root}/etcd.tar.gz"
printf '%s  %s\n' ab102d271026a4060c9f85ecad11f454d82b1df7b8e676cc3da69f67eb078729 "${test_root}/etcd.tar.gz" | shasum -a 256 -c -
tar -xzf "${test_root}/etcd.tar.gz" -C "${test_root}" etcd-v2.3.7-linux-amd64/etcd etcd-v2.3.7-linux-amd64/etcdctl
docker network create "${network}" >/dev/null
docker run -d --name "${render_etcd}" \
    --network "${network}" --network-alias etcd.wodby --network-alias custom-etcd \
    --entrypoint /test/etcd \
    -v "${test_root}/etcd-v2.3.7-linux-amd64:/test:ro" \
    "${image}" --data-dir=/tmp/etcd \
    --listen-client-urls=http://0.0.0.0:2379,http://0.0.0.0:4001 \
    --advertise-client-urls=http://etcd.wodby:4001 >/dev/null
for _ in $(seq 1 15); do
    docker exec "${render_etcd}" /test/etcdctl --endpoint http://127.0.0.1:2379 cluster-health >/dev/null 2>&1 && break
    sleep 1
done
docker exec "${render_etcd}" /test/etcdctl --endpoint http://127.0.0.1:2379 set \
    /wodby/services/edge/http/service.dev.example.test \
    '{"proxy_proto":"http","proxy_addr":"127.0.0.1","proxy_port":8080,"ssl":true,"ssl_required":false,"cert_domain":"dev.example.test","maintenance":false,"no_robots":true,"hsts":false}' >/dev/null
docker run --rm --network "container:${render_etcd}" --entrypoint /bin/sh \
    -v "${test_root}/confd:/opt/wodby/tools/bin/confd:ro" \
    -v "${repo_root}/tests/confd-render:/tmp/confd:ro" \
    "${image}" \
    -c '/opt/wodby/tools/bin/confd -onetime -node http://127.0.0.1:2379 -confdir /tmp/confd && grep -F "/mnt/containers/edge/certificates/dev.example.test.crt;" /tmp/nginx.conf'
# Read and write a value containing URL-significant characters through the v2 API.
docker run --rm --network "container:${render_etcd}" --entrypoint /bin/sh "${image}" \
    -ec '. /etc/wodby/functions; etcd=http://127.0.0.1:2379/v2/keys; etcd_put compatibility "a&b=+%"'
docker exec "${render_etcd}" /test/etcdctl --endpoint http://127.0.0.1:2379 get /compatibility | grep -Fx 'a&b=+%'
# The startup and reload tests below use this same real etcd on a separate
# container IP. A watcher accidentally defaulting to localhost cannot pass.
docker exec "${render_etcd}" /test/etcdctl --endpoint http://127.0.0.1:2379 rm \
    /wodby/services/edge/http/service.dev.example.test >/dev/null
set_route() {
    docker exec "${render_etcd}" /test/etcdctl --endpoint http://127.0.0.1:2379 set \
        "/wodby/services/edge/http/$1" \
        "{\"proxy_proto\":\"http\",\"proxy_addr\":\"127.0.0.1\",\"proxy_port\":8080,\"ssl\":false,\"maintenance\":$2}" >/dev/null
}
set_route cold.example.test false

docker run -d \
    --name "${container}" --network "${network}" \
    -e WODBY_BASE_DOMAIN=example.test \
    -e WODBY_NODE_UUID=test-node \
    -p 127.0.0.1::80 \
    -p 127.0.0.1::443 \
    -v "${test_root}/confd:/opt/wodby/tools/bin/confd:ro" \
    -v "${repo_root}/tests/http-server:/usr/local/bin/test-http-server:ro" \
    -v "${repo_root}/tests/http-upstream:/usr/local/bin/test-http-upstream:ro" \
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

wait_ready() {
    for _ in $(seq 1 30); do
        docker exec "$1" /opt/bin/edge-ready >/dev/null 2>&1 && return 0
        sleep 1
    done
    echo "edge watcher did not become ready" >&2
    return 1
}
wait_ready "${container}"

docker exec -d "${container}" /bin/sh -ec \
    'while :; do /bin/busybox nc -l -p 8080 -e /usr/local/bin/test-http-upstream; done'
wait_route() {
    for _ in $(seq 1 20); do
        if [[ "$(curl -sS --max-time 3 -H "Host: $1" "http://127.0.0.1:${http_port}/" || true)" == "edge-route-ok" ]]; then
            return 0
        fi
        sleep 1
    done
    echo "route $1 was not served by the live watcher" >&2
    return 1
}
wait_route cold.example.test
# Existing routes must be backed by a successful render, not just a healthy etcd.
docker exec "${container}" rm /run/edge-confd-ready
if docker exec "${container}" /opt/bin/edge-ready; then
    echo "readiness accepted routes without an accepted configuration" >&2; exit 1
fi
set_route live.example.test false
wait_route live.example.test
wait_ready "${container}"
set_route live.example.test true
for _ in $(seq 1 20); do
    status="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: live.example.test' "http://127.0.0.1:${http_port}/")"
    [[ "${status}" == "503" ]] && break
    sleep 1
done
[[ "${status}" == "503" ]]
set_route live.example.test false
wait_route live.example.test

# A healthy fallback listener must never hide a dead watcher or unavailable etcd.
docker exec "${container}" /command/s6-svc -d /run/service/01-confd
for _ in $(seq 1 10); do
    docker exec "${container}" /bin/sh -c '! pidof confd >/dev/null' && break
    sleep 1
done
if docker exec "${container}" /opt/bin/edge-ready; then
    echo "readiness accepted a stopped watcher" >&2; exit 1
fi
wait_route live.example.test
docker exec "${container}" /command/s6-svc -u /run/service/01-confd
wait_ready "${container}"
docker stop "${render_etcd}" >/dev/null
if docker exec "${container}" /opt/bin/edge-ready; then
    echo "readiness accepted unavailable etcd" >&2; exit 1
fi
docker start "${render_etcd}" >/dev/null
wait_ready "${container}"
set_route recovered.example.test false
wait_route recovered.example.test

# Also boot with no application routes, using an explicit host and non-default port.
docker exec "${render_etcd}" /test/etcdctl --endpoint http://127.0.0.1:2379 rm \
    --recursive /wodby/services/edge/http >/dev/null
docker run -d --name "${override_container}" --network "${network}" \
    -e WODBY_BASE_DOMAIN=example.test -e WODBY_NODE_UUID=test-override \
    -e WODBY_ETCD_HOST=custom-etcd -e WODBY_ETCD_PORT=2379 \
    -v "${test_root}/confd:/opt/wodby/tools/bin/confd:ro" \
    -v "${test_root}/edge:/mnt/containers/edge" "${image}" >/dev/null
wait_ready "${override_container}"
set_route override.example.test false
for _ in $(seq 1 20); do
    docker exec "${override_container}" grep -q 'server_name override.example.test;' /etc/nginx/nginx.conf && break
    sleep 1
done
docker exec "${override_container}" grep -q 'server_name override.example.test;' /etc/nginx/nginx.conf
docker exec "${override_container}" /bin/sh -c "ps | grep -q '[c]onfd .*http://custom-etcd:2379'"
docker rm -f "${override_container}" >/dev/null

docker exec "${container}" /usr/sbin/nginx -t
docker exec "${container}" /usr/sbin/nginx -v
docker exec "${container}" /opt/wodby/bin/lego --version
docker exec "${container}" /bin/sh -c 'test "$(cat /proc/1/comm)" = s6-svscan'
docker exec "${container}" /bin/sh -c 'pidof nginx >/dev/null && pidof crond >/dev/null'
docker exec "${container}" /bin/sh -c 'test -x /command/with-contenv'
docker exec "${container}" grep -F '/command/with-contenv /opt/bin/default_cert_create' /etc/crontabs/root >/dev/null
docker exec "${container}" grep -F '/command/with-contenv /opt/bin/default_cert_renew' /etc/crontabs/root >/dev/null
docker exec "${container}" /bin/sh -c "ps | grep -q '[c]onfd .*watch'"
docker exec "${container}" /bin/sh -c '! apk info -e curl && ! apk info -e libcurl && ! apk info -e tar && ! apk info -e wget && ! apk info -e unzip'
docker exec "${container}" /bin/sh -n /opt/bin/lego-dns-callback
docker exec "${container}" grep -F 'cert_domain' /etc/confd/templates/nginx.conf.tmpl >/dev/null

docker exec -d "${container}" /bin/busybox nc -l -p 18080 -e /usr/local/bin/test-http-server
sleep 1
docker exec "${container}" /bin/sh -c '. /etc/wodby/functions; etcd="http://127.0.0.1:18080/v2/keys"; etcd_put test test-payload'
docker exec "${container}" /bin/sh -c 'test "$(cat /tmp/test-http-request)" = "PUT /v2/keys/test HTTP/1.1"'
docker exec "${container}" /bin/sh -c 'test "$(cat /tmp/test-http-body)" = "value=%74%65%73%74%2D%70%61%79%6C%6F%61%64"'

docker exec -d "${container}" /bin/busybox nc -l -p 18081 -e /usr/local/bin/test-http-server
sleep 1
docker exec \
    -e dns_callback_url=http://127.0.0.1:18081 \
    -e dns_callback_token=test-token \
    "${container}" \
    /opt/bin/lego-dns-callback \
    present _acme-challenge.dev.example.test exampleChallengeValue123
docker exec "${container}" /bin/sh -c 'test "$(cat /tmp/test-http-body)" = "{\"token\":\"test-token\",\"action\":\"present\",\"fqdn\":\"_acme-challenge.dev.example.test\",\"value\":\"exampleChallengeValue123\"}"'
