#!/bin/sh
# Beryl CYBER : collecte des appareils connectés au réseau LAN du Beryl.
#
# Sources :
#   - table de voisinage ARP (ip neigh) : qui est joignable en ce moment
#   - baux DHCP (/tmp/dhcp.leases)     : nom annoncé par chaque appareil
#
# Usage :
#   collect.sh          une seule collecte
#   collect.sh --loop   collecte en boucle (utilisé par le service)

CONF="${CONF:-/mnt/beryl/beryl-cyber/beryl-cyber.conf}"
[ -f "$CONF" ] && . "$CONF"

APP_DIR="${APP_DIR:-/mnt/beryl/beryl-cyber/app}"
DATA_DIR="${DATA_DIR:-/mnt/beryl/beryl-cyber/data}"
DB="${DB:-$DATA_DIR/beryl.db}"
LAN_IF="${LAN_IF:-br-lan}"
LEASES_FILE="${LEASES_FILE:-/tmp/dhcp.leases}"
COLLECT_INTERVAL="${COLLECT_INTERVAL:-60}"
OFFLINE_AFTER="${OFFLINE_AFTER:-300}"

log() { logger -t beryl-cyber "$*" 2>/dev/null || echo "beryl-cyber: $*" >&2; }

# Crée la base au premier lancement
init_db() {
    [ -f "$DB" ] && return 0
    mkdir -p "$DATA_DIR" || return 1
    sqlite3 "$DB" < "$APP_DIR/sql/schema.sql" >/dev/null || return 1
    log "base créée : $DB"
}

# Lit la table de voisinage IPv4 de l'interface LAN.
# NEIGH_FILE permet de tester le script avec une sortie enregistrée.
read_neigh() {
    if [ -n "$NEIGH_FILE" ]; then
        cat "$NEIGH_FILE"
    else
        ip -4 neigh show dev "$LAN_IF" 2>/dev/null
    fi
}

# Les entrées STALE (pas de trafic récent) sont relancées par un ping :
# le noyau envoie alors une requête ARP et met l'état à jour pour le cycle suivant.
refresh_stale() {
    [ -n "$NEIGH_FILE" ] && return 0
    for ip in $(read_neigh | awk '$NF == "STALE" { print $1 }'); do
        ping -c 1 -W 1 "$ip" >/dev/null 2>&1 &
    done
    wait
}

