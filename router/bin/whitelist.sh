#!/bin/sh
# Beryl CYBER : application de la liste blanche au pare-feu (iptables).
#
# Chaîne BERYL_WL, appelée depuis FORWARD pour tout ce qui sort du LAN :
#   1. appareils "blocked"                      -> rejetés (toujours)
#   2. si WHITELIST_ENABLED=1 :
#        poste d'administration + "approved"    -> autorisés
#        tous les autres (dont les nouveaux)    -> rejetés
#
# Le réseau local reste accessible à tous (DHCP, DNS, interface du routeur) :
# seul l'accès à Internet est filtré.
#
# Usage :
#   whitelist.sh              reconstruit les règles depuis la base
#   whitelist.sh MAC          idem, puis coupe les connexions en cours de cet appareil s'il est refusé

CONF="${CONF:-/mnt/beryl/beryl-cyber/beryl-cyber.conf}"
[ -f "$CONF" ] && . "$CONF"
DATA_DIR="${DATA_DIR:-/mnt/beryl/beryl-cyber/data}"
DB="${DB:-$DATA_DIR/beryl.db}"
LAN_IF="${LAN_IF:-br-lan}"
WHITELIST_ENABLED="${WHITELIST_ENABLED:-0}"
ADMIN_MAC="$(echo "$ADMIN_MAC" | tr 'A-F' 'a-f')"
CHAIN=BERYL_WL

log() { logger -t beryl-cyber "$*" 2>/dev/null; }

valid_mac() { echo "$1" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; }

macs_with_status() {
    [ -f "$DB" ] && sqlite3 "$DB" "SELECT mac FROM devices WHERE status = '$1';" 2>/dev/null
}

# Sécurité : jamais de liste blanche active sans poste d'administration défini
if [ "$WHITELIST_ENABLED" = 1 ] && ! valid_mac "$ADMIN_MAC"; then
    log "liste blanche non activée : ADMIN_MAC absent ou invalide"
    WHITELIST_ENABLED=0
fi

blocked="$(macs_with_status blocked)"
approved="$(macs_with_status approved)"

build() {
    ipt="$1"
    command -v "$ipt" >/dev/null 2>&1 || return 0

    $ipt -N "$CHAIN" 2>/dev/null
    $ipt -F "$CHAIN"
    $ipt -C FORWARD -i "$LAN_IF" -j "$CHAIN" 2>/dev/null || $ipt -I FORWARD 1 -i "$LAN_IF" -j "$CHAIN"

    for m in $blocked; do
        valid_mac "$m" || continue
        [ "$m" = "$ADMIN_MAC" ] && continue          # le poste d'administration n'est jamais bloqué
        $ipt -A "$CHAIN" -m mac --mac-source "$m" -j REJECT
    done

    if [ "$WHITELIST_ENABLED" = 1 ]; then
        $ipt -A "$CHAIN" -m mac --mac-source "$ADMIN_MAC" -j RETURN
        for m in $approved; do
            valid_mac "$m" && $ipt -A "$CHAIN" -m mac --mac-source "$m" -j RETURN
        done
        $ipt -A "$CHAIN" -j REJECT
    fi
}

build iptables
build ip6tables

# Coupe les connexions déjà ouvertes d'un appareil qui vient d'être refusé
# (sinon elles continueraient jusqu'à leur expiration, surtout avec l'accélération matérielle)
target="$(echo "$1" | tr 'A-F' 'a-f')"
if valid_mac "$target" && command -v conntrack >/dev/null 2>&1; then
    status="$(sqlite3 "$DB" "SELECT status FROM devices WHERE mac = '$target';" 2>/dev/null)"
    ip="$(sqlite3 "$DB" "SELECT last_ip FROM devices WHERE mac = '$target';" 2>/dev/null)"
    denied=0
    [ "$status" = "blocked" ] && [ "$target" != "$ADMIN_MAC" ] && denied=1
    [ "$WHITELIST_ENABLED" = 1 ] && [ "$status" != "approved" ] && [ "$target" != "$ADMIN_MAC" ] && denied=1
    if [ "$denied" = 1 ] && [ -n "$ip" ]; then
        conntrack -D -s "$ip" >/dev/null 2>&1
        conntrack -D -d "$ip" >/dev/null 2>&1
    fi
fi

log "liste blanche appliquée (active=$WHITELIST_ENABLED, approuvés=$(echo $approved | wc -w), bloqués=$(echo $blocked | wc -w))"
