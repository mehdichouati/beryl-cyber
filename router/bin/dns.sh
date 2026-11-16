#!/bin/sh
# Beryl CYBER : historique DNS par appareil (V3).
#
# Source : journal des requêtes d'AdGuard Home, écrit sur la clé USB (voir adguard-setup.sh),
# une ligne JSON par requête : heure, appareil (IP), domaine, bloqué ou non.
# Le script lit uniquement les lignes ajoutées depuis son dernier passage (position
# mémorisée en RAM), en tenant compte de la rotation du fichier par AdGuard.
#
# Vie privée :
#   - les appareils marqués "privés" ne sont jamais historisés
#   - le détail est supprimé après DNS_RETENTION_DAYS jours (7 par défaut)

CONF="${CONF:-/mnt/beryl/beryl-cyber/beryl-cyber.conf}"
[ -f "$CONF" ] && . "$CONF"
DATA_DIR="${DATA_DIR:-/mnt/beryl/beryl-cyber/data}"
DB="${DB:-$DATA_DIR/beryl.db}"
QLOG="${QLOG:-$DATA_DIR/adguard/querylog.json}"
RETENTION="${DNS_RETENTION_DAYS:-7}"
STATE="/tmp/beryl-dns.state"          # "inode position"

[ -f "$DB" ] || exit 0

inode() { ls -i "$1" 2>/dev/null | awk '{print $1}'; }
size()  { wc -c < "$1" 2>/dev/null | tr -d ' '; }

[ -f "$STATE" ] && read -r saved_ino saved_pos < "$STATE"
saved_pos="${saved_pos:-0}"

today="$(date +%F)"
now="$(date +%s)"
# Taille du fichier relevée UNE fois : on lit jusqu'à cette position exactement, pour ne
# jamais compter deux fois des lignes écrites pendant la lecture.
pos_after="$(size "$QLOG")"; pos_after="${pos_after:-0}"
ino_after="$(inode "$QLOG")"

# Lignes nouvelles, rotation comprise (AdGuard renomme querylog.json en querylog.json.1)
new_lines() {
    [ -f "$QLOG" ] || return 0
    if [ "$ino_after" = "$saved_ino" ]; then
        [ "$pos_after" -lt "$saved_pos" ] && saved_pos=0               # fichier tronqué
        tail -c +"$((saved_pos + 1))" "$QLOG" | head -c "$((pos_after - saved_pos))"
    else
        if [ -n "$saved_ino" ] && [ "$(inode "$QLOG.1")" = "$saved_ino" ]; then
            tail -c +"$((saved_pos + 1))" "$QLOG.1"                     # fin de l'ancien fichier
        fi
        head -c "$pos_after" "$QLOG"
    fi
}

{
    # Appareils non privés : IP -> MAC
    sqlite3 -separator ' ' "$DB" "SELECT last_ip, mac FROM devices WHERE last_ip IS NOT NULL AND private = 0;" 2>/dev/null | sed 's/^/MAP /'
    new_lines | sed 's/^/Q /'
} | awk -v day="$today" -v now="$now" '
    function field(name,   re, s) {
        re = "\"" name "\":\"[^\"]*\""
        if (!match($0, re)) return ""
        s = substr($0, RSTART, RLENGTH); sub(/^"[^"]*":"/, "", s); sub(/"$/, "", s)
        return s
    }
    $1 == "MAP" { mac[$2] = $3; next }
    $1 == "Q" {
        ip = field("IP"); dom = tolower(field("QH"))
        if (!(ip in mac) || dom == "") next
        gsub(/[^a-z0-9._-]/, "", dom); dom = substr(dom, 1, 253)
        sub(/\.$/, "", dom)
        if (dom == "") next
        d = substr(field("T"), 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) d = day
        k = mac[ip] SUBSEP d SUBSEP dom
        C[k]++
        if ($0 ~ /"IsFiltered":true/) B[k]++
    }
    END {
        n = 0
        for (k in C) {
            if (n++ == 0) print "BEGIN;"
            split(k, p, SUBSEP)
            printf "INSERT INTO dns_queries (mac, day, domain, count, blocked, last_ts) VALUES (\x27%s\x27,\x27%s\x27,\x27%s\x27,%d,%d,%d)", p[1], p[2], p[3], C[k], B[k] + 0, now
            print " ON CONFLICT (mac, day, domain) DO UPDATE SET count = count + excluded.count, blocked = blocked + excluded.blocked, last_ts = excluded.last_ts;"
        }
        if (n > 0) print "COMMIT;"
    }' | sqlite3 "$DB" 2>/dev/null

[ -n "$ino_after" ] && echo "$ino_after $pos_after" > "$STATE"

# Durée de conservation
sqlite3 "$DB" "DELETE FROM dns_queries WHERE day < date('now', 'localtime', '-$RETENTION days');" 2>/dev/null
exit 0
