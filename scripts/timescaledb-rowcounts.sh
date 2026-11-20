#!/usr/bin/env bash
# timescaledb-rowcounts.sh <target> <db> — exact row count of every user table, for parity diffs.
#
#   <target>  k8s:<namespace>/<pod>   (connects as postgres over 127.0.0.1 inside the pod)
#             docker:<container>       (connects as postgres over the local socket;
#                                       as wealth for docker:pwm-postgres-1)
#
# Prints "schema.table<TAB>count", byte-sorted, for every base table outside pg_catalog,
# information_schema and the _timescaledb* schemas. A hypertable's count includes its chunks.
# The sort happens here, not in SQL, so glibc and musl servers produce comparable output.
#
# One-time migration tooling. Spec: docs/superpowers/specs/2026-11-18-shared-timescaledb-design.md

set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 k8s:<namespace>/<pod>|docker:<container> <db>" >&2; exit 2; }
target=$1
db=$2

SQL="SELECT table_schema || '.' || table_name,
       (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text
FROM information_schema.tables
WHERE table_type = 'BASE TABLE'
  AND table_schema NOT IN ('pg_catalog', 'information_schema')
  AND table_schema NOT LIKE '\_timescaledb%';"

TAB="$(printf '\t')"

case "$target" in
  k8s:*/*)
    ns=${target#k8s:}; ns=${ns%%/*}
    pod=${target#k8s:*/}
    # Bitnami keeps the superuser password in a file and swaps local trust for md5;
    # the timescaledb pod has it in POSTGRES_PASSWORD.
    printf '%s\n' "$SQL" | kubectl -n "$ns" exec -i "$pod" -- sh -c '
      PGPASSWORD=$(cat /opt/bitnami/postgresql/secrets/postgres-password 2>/dev/null || printf %s "${POSTGRES_POSTGRES_PASSWORD:-${POSTGRES_PASSWORD:-}}")
      export PGPASSWORD
      psql -X -q -At -F "$2" -v ON_ERROR_STOP=1 -h 127.0.0.1 -U postgres -d "$1"' _ "$db" "$TAB" \
      | LC_ALL=C sort
    ;;
  docker:*)
    container=${target#docker:}
    user=postgres
    [[ "$container" == "pwm-postgres-1" ]] && user=wealth
    printf '%s\n' "$SQL" | docker exec -i "$container" \
      psql -X -q -At -F "$TAB" -v ON_ERROR_STOP=1 -U "$user" -d "$db" \
      | LC_ALL=C sort
    ;;
  *)
    echo "unknown target '$target' (want k8s:<namespace>/<pod> or docker:<container>)" >&2
    exit 2
    ;;
esac
