# Wodby 1 edge proxy

This image is the Wodby 1 node ingress. It watches the Wodby etcd v3
configuration with its bundled `confd` binary, manages ACME certificates,
and proxies ports 80 and 443 to application containers.

## Product versions

Edge Alpine is Wodby software with its own semantic product versions. Use matching
Git and Docker tags such as `wodby/edge-alpine:X.Y.Z` to select a release.
Patch releases contain compatible fixes, minor releases add compatible features,
and major releases introduce incompatible changes.

The previously published `r0` tag remains available. Future releases continue the
existing 3.x version series. See [release tags](https://github.com/wodby/edge-alpine/tags)
for available versions. `latest` follows the default branch.

## Image architecture

- Nginx and its modules come from the maintained
  [`wodby/nginx`](https://github.com/wodby/nginx) image. This repository no
  longer compiles nginx or upgrades an obsolete Alpine filesystem in place.
- The final image refreshes packages from the pinned Alpine release during the
  build and removes inherited build/runtime tools that edge does not use.
- s6-overlay supervises nginx, crond, and `confd`. confd is built from a
  release of [`wodby/confd`](https://github.com/wodby/confd), Wodby's fork of
  the original confd with only its etcd v3 backend and current dependencies.
  Edge connects directly to etcd v3 on port 2379.
- lego is built from a v5 release tag with only its `exec` DNS provider, which
  hands DNS-01 records to Wodby.
- lego 5 stores ACME account keys differently from lego 4. On its first start
  on lego 4 data, Edge archives the lego files to
  `/mnt/containers/edge/lego4-backup-<time>.tar`, runs `lego migrate` once, and
  keeps a copy of each account key where lego 4 expects it, so an earlier Edge
  release still uses the same account. A failed migration is logged and never
  stops nginx.

The pinned versions and digests live at the top of `Dockerfile`.
`LEGO_GO_MODULES` raises Go modules above what lego requires, and only while a
fixable vulnerability needs it. confd's dependencies are updated in
`wodby/confd` itself.

The [images updater](https://github.com/wodby/images) keeps the branch current
every day, but tags a release only when the latest release has a fixable High or
Critical vulnerability that the branch fixes. Each Edge update restarts the
node's ingress, so releases without a security reason are made by hand.

## Runtime contract

The Wodby 1 deployment must provide:

- `WODBY_NODE_UUID` and, when different from `wodby.cloud`,
  `WODBY_BASE_DOMAIN`;
- persistent edge data at `/mnt/containers/edge`;
- etcd v3 reachable through `WODBY_ETCD_HOST` and `WODBY_ETCD_PORT`;
- optional backups at `/usr/share/nginx/html/backups`.

Edge 3.x no longer supports the legacy etcd v2 backend. Existing Infrastructure
6 nodes remain on Edge 2.x.

## Build and test

```sh
make
make test
```

The runtime test starts the image with an isolated edge data directory and a
stub `confd`, validates nginx and lego versions, and checks the default HTTP and
HTTPS responses.

The ACME test uses a local [Pebble](https://github.com/letsencrypt/pebble)
server. It upgrades lego 4 data written by Edge 3.0.41, runs the lego actions
Wodby requests, and checks that 3.0.41 still renews with the migrated account.
On hosts that cannot run the amd64 3.0.41 image, set `LEGACY_IMAGE` to a local
image with that release's lego at `/opt/wodby/bin/lego`.
