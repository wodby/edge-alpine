#!/usr/bin/env bash

# Certificate tests against a local Pebble ACME server, which accepts every
# challenge. They cover:
# - upgrading lego 4 data written by an earlier Edge release, and an earlier
#   release still using the same account after the upgrade;
# - the lego actions Edge runs for Wodby (run, renew, revoke, DNS-01 ensure) and
#   the scheduled renewal of the node certificate.

set -Eeuo pipefail

image="${IMAGE:-wodby/edge-alpine:latest}"
# The last lego 4 release. LEGACY_IMAGE overrides it, e.g. with a local build
# on hosts that cannot run its amd64 image.
legacy_image="${LEGACY_IMAGE:-wodby/edge-alpine:3.0.41@sha256:bc73930ef5bc8caa367fdecba19c793736f74d4915c61239d9b20ef1042ef974}"
pebble_image="ghcr.io/letsencrypt/pebble:2.10.1@sha256:ddf230642b1a584f519f32e347de1b05a6e4c1f6c35c1863b33effeab5f78199"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/edge-alpine-acme.XXXXXX")"
network="edge-alpine-acme-$$"
pebble="${network}-pebble"
container="${network}-edge"

edge_dir=/mnt/containers/edge
node_domain=node-test-node.example.test
account_dir="${edge_dir}/accounts/pebble_14000/hello@wodby.com"
account_url_pattern='https://pebble:14000/my-account/[A-Za-z0-9]+'

cleanup() {
    status=$?
    if [[ "${status}" -ne 0 ]]; then
        docker logs "${container}" 2>/dev/null || true
        docker exec "${container}" cat /tmp/backend-messages 2>/dev/null || true
    fi
    docker rm -f "${container}" "${pebble}" >/dev/null 2>&1 || true
    docker network rm "${network}" >/dev/null 2>&1 || true
    # Containers write the data directory as root.
    docker run --rm -v "${test_root}:/test-root" --entrypoint /bin/sh "${image}" \
        -c 'rm -rf /test-root/edge' >/dev/null 2>&1 || true
    rm -rf "${test_root}"
    exit "${status}"
}
trap cleanup EXIT

fail() {
    echo "acme test failed: $*" >&2
    exit 1
}

edge() {
    docker exec "${container}" "$@"
}

# Runs a command the way Edge's services and cron jobs do: with-contenv and the
# execline tools it uses come from s6's /command, which docker exec leaves out of PATH.
edge_s6() {
    docker exec -e PATH=/command:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        "${container}" /command/with-contenv "$@"
}

trap 'echo "acme test failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

# Pebble's sample configuration also offers a 6-day profile, which it may pick
# for orders that name none; Edge's renewal checks assume 90-day certificates.
cat >"${test_root}/pebble-config.json" <<'JSON'
{
  "pebble": {
    "listenAddress": "0.0.0.0:14000",
    "managementListenAddress": "0.0.0.0:15000",
    "certificate": "test/certs/localhost/cert.pem",
    "privateKey": "test/certs/localhost/key.pem",
    "httpPort": 5002,
    "tlsPort": 5001,
    "ocspResponderURL": "",
    "externalAccountBindingRequired": false,
    "retryAfter": {"authz": 3, "order": 5},
    "keyAlgorithm": "ecdsa",
    "profiles": {
      "default": {"description": "90-day certificates", "validityPeriod": 7776000}
    }
  }
}
JSON

docker network create "${network}" >/dev/null
docker run -d \
    --name "${pebble}" \
    --network "${network}" \
    --network-alias pebble \
    -e PEBBLE_VA_ALWAYS_VALID=1 \
    -e PEBBLE_VA_NOSLEEP=1 \
    -e PEBBLE_WFE_NONCEREJECT=0 \
    -v "${test_root}/pebble-config.json:/test/config/pebble-config.json:ro" \
    "${pebble_image}" >/dev/null
docker cp "${pebble}:/test/certs/pebble.minica.pem" "${test_root}/pebble-ca.pem" >/dev/null
for _ in $(seq 1 30); do
    docker logs "${pebble}" 2>&1 | grep -q 'Listening on' && break
    sleep 1
done

mkdir -p "${test_root}/edge"
# Skip the slow DH parameter generation; Edge only reuses the file.
docker run --rm --entrypoint /usr/bin/openssl -v "${test_root}/edge:/edge" "${image}" \
    dhparam -dsaparam -out /edge/dhparam.pem 2048 >/dev/null 2>&1

