#!/bin/sh
# Beryl CYBER : entretien automatique, appelé par collect.sh à chaque cycle.
# Ne fait réellement quelque chose que lorsque c'est nécessaire (vérifications légères).
#
#   - base de géolocalisation (geo.db) de plus de 32 jours : nouvelle version DB-IP
#   - base des fabricants (oui.txt) de plus de 32 jours    : nouvelle version Wireshark
#   - informations d'adresses (ip_info) de plus de 30 jours : effacées, pour être
#     recherchées à nouveau avec la base à jour
#
# Les téléchargements tournent en arrière-plan, protégés par un verrou : la collecte
# n'est jamais bloquée et deux mises à jour ne peuvent pas se chevaucher.

CONF="${CONF:-/mnt/beryl/beryl-cyber/beryl-cyber.conf}"
[ -f "$CONF" ] && . "$CONF"
DATA_DIR="${DATA_DIR:-/mnt/beryl/beryl-cyber/data}"
DB="${DB:-$DATA_DIR/beryl.db}"
BIN="$(dirname "$0")"
MAX_AGE=32

log() { logger -t beryl-cyber "maintenance: $*" 2>/dev/null; }

# Lance une mise à jour en arrière-plan si le fichier est absent ou trop ancien
refresh() {    # refresh FICHIER SCRIPT NOM
    file="$1"; script="$2"; name="$3"; lock="/tmp/beryl-update-$name.lock"
    if [ -f "$file" ] && [ -z "$(find "$file" -mtime +"$MAX_AGE" 2>/dev/null)" ]; then
        return 0                                   # récent : rien à faire
    fi
    retry="$DATA_DIR/.retry-$name"                 # dernier échec : on attend 1 jour
    [ -n "$(find "$retry" -mtime -1 2>/dev/null)" ] && return 0
    mkdir "$lock" 2>/dev/null || return 0          # mise à jour déjà en cours
    (
        if sh "$BIN/$script" >/tmp/beryl-update-$name.log 2>&1; then
            rm -f "$retry"
            log "$name mis à jour"
        else
            touch "$retry"
            log "$name : échec de la mise à jour ($(tail -n 1 /tmp/beryl-update-$name.log))"
        fi
        rmdir "$lock"
    ) &
}

refresh "$DATA_DIR/geo.db"  update-geoip.sh geo
refresh "$DATA_DIR/oui.txt" update-oui.sh   oui

# Cache des adresses : renouvelé tous les 30 jours
[ -f "$DB" ] && sqlite3 "$DB" "DELETE FROM ip_info WHERE updated < $(( $(date +%s) - 30 * 86400 ));" 2>/dev/null
exit 0
