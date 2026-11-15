#!/bin/sh
# Beryl CYBER : base de géolocalisation des adresses IPv4 (pays + organisation).
#
# Source : bases gratuites "IP to Country Lite" et "IP to ASN Lite" de DB-IP
# (https://db-ip.com, licence CC BY 4.0), mises à jour chaque mois.
# Converties en plages d'entiers triées, pour une recherche rapide en un seul passage :
#   geo-country.txt : debut fin CODE_PAYS
#   geo-asn.txt     : debut fin ASN|Organisation

CONF="${CONF:-/mnt/beryl/beryl-cyber/beryl-cyber.conf}"
[ -f "$CONF" ] && . "$CONF"
DATA_DIR="${DATA_DIR:-/mnt/beryl/beryl-cyber/data}"
BASE_URL="https://download.db-ip.com/free"
TMP="/tmp/beryl-geo.$$"

command -v curl >/dev/null 2>&1 || { echo "curl introuvable"; exit 1; }
mkdir -p "$DATA_DIR"

# Télécharge la base du mois, ou celle du mois précédent si elle n'est pas encore publiée
fetch() {
    kind="$1"
    for month in "$(date +%Y-%m)" "$(date -d "@$(( $(date +%s) - 2678400 ))" +%Y-%m 2>/dev/null)"; do
        [ -n "$month" ] || continue
        if curl -fsSL -m 120 -o "$TMP.gz" "$BASE_URL/dbip-$kind-lite-$month.csv.gz" && gunzip -t "$TMP.gz" 2>/dev/null; then
            gunzip -c "$TMP.gz"
            rm -f "$TMP.gz"
            return 0
        fi
    done
    rm -f "$TMP.gz"
    return 1
}

# IPv4 uniquement. Ligne CSV : debut,fin,valeur[,organisation avec virgules éventuelles]
convert='
    function ip2n(s,   a) { split(s, a, "."); return ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4] }
    $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
        if (mode == "country") { print ip2n($1), ip2n($2), $3; next }
        org = $4; for (i = 5; i <= NF; i++) org = org "," $i
        gsub(/"/, "", org); gsub(/[\047\\|;<>`$]/, "", org)
        print ip2n($1), ip2n($2), $3 "|" substr(org, 1, 60)
    }'

ok=1
for kind in country asn; do
    if fetch "$kind" | awk -F ',' -v mode="$kind" "$convert" > "$DATA_DIR/geo-$kind.txt.new" \
       && [ "$(wc -l < "$DATA_DIR/geo-$kind.txt.new")" -gt 10000 ]; then
        mv "$DATA_DIR/geo-$kind.txt.new" "$DATA_DIR/geo-$kind.txt"
        echo "    base $kind : $(wc -l < "$DATA_DIR/geo-$kind.txt") plages"
    else
        rm -f "$DATA_DIR/geo-$kind.txt.new"
        echo "    base $kind : téléchargement impossible"
        ok=0
    fi
done
[ "$ok" = 1 ]