acme_args=(
    --network "${network}"
    -e LEGO_SERVER=https://pebble:14000/dir
    -e LEGO_CA_CERTIFICATES=/pebble-ca.pem
    -v "${test_root}/pebble-ca.pem:/pebble-ca.pem:ro"
    -v "${test_root}/edge:${edge_dir}"
)

# 1. lego 4 data, written the way Edge 3.0.41 writes the node certificate.
docker run --rm "${acme_args[@]}" --entrypoint /opt/wodby/bin/lego "${legacy_image}" \
    -a --email=hello@wodby.com --domains="${node_domain}" \
    --http --http.webroot="${edge_dir}" --path="${edge_dir}" run
legacy_account="$(docker run --rm "${acme_args[@]}" --entrypoint /bin/cat "${image}" \
    "${account_dir}/account.json" | grep -oE "${account_url_pattern}")"
[[ -n "${legacy_account}" ]] || fail "lego 4 did not register an account"

# 2. Edge starts on that data and migrates it before anything runs lego.
docker run -d \
    --name "${container}" \
    "${acme_args[@]}" \
    --add-host wodby-svc.wodby:127.0.0.1 \
    --add-host etcd.wodby:127.0.0.1 \
    -e WODBY_BASE_DOMAIN=example.test \
    -e WODBY_NODE_UUID=test-node \
    -v "${repo_root}/tests/confd:/opt/wodby/tools/bin/confd:ro" \
    -v "${repo_root}/tests/http-server:/usr/local/bin/test-http-server:ro" \
    "${image}" >/dev/null

for _ in $(seq 1 30); do
    edge pidof nginx >/dev/null 2>&1 && break
    sleep 1
done
docker logs "${container}" 2>&1 | grep -F 'edge: lego storage migrated' >/dev/null \
    || fail "the lego 4 data was not migrated"
edge test -f "${account_dir}/hello@wodby.com.key"
edge test -f "${account_dir}/keys/hello@wodby.com.key"
edge cmp "${account_dir}/hello@wodby.com.key" "${account_dir}/keys/hello@wodby.com.key"
edge /bin/sh -c "ls ${edge_dir}/lego4-backup-*.tar >/dev/null"
edge /bin/sh -c "/bin/busybox tar -tf ${edge_dir}/lego4-backup-*.tar | grep -qx 'accounts/pebble_14000/hello@wodby.com/keys/hello@wodby.com.key'"
[[ "$(edge cat "${account_dir}/account.json" | grep -oE "${account_url_pattern}")" == "${legacy_account}" ]] \
    || fail "the migrated account does not keep its registration"

# A second start finds nothing left to migrate.
docker restart "${container}" >/dev/null
for _ in $(seq 1 30); do
    edge pidof nginx >/dev/null 2>&1 && break
    sleep 1
done
[[ "$(docker logs "${container}" 2>&1 | grep -c 'edge: migrating')" == 1 ]] \
    || fail "the lego storage was migrated twice"
[[ "$(edge /bin/sh -c "ls ${edge_dir}/lego4-backup-*.tar | wc -l")" -eq 1 ]]

# Stand-ins for the Wodby Agent (answers and logs) and etcd (key removal).
edge /bin/sh -c ': > /tmp/backend-messages'
docker exec -d "${container}" /bin/sh -c \
    'while :; do /bin/busybox nc -l -p 8125 >>/tmp/backend-messages; echo >>/tmp/backend-messages; done'
docker exec -d "${container}" /bin/sh -c \
    'while :; do /bin/busybox nc -l -p 2379 -e /usr/local/bin/test-http-server; done'
sleep 1

# Runs the lego action Wodby requests through etcd, then checks the answer.
lego_action() {
    local settings="$1" expected="$2" answer
    edge /bin/sh -c "printf '%s\n' ${settings} > /etc/wodby/lego"
    edge /bin/sh -c ': > /tmp/backend-messages'
    if ! edge_s6 /opt/bin/lego; then
        [[ "${expected}" == error ]] || fail "lego action failed: ${settings}"
    fi
    answer="$(edge grep -F '"type":"response"' /tmp/backend-messages | tail -n 1)"
    EXPECTED="${expected}" python3 -c '
import json, os, sys
answer = json.loads(sys.argv[1])
if os.environ["EXPECTED"] == "ok":
    assert "result" in answer and "error" not in answer, answer
else:
    assert "error" in answer, answer
' "${answer}" || fail "unexpected answer for ${settings}: ${answer}"
}