# Produit le SQL d'un cycle de collecte, dans une seule transaction.
# Les valeurs venant du réseau sont filtrées (MAC, IP, nom) avant d'entrer dans le SQL.
build_sql() {
    now="$1"
    cutoff=$((now - OFFLINE_AFTER))

    {
        # 1) baux DHCP : "expiration mac ip nom client-id"
        [ -r "$LEASES_FILE" ] && sed 's/^/LEASE /' "$LEASES_FILE"
        # 2) voisins : "ip lladdr mac ETAT"
        read_neigh | sed 's/^/NEIGH /'
    } | awk -v now="$now" -v cutoff="$cutoff" '
    function valid_mac(m) { return m ~ /^[0-9a-f][0-9a-f](:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])$/ }
    function valid_ip(a)  { return a ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ }
    function clean_name(n) { if (n == "*") return ""; gsub(/[^A-Za-z0-9._-]/, "", n); return substr(n, 1, 63) }

    $1 == "LEASE" {
        mac = tolower($3)
        if (valid_mac(mac)) name[mac] = clean_name($5)
        next
    }
    $1 == "NEIGH" {
        ip = $2; state = $NF; mac = ""
        for (i = 3; i < NF; i++) if ($i == "lladdr") mac = tolower($(i + 1))
        if (!valid_mac(mac) || !valid_ip(ip)) next
        if (state == "REACHABLE" || state == "DELAY" || state == "PROBE") seen[mac] = ip
    }
    END {
        print "PRAGMA foreign_keys = ON;"
        print "BEGIN;"
        print "CREATE TEMP TABLE seen (mac TEXT PRIMARY KEY, ip TEXT, hostname TEXT, random_mac INTEGER);"
        for (m in seen) {
            # MAC aléatoire : bit "administré localement" = 2e caractère hexa dans {2,6,a,e}
            rnd = (substr(m, 2, 1) ~ /[26ae]/) ? 1 : 0
            printf "INSERT INTO seen VALUES (\x27%s\x27, \x27%s\x27, \x27%s\x27, %d);\n", m, seen[m], name[m], rnd
        }
        print "CREATE TEMP TABLE new_macs AS SELECT mac FROM seen WHERE mac NOT IN (SELECT mac FROM devices);"

        # nouveaux appareils
        print "INSERT INTO devices (mac, hostname, random_mac, last_ip, first_seen, last_seen)"
        print "  SELECT mac, NULLIF(hostname, \x27\x27), random_mac, ip, " now ", " now " FROM seen WHERE mac IN (SELECT mac FROM new_macs);"
        print "INSERT INTO events (ts, mac, type, detail)"
        print "  SELECT " now ", s.mac, \x27new_device\x27, s.ip FROM seen s WHERE s.mac IN (SELECT mac FROM new_macs);"

        # changement d IP
        print "INSERT INTO events (ts, mac, type, detail)"
        print "  SELECT " now ", d.mac, \x27ip_change\x27, d.last_ip || \x27 -> \x27 || s.ip"
        print "  FROM devices d JOIN seen s ON s.mac = d.mac WHERE d.last_ip IS NOT NULL AND d.last_ip <> s.ip;"

        # retour en ligne : événement + nouvelle session
        print "INSERT INTO events (ts, mac, type, detail)"
        print "  SELECT " now ", d.mac, \x27online\x27, s.ip FROM devices d JOIN seen s ON s.mac = d.mac"
        print "  WHERE d.online = 0 AND d.mac NOT IN (SELECT mac FROM new_macs);"
        print "INSERT INTO sessions (mac, ip, start_ts)"
        print "  SELECT d.mac, s.ip, " now " FROM devices d JOIN seen s ON s.mac = d.mac WHERE d.online = 0;"

        # mise à jour des appareils vus
        print "UPDATE devices SET online = 1, last_seen = " now ","
        print "  last_ip  = (SELECT ip FROM seen WHERE seen.mac = devices.mac),"
        print "  hostname = COALESCE(NULLIF((SELECT hostname FROM seen WHERE seen.mac = devices.mac), \x27\x27), hostname)"
        print "  WHERE mac IN (SELECT mac FROM seen);"

        # appareils hors ligne depuis plus de OFFLINE_AFTER secondes
        print "INSERT INTO events (ts, mac, type) SELECT " now ", mac, \x27offline\x27 FROM devices WHERE online = 1 AND last_seen < " cutoff ";"
        print "UPDATE sessions SET end_ts = (SELECT last_seen FROM devices d WHERE d.mac = sessions.mac)"
        print "  WHERE end_ts IS NULL AND mac IN (SELECT mac FROM devices WHERE online = 1 AND last_seen < " cutoff ");"
        print "UPDATE devices SET online = 0 WHERE online = 1 AND last_seen < " cutoff ";"
        print "COMMIT;"
    }'
}

collect_once() {
    # Horloge pas encore synchronisée (juste après un démarrage) : on attend
    if [ "$(date +%Y)" -lt 2025 ]; then
        log "horloge non synchronisée, cycle ignoré"
        return 0
    fi
    refresh_stale
    now=$(date +%s)
    build_sql "$now" | sqlite3 "$DB" || log "erreur pendant l'écriture en base"
}

command -v sqlite3 >/dev/null 2>&1 || { log "sqlite3 introuvable (opkg install sqlite3-cli)"; exit 1; }
init_db || { log "impossible de créer la base $DB"; exit 1; }

if [ "$1" = "--loop" ]; then
    while true; do
        collect_once
        sleep "$COLLECT_INTERVAL"
    done
else
    collect_once
fi
