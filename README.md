# Wodby 1 edge proxy

This image is the Wodby 1 node ingress. It watches the legacy Wodby etcd v2
configuration with the host-provided `confd` binary, manages ACME certificates,
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
- s6-overlay supervises nginx, crond, and the host-provided legacy `confd`.
  Edge retains the etcd v2 key API on port 4001.
- lego stays on the v4 CLI/storage contract so existing Wodby 1 certificate
  data does not need a destructive v5 migration. The v4.35.2 source is rebuilt
  as `v4.35.2-wodby.1` with Go 1.26.5 and patched `x/crypto`, `x/net`, and gRPC
  dependencies.

The pinned versions and digests live at the top of `Dockerfile`. Update those
pins together and run the build, runtime tests, and an image vulnerability scan
before releasing a new tag.

## Runtime contract

The Wodby 1 deployment must provide:

- `WODBY_NODE_UUID` and, when different from `wodby.cloud`,
  `WODBY_BASE_DOMAIN`;
- persistent edge data at `/mnt/containers/edge`;
- etcd v2 reachable through `WODBY_ETCD_HOST` (default `etcd.wodby`) and
  `WODBY_ETCD_PORT` (default `4001`);
- the existing `confd` executable mounted at `/opt/wodby/tools/bin/confd`;
- optional backups at `/usr/share/nginx/html/backups`.

This maintenance branch releases Edge 2.x for Infrastructure 6. Edge 3.x uses
etcd v3 and is released from `master`. Do not replace a legacy etcd store or
host-mounted tools as part of an Edge image update.

Readiness uses `/opt/bin/edge-ready`: both nginx and the watcher must be
running, etcd must be healthy, and nginx must have accepted a configuration
rendered by the watcher. Before the first route exists, the default fallback
configuration is allowed. Use this command as the Kubernetes exec readiness probe; a TCP probe
alone also accepts the fallback error page. The image health check uses the same
command.

## Build and test

```sh
make
make test
```

The runtime tests exercise the legacy etcd API and host-provided `confd`,
validate nginx and lego, and check default HTTP and HTTPS responses. They also
boot the actual watcher against etcd on another container IP, verify existing
and newly added routes, exercise endpoint overrides, and reject readiness when
the watcher or etcd is unavailable.
