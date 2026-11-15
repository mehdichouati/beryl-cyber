#!/bin/sh
# Beryl CYBER : destinations du trafic de chaque appareil.
#
# Source : table de suivi des connexions du noyau (conntrack), qui connaît pour chaque
# connexion l'appareil, l'adresse distante, le port et les octets échangés.
# Les connexions fermées restent visibles environ deux minutes (TIME_WAIT) : une lecture
# par minute voit donc aussi les connexions courtes.
#
# Chaque connexion a un identifiant : on mémorise ses octets d'une minute à l'autre
# (dans /tmp, en RAM) pour n'ajouter que la différence.
# Puis les nouvelles adresses sont enrichies (pays, organisation) depuis la base DB-IP.
#
# Données conservées DEST_RETENTION_DAYS jours (30 par défaut), puis supprimées.

CONF="${CONF:-/mnt/beryl/beryl-cyber/beryl-cyber.conf}"
[ -f "$CONF" ] && . "$CONF"
DATA_DIR="${DATA_DIR:-/mnt/beryl/beryl-cyber/data}"
DB="${DB:-$DATA_DIR/beryl.db}"
RETENTION="${DEST_RETENTION_DAYS:-30}"
STATE="/tmp/beryl-conntrack.state"
NEW_STATE="/tmp/beryl-conntrack.state.new"
CT_INPUT="${CT_INPUT:-}"        # pour les tests : fichier contenant une sortie de conntrack

command -v conntrack >/dev/null 2>&1 || [ -n "$CT_INPUT" ] || exit 0
[ -f "$DB" ] || exit 0

today="$(date +%F)"
now="$(date +%s)"
[ -f "$STATE" ] || : > "$STATE"

ct_list() {
    if [ -n "$CT_INPUT" ]; then cat "$CT_INPUT"; else conntrack -L -f ipv4 -o id 2>/dev/null; fi
}

# Adresses IP -> MAC des appareils connus
sqlite3 -separator ' ' "$DB" "SELECT last_ip, mac FROM devices WHERE last_ip IS NOT NULL;" > /tmp/beryl-ipmac.$$ 2>/dev/null

# --- 1. Différences d'octets par connexion, agrégées par appareil et destination ---
{
    sed 's/^/STATE /' "$STATE"
    sed 's/^/MAP /' /tmp/beryl-ipmac.$$
    ct_list | sed 's/^/CT /'
} | awk -v day="$today" -v newstate="$NEW_STATE" '
    function private(ip) {
        return ip ~ /^(10\.|192\.168\.|127\.|169\.254\.|0\.)/ || ip ~ /^172\.(1[6-9]|2[0-9]|3[01])\./ \
            || ip ~ /^(22[4-9]|23[0-9]|24[0-9]|25[0-5])\./
    }
    $1 == "STATE" { prev[$2] = $3; next }
    $1 == "MAP"   { mac[$2] = $3; next }
    $1 == "CT" {
        proto = $2; id = ""; n = 0
        delete f
        for (i = 3; i <= NF; i++) {
            if ($i ~ /^id=/) id = substr($i, 4)
            if (split($i, kv, "=") == 2) {
                k = kv[1]
                if (k == "src" || k == "dst" || k == "dport" || k == "bytes") {
                    c[k]++                       # 1re occurrence = sens aller, 2e = retour
                    f[k c[k]] = kv[2]
                }
            }
        }
        delete c
        if (proto != "tcp" && proto != "udp") next
        lan = f["src1"]; remote = f["dst1"]; port = f["dport1"]
        if (!(lan in mac) || private(remote) || id == "") next
        up = f["bytes1"] + 0; down = f["bytes2"] + 0
        total = up + down
        print id, total > newstate
        if (id in prev) {
            d = total - prev[id]
            if (d <= 0) next
            # partage de la différence au prorata envoi/reçu
            dtx = (total > 0) ? int(d * up / total) : 0
            drx = d - dtx; isnew = 0
        } else {
            dtx = up; drx = down; isnew = 1
        }
        key = mac[lan] SUBSEP remote SUBSEP proto SUBSEP port
        RX[key] += drx; TX[key] += dtx; CN[key] += isnew
        seen[remote] = 1
    }
    END {
        print "BEGIN;"
        for (k in RX) {
            split(k, p, SUBSEP)
            printf "INSERT INTO destinations (mac, day, ip, proto, port, rx, tx, conns) VALUES (\x27%s\x27,\x27%s\x27,\x27%s\x27,\x27%s\x27,%d,%d,%d,%d)", p[1], day, p[2], p[3], p[4], RX[k], TX[k], CN[k]
            print " ON CONFLICT (mac, day, ip, proto, port) DO UPDATE SET rx = rx + excluded.rx, tx = tx + excluded.tx, conns = conns + excluded.conns;"
        }
        print "COMMIT;"
    }' | sqlite3 "$DB" 2>/dev/null

