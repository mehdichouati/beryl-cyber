#!/bin/sh
# Beryl CYBER : API JSON du tableau de bord (lecture seule)
#
#   /cgi-bin/api.sh?q=summary   compteurs
#   /cgi-bin/api.sh?q=devices   inventaire
#   /cgi-bin/api.sh?q=events    50 derniers événements

CONF="${CONF:-/mnt/beryl/beryl-cyber/beryl-cyber.conf}"
[ -f "$CONF" ] && . "$CONF"
DB="${DB:-/mnt/beryl/beryl-cyber/data/beryl.db}"
case "$WHITELIST_ENABLED" in 1) WL=1 ;; *) WL=0 ;; esac

reply() {
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store\r\n\r\n'
    printf '%s\n' "$1"
}

# Exécute une requête et renvoie le résultat en JSON ([] si vide)
query_json() {
    out=$(printf '.mode json\n%s\n' "$1" | sqlite3 "$DB" 2>/dev/null)
    [ -n "$out" ] && echo "$out" || echo "[]"
}

# Seule la valeur de q est lue, et uniquement parmi une liste fixe : aucune donnée
# de la requête HTTP n'est insérée dans le SQL.
q=$(echo "$QUERY_STRING" | sed -n 's/^.*q=\([a-z]*\).*$/\1/p')

[ -f "$DB" ] || { reply '{"error":"base introuvable"}'; exit 0; }

case "$q" in
    summary)
        reply "$(query_json "
            SELECT
              (SELECT COUNT(*) FROM devices)                       AS total,
              (SELECT COUNT(*) FROM devices WHERE online = 1)      AS online,
              (SELECT COUNT(*) FROM devices WHERE status = 'pending') AS pending,
              (SELECT COUNT(*) FROM events  WHERE seen = 0 AND type = 'new_device') AS alerts,
              strftime('%s','now')                                 AS now,
              $WL                                                  AS whitelist;")"
        ;;
    devices)
        reply "$(query_json "
            SELECT d.mac, d.hostname, d.alias, d.vendor, d.random_mac, d.last_ip,
                   d.status, d.online, d.first_seen, d.last_seen,
                   COALESCE((SELECT rx FROM traffic t WHERE t.mac = d.mac AND t.day = date('now','localtime')), 0) AS rx_today,
                   COALESCE((SELECT tx FROM traffic t WHERE t.mac = d.mac AND t.day = date('now','localtime')), 0) AS tx_today,
                   COALESCE((SELECT SUM(rx + tx) FROM traffic t WHERE t.mac = d.mac
                             AND t.day >= date('now','localtime','start of month')), 0) AS total_month
            FROM devices d
            ORDER BY d.online DESC, d.last_seen DESC;")"
        ;;
    events)
        reply "$(query_json "
            SELECT e.id, e.ts, e.type, e.detail, e.seen, e.mac,
                   COALESCE(d.alias, d.hostname, e.mac) AS name
            FROM events e LEFT JOIN devices d ON d.mac = e.mac
            ORDER BY e.ts DESC, e.id DESC
            LIMIT 50;")"
        ;;
    *)
        reply '{"error":"requête inconnue"}'
        ;;
esac
