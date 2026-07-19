# Shared contract-graph modules for the service-locality PoC.
#
# Ported verbatim (in intent) from nixpkgs
# `nixos/tests/contracts/child-service-locality.nix`, with ONE change: the
# provider host is a PARAMETER rather than a hardcoded `127.0.0.1`. That single
# argument is the only locality-dependent input; the CONSUMER never encodes it.
#
# A consumer service (`app`) expresses a NEED for a database via the
# `databaseConnection` contract. It never names a provider, a locality, or even
# that a "db service" exists -- it owns a `want` and reads the resolved
# `connectionString`. The provider derives its endpoint from its own portable
# `process.ports` metadata plus the host parameter.
#
# The whole point: `appModule` is byte-identical across both localities. Only
# the PROVIDER BINDING (child vs peer) and the host argument to `dbProvider`
# differ -- neither of which the consumer encodes.
{ lib }:
let
  inherit (lib) mkOption types;

  # Default host at which a provider is reachable. Co-located providers keep this
  # (loopback under one PID-1); distributed providers override `db.host` to their
  # container/DNS name. Either way the CONSUMER never encodes it.
  defaultHost = "127.0.0.1";

  sqlPort = 5432;

  # --- databaseConnection contract (as in chaining.nix, inline) ---
  # request { dbName } -> result { connectionString }
  dbContract =
    { lib, ... }:
    {
      config.contractDefinitions.databaseConnection = {
        meta = {
          description = ''
            Contract for database connections where a consumer requests a named
            database and a provider returns a connection string.
          '';
          maintainers = [ ];
        };
        interface = {
          request.dbName = mkOption {
            description = "Name of the database to connect to.";
            type = types.str;
          };
          result.connectionString = mkOption {
            description = "Connection string for the database.";
            type = types.str;
          };
        };
      };
    };

  # --- CONSUMER: written ONCE, used unchanged by both setups ---
  # Owns a `want` and reads the resolved `connectionString` into its runtime
  # config, then connects to the derived endpoint. It never owns a db, never
  # names locality, and never names a provider.
  appModule =
    { lib, config, ... }:
    {
      _class = "service";
      imports = [ dbContract ];
      options.app.db = mkOption {
        description = "Database connection for the app.";
        default.result = config.contracts.databaseConnection.results.db;
        type = config.contractDefinitions.databaseConnection.mkContract {
          request.dbName.default = "appdb";
        };
      };
      config =
        let
          connstring = config.app.db.result.connectionString;
          # Parse host/port out of `postgresql://<host>:<port>/<db>` at eval time
          # (locality-agnostic: identical logic in both setups).
          hostport = lib.head (lib.splitString "/" (lib.removePrefix "postgresql://" connstring));
          host = lib.head (lib.splitString ":" hostport);
          port = lib.last (lib.splitString ":" hostport);
        in
        {
          contracts.databaseConnection.want = { inherit (config.app) db; };
          # The resolved connection string flows into the service's runtime state;
          # the app then connects to the derived endpoint to prove reachability.
          # busybox `nc -z` returns 0 once the port accepts a connection.
          process.argv = [
            "/bin/sh"
            "-c"
            ''
              mkdir -p /run/app
              echo -n ${lib.escapeShellArg connstring} > /run/app/connstring
              until nc -z ${lib.escapeShellArg host} ${lib.escapeShellArg port}; do sleep 1; done
              touch /run/app/connected
              exec sleep infinity
            ''
          ];
        };
    };

  # --- PROVIDER: databaseConnection provider ---
  # Declares `process.ports.sql.port = 5432` and builds its `connectionString`
  # result FROM that port metadata (not a hardcoded literal) plus its own
  # reachable host. The host is declarative PROVIDER CONFIGURATION (`db.host`,
  # defaulting to loopback), not a curried argument: co-located leaves the
  # default, distributed sets `db.host` to the container name. The provider
  # module is identical in both setups; only `db.host` and WHERE it is bound
  # (child vs peer) differ.
  dbProvider =
    { lib, config, options, ... }:
    {
      _class = "service";
      imports = [ dbContract ];
      # Where this provider is reachable. Deployment configuration with a
      # loopback default; the consumer never reads or sets it.
      options.db.host = mkOption {
        description = "Host at which this database provider is reachable.";
        type = types.str;
        default = defaultHost;
      };
      options.db.databaseConnection = mkOption {
        description = "databaseConnection instances fulfilled by this provider.";
        default = config.contracts.databaseConnection.providerRequests.db;
        type = config.contracts.databaseConnection.mkProviderType {
          fulfill =
            { dbName }:
            {
              connectionString = "postgresql://${config.db.host}:${toString config.process.ports.sql.port}/${dbName}";
            };
        };
      };
      config = {
        process.ports.sql.port = sqlPort;
        # Stand-in for a real database: keep a listener open on the declared SQL
        # port. BusyBox `nc` has no `-k` (keep-alive) and serves a single
        # connection before exiting, so loop it to stay reachable across repeated
        # probes/connections.
        process.argv = [
          "/bin/sh"
          "-c"
          "while true; do nc -l -p ${toString config.process.ports.sql.port} >/dev/null 2>&1 || true; done"
        ];
        contracts.databaseConnection.providers.db.module = options.db.databaseConnection;
        contracts.databaseConnection.defaultProviderName = "db";
      };
    };
in
{
  inherit
    sqlPort
    dbContract
    appModule
    dbProvider
    ;
}
