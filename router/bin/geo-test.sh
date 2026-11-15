#!/bin/sh
# Beryl CYBER : diagnostic de la géolocalisation.
#   sh geo-test.sh IP [IP...]
# Affiche le pays et l'organisation de chaque adresse, tels que trouvés dans geo.db.

DATA_DIR="${DATA_DIR:-/mnt/beryl/beryl-cyber/data}"
GEO_DB="$DATA_DIR/geo.db"
[ $# -gt 0 ] || { echo "usage : sh geo-test.sh IP [IP...]"; exit 1; }
[ -f "$GEO_DB" ] || { echo "geo.db absente : lancer update-geoip.sh"; exit 1; }

for ip in "$@"; do
    n="$(echo "$ip" | awk -F. 'NF == 4 { printf "%.0f", ((($1 * 256 + $2) * 256 + $3) * 256 + $4) }')"
    [ -n "$n" ] || { echo "$ip : adresse invalide"; continue; }
    sqlite3 -separator ' | ' "$GEO_DB" "
        SELECT '$ip',
          (SELECT cc  FROM country WHERE start = (SELECT MAX(start) FROM country WHERE start <= $n) AND end >= $n),
          (SELECT asn FROM asn     WHERE start = (SELECT MAX(start) FROM asn     WHERE start <= $n) AND end >= $n),
          (SELECT org FROM asn     WHERE start = (SELECT MAX(start) FROM asn     WHERE start <= $n) AND end >= $n);"
done