[ -f "$NEW_STATE" ] && mv "$NEW_STATE" "$STATE" || : > "$STATE"
rm -f /tmp/beryl-ipmac.$$

# --- 2. Pays et organisation des nouvelles adresses ------------------------------
# Recherche par fusion : adresses triées et plages triées, lues une seule fois.
lookup() {    # lookup FICHIER_PLAGES < liste "entier ip"
    sort -n | awk -v ranges="$1" '
        { want[++n] = $1; ipof[n] = $2 }
        END {
            i = 1
            while ((getline line < ranges) > 0 && i <= n) {
                split(line, r, " ")
                while (i <= n && want[i] < r[1] + 0) i++
                rest = line; sub(/^[^ ]+ [^ ]+ /, "", rest)      # valeur complète (peut contenir des espaces)
                while (i <= n && want[i] <= r[2] + 0) { print ipof[i], rest; i++ }
            }
        }'
}

unknown="$(sqlite3 "$DB" "SELECT DISTINCT d.ip FROM destinations d LEFT JOIN ip_info i ON i.ip = d.ip
                          WHERE i.ip IS NULL AND d.day = '$today' LIMIT 500;" 2>/dev/null)"
if [ -n "$unknown" ] && [ -f "$DATA_DIR/geo-country.txt" ]; then
    echo "$unknown" | awk -F. '{ printf "%.0f %s\n", ((($1 * 256 + $2) * 256 + $3) * 256 + $4), $0 }' > /tmp/beryl-want.$$
    lookup "$DATA_DIR/geo-country.txt" < /tmp/beryl-want.$$ > /tmp/beryl-cc.$$
    if [ -f "$DATA_DIR/geo-asn.txt" ]; then lookup "$DATA_DIR/geo-asn.txt" < /tmp/beryl-want.$$ > /tmp/beryl-asn.$$; else : > /tmp/beryl-asn.$$; fi
    {
        echo "BEGIN;"
        awk -v now="$now" '
            FILENAME ~ /cc/  { cc[$1] = $2; next }
            FILENAME ~ /asn/ { split($2, a, "|"); asn[$1] = a[1] + 0; o = $0; sub(/^[^ ]+ [^|]*\|/, "", o); org[$1] = o; next }
            { ip = $2
              printf "INSERT OR REPLACE INTO ip_info (ip, country, asn, org, updated) VALUES (\x27%s\x27, %s, %s, %s, %d);\n", ip,
                     (ip in cc) ? "\x27" cc[ip] "\x27" : "NULL", (ip in asn) ? asn[ip] : "NULL",
                     (ip in org) ? "\x27" org[ip] "\x27" : "NULL", now }' /tmp/beryl-cc.$$ /tmp/beryl-asn.$$ /tmp/beryl-want.$$
        echo "COMMIT;"
    } | sqlite3 "$DB" 2>/dev/null
    rm -f /tmp/beryl-want.$$ /tmp/beryl-cc.$$ /tmp/beryl-asn.$$
fi

# --- 3. Durée de conservation ------------------------------------------------------
sqlite3 "$DB" "DELETE FROM destinations WHERE day < date('now', 'localtime', '-$RETENTION days');" 2>/dev/null
