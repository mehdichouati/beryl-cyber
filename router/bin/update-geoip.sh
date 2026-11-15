#!/bin/sh
# Beryl CYBER : base de géolocalisation des adresses IPv4 (pays + organisation).
#
# Source : bases gratuites "IP to Country Lite" et "IP to ASN Lite" de DB-IP
# (https://db-ip.com, licence CC BY 4.0), mises à jour chaque mois.
#
# Les plages sont converties en entiers et chargées dans une base SQLite dédiée
# (geo.db), indexée sur le début de plage. La recherche se fait ensuite en SQL :
# SQLite compare les entiers de façon fiable, contrairement à awk (BusyBox), dont les
# limites (notation scientifique, comparaisons texte) faussaient les résultats.

CONF="${CONF:-/mnt/beryl/beryl-cyber/beryl-cyber.conf}"
[ -f "$CONF" ] && . "$CONF"
DATA_DIR="${DATA_DIR:-/mnt/beryl/beryl-cyber/data}"
BASE_URL="https://download.db-ip.com/free"
TMP="/tmp/beryl-geo.$$"
GEO_DB="$DATA_DIR/geo.db"

command -v curl >/dev/null 2>&1 || { echo "curl introuvable"; exit 1; }
mkdir -p "$DATA_DIR"

# Télécharge la base du mois, ou celle du mois précédent si elle n'est pas encore publiée
fetch() {
    kind="$1"
    for month in "$(date +%Y-%m)" "$(date -d "@$(( $(date +%s) - 2678400 ))" +%Y-%m 2>/dev/null)"; do
        [ -n "$month" ] || continue
        if curl -fsSL -m 180 -o "$TMP.gz" "$BASE_URL/dbip-$kind-lite-$month.csv.gz" && gunzip -t "$TMP.gz" 2>/dev/null; then
            gunzip -c "$TMP.gz"
            rm -f "$TMP.gz"
            return 0
        fi
    done
    rm -f "$TMP.gz"
    return 1
}

# IPv4 uniquement. CSV : debut,fin,valeur[,organisation avec virgules éventuelles]
# Sortie séparée par des tabulations, pour l'import SQLite.
# printf "%.0f" : sans lui, awk (BusyBox) peut écrire les grands nombres en notation scientifique.
convert='
    function ip2n(s,   a) { split(s, a, "."); return ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4] }
    $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
        if (mode == "country") { printf "%.0f\t%.0f\t%s\n", ip2n($1), ip2n($2), $3; next }
        org = $4; for (i = 5; i <= NF; i++) org = org "," $i
        gsub(/"/, "", org); gsub(/[\t\047\\|;<>`$]/, "", org)
        printf "%.0f\t%.0f\t%s\t%s\n", ip2n($1), ip2n($2), $3, substr(org, 1, 60)
    }'

for kind in country asn; do
    if ! fetch "$kind" | awk -F ',' -v mode="$kind" "$convert" > "$TMP.$kind.tsv" \
       || [ "$(wc -l < "$TMP.$kind.tsv")" -lt 10000 ]; then
        echo "    base $kind : téléchargement impossible"
        rm -f "$TMP".*.tsv
        exit 1
    fi
done

# Nouvelle base construite à côté, puis remplacée d'un coup (jamais de base à moitié remplie)
rm -f "$GEO_DB.new"
sqlite3 "$GEO_DB.new" <<SQL
CREATE TABLE country (start INTEGER PRIMARY KEY, end INTEGER NOT NULL, cc TEXT);
CREATE TABLE asn     (start INTEGER PRIMARY KEY, end INTEGER NOT NULL, asn INTEGER, org TEXT);
.separator "\t"
.import $TMP.country.tsv country
.import $TMP.asn.tsv asn
SQL
rm -f "$TMP".*.tsv

c="$(sqlite3 "$GEO_DB.new" "SELECT COUNT(*) FROM country;" 2>/dev/null)"
a="$(sqlite3 "$GEO_DB.new" "SELECT COUNT(*) FROM asn;" 2>/dev/null)"
if [ "${c:-0}" -lt 10000 ] || [ "${a:-0}" -lt 10000 ]; then
    echo "    import SQLite incomplet (pays : $c, organisations : $a)"
    rm -f "$GEO_DB.new"
    exit 1
fi
mv "$GEO_DB.new" "$GEO_DB"
rm -f "$DATA_DIR"/geo-country.txt "$DATA_DIR"/geo-asn.txt     # anciens fichiers texte
echo "    géolocalisation : $c plages pays, $a plages organisations"
