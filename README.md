# Wodby 1 edge proxy

This image is the Wodby 1 node ingress. It watches the Wodby etcd v3
configuration with its bundled `confd` binary, manages ACME certificates,
and proxies ports 80 and 443 to application containers.

## Image architecture

- Nginx and its modules come from the maintained
  [`wodby/nginx`](https://github.com/wodby/nginx) image. This repository no
  longer compiles nginx or upgrades an obsolete Alpine filesystem in place.
- The final image refreshes packages from the pinned Alpine release during the
  build and removes inherited build/runtime tools that edge does not use.
- s6-overlay supervises nginx, crond, and a pinned `confd` build restricted to
  its etcd v3 backend. Edge connects directly to etcd on port 2379.
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
