{
  description = "PoC: contract-mediated service locality, proven hostless via nimi (OCI)";

  inputs = {
    # nixpkgs carrying the modular-services engine commits (evalServices /
    # resolveContracts / child-lift), which are not yet upstream. The nimi input
    # follows it, so those commits are threaded straight into nimi's eval.
    nixpkgs.url = "github:kiaragrouwstra/nixpkgs/child-service-locality";
    # nimi with the resolve+flatten pre-pass that makes it a lowering target for
    # modular services (branch `service-locality`). Once that lands in
    # weyl-ai/nimi this can point at upstream instead.
    nimi.url = "github:kiaragrouwstra/nimi/service-locality";
    nimi.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nimi,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system}.appendOverlays [ nimi.overlays.default ];
      lib = nixpkgs.lib;
      nimiLib = pkgs.nimi.passthru;

      graph = import ./modules.nix { inherit lib; };
      inherit (graph) appModule dbProvider;

      # The service `process.argv` reference `/bin/sh` and `nc` (busybox); nimi's
      # image is otherwise just the PID-1 entrypoint, so we copy busybox to the
      # image root. `buildEnv` places its `bin/` (sh, nc, sleep, mkdir, ...) at
      # the image's `/bin`.
      containerRoot = pkgs.buildEnv {
        name = "service-locality-root";
        paths = [ pkgs.busybox ];
      };

      # === Co-located: db is the app's OWN CHILD, one image, one PID-1. ==========
      # child-lift resolves the contract within the set; the flattener in
      # modules/nimi.nix lowers `services.app.services.db` to a top-level `app.db`
      # runtime entry so nimi PID-1 co-runs both `app` and `app.db` on loopback.
      colocatedModule = {
        services.app = {
          imports = [ appModule ];
          # Provider keeps its default `db.host` (loopback): app + app.db share
          # one PID-1, so the endpoint is 127.0.0.1.
          services.db = dbProvider;
        };
        settings.container.name = "app-with-db";
        settings.container.copyToRoot = containerRoot;
        # Sidecar-readiness analog: nimi has no explicit dependency ordering, so the
        # app's `until nc -z` gate + always-restart keeps it retrying until the db
        # listener is up.
        settings.restart.mode = "always";
      };

      # === Distributed: ONE shared eval, partitioned into two images. ===========
      # The db is a top-level PEER of the app, reachable across the container
      # boundary at a DNS name (`db`) rather than loopback. We resolve the whole
      # `{ app; db }` graph ONCE -- so the app's `want` (dbName = "appdb") flows
      # to the provider and the connString is built as `postgresql://db:5432/appdb`
      # -- then PARTITION the resolved services: the `app` slice ships in one
      # image, the `db` slice in another. This is the in-tree cross-node
      # modular-service pattern: a single `evalServices` feeding several
      # separately-deployed targets. The consumer (`appModule`) is byte-identical
      # to the co-located case; only the peer host (`db` vs loopback) and the set
      # partition differ, and the consumer encodes neither.
      dbDns = "db";
      distributedGraph = {
        app = appModule;
        # Distributed provider overrides its default host to the container name;
        # `db.host` is normal module config, not a curried argument.
        db = {
          imports = [ dbProvider ];
          db.host = dbDns;
        };
      };

      # Resolve once per top-level service, selecting that service's slice. One
      # image per top-level key: resolution spans the full graph every time, and
      # `select` only restricts which slice each image ships. Deriving the
      # partitions by `mapAttrs` over the graph keeps them in lockstep with
      # `distributedGraph` -- no hand-maintained `[ "app" ]` / `[ "db" ]` literals.
      partitions = lib.mapAttrs (
        name: _:
        nimiLib.resolveAndFlattenServices {
          services = distributedGraph;
          select = [ name ];
        }
      ) distributedGraph;
      appServices = partitions.app;
      dbServices = partitions.db;

      # === The invariant ========================================================
      # `appModule` is the SAME value in both localities (this one `let` binding
      # is imported by `colocatedModule` and `distributedGraph` alike -- there is
      # no per-locality consumer variant). The only locality-dependent inputs are
      # the set partition and the host argument to `dbProvider`, and the consumer
      # encodes neither: the co-located connString is loopback, the distributed
      # one names the db container, but both request the same database on the same
      # port derived from the provider's `process.ports` metadata.
      colocatedConn =
        (nimiLib.resolveAndFlattenServices {
          services.app = {
            imports = [ appModule ];
            services.db = dbProvider;
          };
        }).app.process.argv;
      distributedConn = appServices.app.process.argv;
      # Extract the `postgresql://.../appdb` value baked into each argv script.
      connOf = argv: lib.head (lib.filter (lib.hasInfix "connstring") (lib.splitString "\n" (lib.elemAt argv 2)));
    in
    {
      # Exposed for the eval-only sanity gate: confirm the distributed app slice's
      # baked connString names the db CONTAINER (`db:5432`), not loopback, before
      # building any image.
      debug = {
        colocatedResolved = nimiLib.evalNimiModule colocatedModule;
        appServices = appServices;
        dbServices = dbServices;
        distributedAppArgv = appServices.app.process.argv;
        colocatedConnLine = connOf colocatedConn;
        distributedConnLine = connOf distributedConn;
      };

      checks.${system} = {
        # Eval-only invariant gate: the consumer abstracts locality. The two
        # connStrings differ ONLY by host (loopback vs the db container name);
        # everything else -- database `appdb`, port `5432` (from the provider's
        # port metadata), scheme -- is identical, because the SAME `appModule`
        # produced both.
        locality-invariant =
          let
            colo = connOf colocatedConn; # ...postgresql://127.0.0.1:5432/appdb...
            dist = connOf distributedConn; # ...postgresql://db:5432/appdb...
            ok =
              (lib.hasInfix "postgresql://127.0.0.1:5432/appdb" colo)
              && (lib.hasInfix "postgresql://${dbDns}:5432/appdb" dist)
              # The db name + port are identical across localities.
              && (lib.hasInfix "5432/appdb" colo && lib.hasInfix "5432/appdb" dist);
          in
          assert lib.assertMsg ok ''
            locality invariant failed:
              co-located:  ${colo}
              distributed: ${dist}
          '';
          pkgs.runCommandLocal "locality-invariant-ok" { } ''
            printf 'co-located:  %s\ndistributed: %s\n' ${lib.escapeShellArg colo} ${lib.escapeShellArg dist} > "$out"
          '';
      };

      packages.${system} = {
        app-with-db-image = nimiLib.mkContainerImage colocatedModule;
        app-image = nimiLib.mkContainerImage {
          services = appServices;
          settings.container.name = "app";
          settings.container.copyToRoot = containerRoot;
          settings.restart.mode = "always";
        };
        db-image = nimiLib.mkContainerImage {
          services = dbServices;
          settings.container.name = "db";
          settings.container.copyToRoot = containerRoot;
          settings.restart.mode = "always";
        };
      };
    };
}