serial() {
    edge openssl x509 -noout -serial -in "${edge_dir}/certificates/$1.crt"
}

# 3. The scheduled renewal leaves a certificate that is not due alone.
node_serial="$(serial "${node_domain}")"
edge_s6 /opt/bin/default_cert_renew
[[ "$(serial "${node_domain}")" == "${node_serial}" ]] || fail "a certificate that is not due was renewed"

# 4. HTTP-01: run issues a certificate for the account the upgrade kept.
lego_action "action=run email=hello@wodby.com domains=app.example.test,www.app.example.test challenge=http" ok
edge openssl x509 -noout -ext subjectAltName -in "${edge_dir}/certificates/app.example.test.crt" \
    | grep -F 'DNS:www.app.example.test' >/dev/null
[[ "$(edge cat "${account_dir}/account.json" | grep -oE "${account_url_pattern}")" == "${legacy_account}" ]] \
    || fail "lego registered a new account"
app_serial="$(serial app.example.test)"

# run always issues a new certificate, as it did with lego 4.
lego_action "action=run email=hello@wodby.com domains=app.example.test,www.app.example.test challenge=http" ok
[[ "$(serial app.example.test)" != "${app_serial}" ]] || fail "run did not issue a new certificate"
app_serial="$(serial app.example.test)"

# renew leaves a certificate that is not due alone. The account check in the
# script looks for the Let's Encrypt server directory.
edge ln -s pebble_14000 "${edge_dir}/accounts/acme-v02.api.letsencrypt.org"
lego_action "action=renew email=hello@wodby.com domains=app.example.test,www.app.example.test challenge=http" ok
[[ "$(serial app.example.test)" == "${app_serial}" ]] || fail "renew replaced a certificate that is not due"
edge rm "${edge_dir}/accounts/acme-v02.api.letsencrypt.org"

# revoke revokes the certificate and archives its files.
lego_action "action=revoke email=hello@wodby.com domains=app.example.test,www.app.example.test challenge=http" ok
edge test ! -f "${edge_dir}/certificates/app.example.test.crt"
edge /bin/sh -c "ls ${edge_dir}/archives/certificates/ | grep -q app.example.test"

# An unsupported action is reported as an error.
lego_action "action=unknown email=hello@wodby.com domains=app.example.test challenge=http" error

# 5. DNS-01: lego hands the challenge record to the Wodby callback. The test
# stops once the callback is called, since nothing serves the record.
docker exec -d "${container}" /bin/sh -c \
    'while :; do /bin/busybox nc -l -p 18081 -e /usr/local/bin/test-http-server; done'
edge rm -f /tmp/test-http-body
edge /bin/sh -c "printf '%s\n' action=ensure email=hello@wodby.com domain=dns.example.test challenge=dns \
    dns_callback_url=http://127.0.0.1:18081 dns_callback_token=test-token > /etc/wodby/lego"
docker exec -d -e PATH=/command:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    "${container}" /command/with-contenv /opt/bin/lego
callback=""
for _ in $(seq 1 60); do
    # The etcd stand-in writes the same file, so wait for the callback's body.
    callback="$(edge cat /tmp/test-http-body 2>/dev/null || true)"
    [[ "${callback}" == *'"fqdn"'* ]] && break
    sleep 1
done
edge pkill -f '/opt/wodby/bin/lego run' || true
python3 -c '
import json, re, sys
body = json.loads(sys.argv[1])
assert body["token"] == "test-token", body
assert body["action"] == "present", body
assert body["fqdn"] == "_acme-challenge.dns.example.test.", body
assert re.fullmatch(r"[A-Za-z0-9_-]{43}", body["value"]), body
' "${callback}" || fail "unexpected DNS callback: ${callback}"

# 6. An earlier Edge release still renews with the migrated account.
docker rm -f "${container}" >/dev/null
docker run --rm "${acme_args[@]}" --entrypoint /opt/wodby/bin/lego "${legacy_image}" \
    -a --email=hello@wodby.com --domains="${node_domain}" \
    --http --http.webroot="${edge_dir}" --path="${edge_dir}" renew --days=100 --no-random-sleep
[[ "$(docker run --rm "${acme_args[@]}" --entrypoint /bin/cat "${image}" "${account_dir}/account.json" \
    | grep -oE "${account_url_pattern}")" == "${legacy_account}" ]] \
    || fail "the earlier release registered a new account"

echo "acme tests passed"
