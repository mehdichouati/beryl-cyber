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

# MAC demandée (destinations) : validée par expression régulière avant usage
mac=$(echo "$QUERY_STRING" | sed -n 's/^.*mac=\([0-9a-fA-F:%A]*\).*$/\1/p' | sed 's/%3[Aa]/:/g' | tr 'A-F' 'a-f')
echo "$mac" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || mac=""

# Code pays demandé (carte) : deux lettres majuscules, sinon ignoré
cc=$(echo "$QUERY_STRING" | sed -n 's/^.*cc=\([A-Za-z][A-Za-z]\).*$/\1/p' | tr 'a-z' 'A-Z')

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
              (SELECT COALESCE(SUM(blocked), 0) FROM dns_queries WHERE day = date('now','localtime')) AS dns_blocked,
              (SELECT COALESCE(SUM(count), 0)   FROM dns_queries WHERE day = date('now','localtime')) AS dns_total,
              strftime('%s','now')                                 AS now,
              $WL                                                  AS whitelist;")"
        ;;
    devices)
        reply "$(query_json "
            SELECT d.mac, d.hostname, d.alias, d.vendor, d.random_mac, d.last_ip,
                   d.status, d.online, d.first_seen, d.last_seen, d.private,
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
    daily)
        reply "$(query_json "
            SELECT day, SUM(rx) AS rx, SUM(tx) AS tx
            FROM traffic
            WHERE day >= date('now','localtime','-29 days')
            GROUP BY day ORDER BY day;")"
        ;;
    bydevice)
        reply "$(query_json "
            SELECT COALESCE(d.alias, d.hostname, d.mac) AS name, SUM(t.rx) AS rx, SUM(t.tx) AS tx
            FROM traffic t JOIN devices d ON d.mac = t.mac
            WHERE t.day >= date('now','localtime','start of month')
            GROUP BY t.mac ORDER BY SUM(t.rx + t.tx) DESC LIMIT 8;")"
        ;;
    orgs)
        reply "$(query_json "
            SELECT COALESCE(i.org, 'Inconnue') AS org, SUM(d.rx + d.tx) AS total
            FROM destinations d LEFT JOIN ip_info i ON i.ip = d.ip
            WHERE d.day = date('now','localtime')
            GROUP BY COALESCE(i.org, 'Inconnue') ORDER BY total DESC LIMIT 10;")"
        ;;
    countries)
        reply "$(query_json "
            SELECT i.country AS cc, SUM(d.rx + d.tx) AS total, SUM(d.conns) AS conns,
                   COUNT(DISTINCT d.ip) AS ips
            FROM destinations d JOIN ip_info i ON i.ip = d.ip
            WHERE d.day = date('now','localtime') AND i.country IS NOT NULL
            GROUP BY i.country ORDER BY total DESC;")"
        ;;
    dns)
        [ -n "$mac" ] || { reply '{"error":"MAC invalide"}'; exit 0; }
        reply "$(query_json "
            SELECT domain, SUM(count) AS count, SUM(blocked) AS blocked
            FROM dns_queries
            WHERE mac = '$mac' AND day = date('now','localtime')
            GROUP BY domain ORDER BY SUM(count) DESC LIMIT 40;")"
        ;;
    country)
        [ -n "$cc" ] || { reply '{"error":"pays invalide"}'; exit 0; }
        reply "$(query_json "
            SELECT COALESCE(v.alias, v.hostname, v.mac) AS device,
                   COALESCE(n.domain, i.org, d.ip) AS site,
                   i.org AS org,
                   SUM(d.rx) AS rx, SUM(d.tx) AS tx, SUM(d.conns) AS conns
            FROM destinations d
            JOIN ip_info i ON i.ip = d.ip
            JOIN devices v ON v.mac = d.mac
            LEFT JOIN dns_ip n ON n.mac = d.mac AND n.ip = d.ip
            WHERE d.day = date('now','localtime') AND i.country = '$cc'
            GROUP BY v.mac, COALESCE(n.domain, i.org, d.ip)
            ORDER BY SUM(d.rx + d.tx) DESC
            LIMIT 60;")"
        ;;
    destinations)
        [ -n "$mac" ] || { reply '{"error":"MAC invalide"}'; exit 0; }
        reply "$(query_json "
            SELECT d.ip, d.proto, d.port,
                   SUM(d.rx) AS rx, SUM(d.tx) AS tx, SUM(d.conns) AS conns,
                   i.country, i.org
            FROM destinations d LEFT JOIN ip_info i ON i.ip = d.ip
            WHERE d.mac = '$mac' AND d.day = date('now','localtime')
            GROUP BY d.ip, d.proto, d.port
            ORDER BY (SUM(d.rx) + SUM(d.tx)) DESC
            LIMIT 30;")"
        ;;
    *)
        reply '{"error":"requête inconnue"}'
        ;;
esac
