# PoC: contract-mediated service locality, proven hostless via nimi (OCI)

An app and a database are wired together by a `databaseConnection` contract. The
consumer (`appModule`) is authored **once** and is byte-identical whether the db
is:

- **co-located** -- the app's own child sub-service, running as a peer process
  under a single nimi PID-1 in **one** OCI image; or
- **distributed** -- a separate top-level service shipped in its **own** OCI
  image, reached across the container boundary at its DNS name.

The consumer never names a provider, a locality, or a host. The only
locality-dependent inputs are the set partition (which services share an image)
and the host argument to the provider -- neither of which the consumer encodes.

This proves the locality-agnostic contract boundary **directly, with no NixOS
host anywhere**: contract resolution happens in `lib.services.evalServices`
(peer-to-peer, host-agnostic), and nimi is just another lowering target for the
resolved service tree -- alongside `lib.services.toNixosServices` (systemd) and
`lib.services.toKubernetesManifests` (k8s manifests).

## How it works

nimi consumes the modular-services engine from the nixpkgs it is built against.
`nix/lib.nix`'s `resolveNimiServicesModule` (a pre-pass in `evalNimiModule`):

1. **resolves contracts** across the declared `services` set via `evalServices`,
   so each service reads its baked `contracts.<type>.results` (an app `want` is
   satisfied by a peer or a lifted child provider, with no containing host); and
2. **flattens** `services.<parent>.services.<child>` into dotted top-level
   entries (`parent.child`), so the single nimi PID-1 co-runs the whole tree as
   flat peers -- the same way a Kubernetes Pod lowers a logical group into a flat
   `spec.containers[]` list.

`resolveAndFlattenServices { services; select ? null; }` is the reusable seam:
resolution always spans the full `services` set, while `select` restricts which
slice a given image ships. That is how the distributed case partitions a single
shared resolution across two images (mirroring the in-tree cross-node
modular-service pattern, where one `evalServices` feeds multiple separately
deployed targets).

The pre-pass is guarded: on a nixpkgs without `evalServices`, it is the identity
(nimi's original behavior), so existing consumers on stock nixpkgs are
unaffected.

## Build

```sh
nix build .#app-with-db-image   # co-located: one image, app + app.db under one PID-1
nix build .#app-image .#db-image  # distributed: two images
```

## Eval-only checks (no runtime)

```sh
# The invariant: both connStrings differ ONLY by host (loopback vs db container).
nix build .#checks.x86_64-linux.locality-invariant && cat result
#   co-located:  postgresql://127.0.0.1:5432/appdb
#   distributed: postgresql://db:5432/appdb

# Inspect the baked argv / partitions.
nix eval --json .#debug.distributedAppArgv     # names db:5432, not loopback
nix eval --json .#debug.appServices --apply builtins.attrNames  # ["app"]
nix eval --json .#debug.dbServices  --apply builtins.attrNames  # ["db"]
```

## Runtime verification (podman)

Load and run the images (rootful podman used here; the DB DNS name is provided
via `--add-host` because this host is not configured for rootful-podman DNS --
the contract binding, not the DNS transport, is what is under test):

**Co-located** -- one container, one nimi PID-1 co-running `app` + `app.db` on
loopback; the app reaches the db and writes `/run/app/connected`:

```sh
skopeo copy nix:$(nix build --no-link --print-out-paths .#app-with-db-image) \
  containers-storage:app-with-db:latest    # or: .#app-with-db-image.copyToPodman
podman run -d --name colo app-with-db:latest
podman exec colo cat /run/app/connstring    # postgresql://127.0.0.1:5432/appdb
podman exec colo test -f /run/app/connected && echo connected
```

**Distributed** -- two containers on one network; the app reaches the db by the
name the contract baked (`db:5432`), across the container boundary:

```sh
# load app-image + db-image, then:
podman network create sl-net
podman run -d --name db --network sl-net db:latest
DBIP=$(podman inspect db --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
podman run -d --name app --network sl-net --add-host db:$DBIP app:latest
podman exec app cat /run/app/connstring     # postgresql://db:5432/appdb
podman exec app test -f /run/app/connected && echo "reached db across boundary"
```

## Inputs

Both engine and lowering live on published branches, so this flake is fully
reproducible with no local paths:

- `nixpkgs` -> `github:kiaragrouwstra/nixpkgs/child-service-locality` -- the
  modular-services contract engine (`evalServices`, `resolveContracts`,
  child-lift), not yet upstream in NixOS/nixpkgs.
- `nimi` -> `github:kiaragrouwstra/nimi/service-locality` -- nimi with the
  `resolveAndFlattenServices` pre-pass (`nix/lib.nix`) that makes it a lowering
  target for modular services. Once that lands in `weyl-ai/nimi` this input can
  point at upstream.

## Requirements

- Nix with flakes enabled. The flake pins both inputs by revision, so no local
  checkout of nixpkgs or nimi is needed.
- For runtime verification: podman (+ crun, conmon). Not required for the
  build/eval proofs.
