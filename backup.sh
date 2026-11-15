#!/bin/sh
# Beryl CYBER : sauvegarde de la base du routeur vers le PC (Git Bash).
#
#   ./backup.sh           sauvegarde si la dernière date de plus de 30 jours
#   ./backup.sh --force   sauvegarde immédiate
#
# Prévu pour être lancé chaque jour par le Planificateur de tâches Windows : il ne fait
# réellement la sauvegarde que tous les 30 jours, même si le PC était éteint le jour prévu.
#
# Étapes :
#   1. sur le routeur, copie cohérente de la base (commande .backup de SQLite : sûre
#      même pendant que la collecte écrit), puis compression
#   2. rapatriement sur le PC, dans un dossier HORS du dépôt Git (données privées)
#   3. conservation des KEEP dernières sauvegardes
#   4. sur le routeur, compactage de la base (VACUUM) pour libérer la place sur la clé

HOST="${HOST:-beryl}"
DEST="${DEST:-$HOME/beryl-backups}"
DAYS="${DAYS:-30}"
KEEP="${KEEP:-12}"
DB="/mnt/beryl/beryl-cyber/data/beryl.db"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10 $HOST"

mkdir -p "$DEST"
LOG="$DEST/backup.log"
log() { echo "$(date '+%Y-%m-%d %H:%M') $*" | tee -a "$LOG"; }

# Sauvegarde nécessaire ? (fichier le plus récent de moins de DAYS jours = rien à faire)
if [ "$1" != "--force" ] && [ -n "$(find "$DEST" -name 'beryl-*.db.gz' -mtime -"$DAYS" 2>/dev/null | head -n 1)" ]; then
    exit 0
fi

stamp="$(date +%Y-%m-%d)"
file="$DEST/beryl-$stamp.db.gz"

# 1. Copie cohérente + compression sur le routeur
if ! $SSH "sqlite3 '$DB' \".backup /tmp/beryl-backup.db\" && gzip -f /tmp/beryl-backup.db" 2>>"$LOG"; then
    log "ÉCHEC : routeur injoignable ou copie impossible"
    exit 1
fi

# 2. Rapatriement (scp -O : protocole compatible avec Dropbear)
if ! scp -O -q -o BatchMode=yes "$HOST:/tmp/beryl-backup.db.gz" "$file" 2>>"$LOG"; then
    log "ÉCHEC : transfert impossible"
    $SSH "rm -f /tmp/beryl-backup.db.gz"
    exit 1
fi
$SSH "rm -f /tmp/beryl-backup.db.gz"

# Vérification : l'archive doit être lisible
if ! gzip -t "$file" 2>/dev/null; then
    log "ÉCHEC : archive corrompue, supprimée"
    rm -f "$file"
    exit 1
fi

# 3. Rotation : on garde les KEEP plus récentes
ls -1t "$DEST"/beryl-*.db.gz 2>/dev/null | tail -n +"$((KEEP + 1))" | while read -r old; do
    rm -f "$old" && log "ancienne sauvegarde supprimée : $(basename "$old")"
done

# 4. Compactage de la base sur la clé
before="$($SSH "ls -l '$DB' | awk '{print \$5}'")"
$SSH "sqlite3 '$DB' 'VACUUM;'" 2>>"$LOG"
after="$($SSH "ls -l '$DB' | awk '{print \$5}'")"

log "OK : $(basename "$file") ($(du -h "$file" | cut -f1)), base sur la clé : $before -> $after octets"
