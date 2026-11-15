#!/bin/sh
# Beryl CYBER : comptage de la bande passante par appareil.
#
# Chaîne iptables BERYL_ACCT, appelée en tête de FORWARD, avec deux règles par appareil
# en ligne : "-s IP" (envoi) et "-d IP" (téléchargement). Chaque règle porte en
# commentaire le sens et la MAC de l'appareil.
#
# À chaque passage (appelé par collect.sh) :
#   1. lecture des compteurs ET remise à zéro en une seule opération (-L -Z)
#   2. ajout des octets au total du jour de chaque appareil (table traffic)
#   3. reconstruction des règles si la liste des appareils en ligne a changé
#
# Prérequis : accélération matérielle désactivée. Sinon les paquets accélérés
# ne passent plus par le pare-feu et ne sont pas comptés.
# IPv6 non compté : le réseau n'a pas d'adressage IPv6 public.

CONF="${CONF:-/mnt/beryl/beryl-cyber/beryl-cyber.conf}"
[ -f "$CONF" ] && . "$CONF"
DATA_DIR="${DATA_DIR:-/mnt/beryl/beryl-cyber/data}"
DB="${DB:-$DATA_DIR/beryl.db}"
CHAIN=BERYL_ACCT

command -v iptables >/dev/null 2>&1 || exit 0

# Chaîne et branchement (recréés si un rechargement du pare-feu les a supprimés)
iptables -N "$CHAIN" 2>/dev/null
iptables -C FORWARD -j "$CHAIN" 2>/dev/null || iptables -I FORWARD 1 -j "$CHAIN"

today="$(date +%F)"

# --- 1 et 2. Lecture + remise à zéro, puis enregistrement -----------------------
# Ligne type : "  12  3456 RETURN all -- * * 0.0.0.0/0 192.168.8.10 /* rx|aa:bb:cc:dd:ee:ff */"
iptables -L "$CHAIN" -n -v -x -Z 2>/dev/null | awk -v day="$today" '
    match($0, /\/\* (rx|tx)\|[0-9a-f:]+ \*\//) {
        tag = substr($0, RSTART + 3, RLENGTH - 6)      # "rx|aa:bb:..."
        split(tag, t, "|")
        if ($2 > 0) bytes[t[2], t[1]] += $2
        macs[t[2]] = 1
    }
    END {
        n = 0
        for (m in macs) {
            rx = bytes[m, "rx"] + 0; tx = bytes[m, "tx"] + 0
            if (rx == 0 && tx == 0) continue
            if (n++ == 0) print "BEGIN;"
            printf "INSERT INTO traffic (mac, day, rx, tx) VALUES (\x27%s\x27, \x27%s\x27, %d, %d)\n", m, day, rx, tx
            print "  ON CONFLICT (mac, day) DO UPDATE SET rx = rx + excluded.rx, tx = tx + excluded.tx;"
        }
        if (n > 0) print "COMMIT;"
    }' | sqlite3 "$DB" 2>/dev/null

# --- 3. Règles à jour avec les appareils en ligne -------------------------------
wanted="$(sqlite3 -separator ' ' "$DB" "SELECT mac, last_ip FROM devices WHERE online = 1 AND last_ip IS NOT NULL ORDER BY mac;" 2>/dev/null)"
current="$(iptables -S "$CHAIN" 2>/dev/null | sed -n 's/^-A .* -s \([0-9.]*\)\/32 .*tx|\([0-9a-f:]*\).*/\2 \1/p' | sort)"

if [ "$wanted" != "$current" ]; then
    iptables -F "$CHAIN"
    echo "$wanted" | while read -r mac ip; do
        echo "$mac" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || continue
        echo "$ip"  | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'  || continue
        iptables -A "$CHAIN" -s "$ip" -m comment --comment "tx|$mac" -j RETURN
        iptables -A "$CHAIN" -d "$ip" -m comment --comment "rx|$mac" -j RETURN
    done
fi
