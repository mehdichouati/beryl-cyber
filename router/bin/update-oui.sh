#!/bin/sh
# Beryl CYBER : télécharge la base des fabricants (préfixes OUI des adresses MAC).
#
# Source : fichier "manuf" du projet Wireshark, converti en format compact
#   AABBCC|Fabricant
# et stocké sur la clé USB. À relancer de temps en temps pour le mettre à jour.

CONF="${CONF:-/mnt/beryl/beryl-cyber/beryl-cyber.conf}"
[ -f "$CONF" ] && . "$CONF"
DATA_DIR="${DATA_DIR:-/mnt/beryl/beryl-cyber/data}"
OUI_FILE="$DATA_DIR/oui.txt"
URL="https://www.wireshark.org/download/automated/data/manuf"
TMP="/tmp/beryl-manuf.$$"

command -v curl >/dev/null 2>&1 || { echo "curl introuvable"; exit 1; }

if ! curl -fsSL -m 60 -o "$TMP" "$URL"; then
    echo "téléchargement impossible : $URL"
    rm -f "$TMP"
    exit 1
fi

# Fichier éventuellement compressé (gzip) : on le décompresse
if gunzip -t "$TMP" 2>/dev/null; then
    gunzip -c "$TMP" > "$TMP.txt" && mv "$TMP.txt" "$TMP"
fi

# Garde uniquement les préfixes de 24 bits (AA:BB:CC), sans les guillemets
mkdir -p "$DATA_DIR"
# Analyse sans dépendre du séparateur : selon les versions d'awk (BusyBox notamment)
# et du fichier, les colonnes peuvent être séparées par des tabulations ou des espaces.
# Ligne attendue : AA:BB:CC <nom court> [<tab> <nom complet>]
awk '
    /^#/ { next }
    {
        sub(/\r$/, "")
        if ($0 !~ /^[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f][ \t]/) next
        p = toupper(substr($0, 1, 8)); gsub(":", "", p)
        rest = substr($0, 9); sub(/^[ \t]+/, "", rest)
        n = split(rest, parts, "\t")
        name = (n >= 2 && parts[n] != "") ? parts[n] : rest
        gsub(/["\047\\|;<>`$]/, "", name)
        print p "|" substr(name, 1, 60)
    }' "$TMP" > "$OUI_FILE.new"
mv "$TMP" "$TMP.debug"

count="$(wc -l < "$OUI_FILE.new")"
if [ "$count" -lt 1000 ]; then
    echo "fichier reçu invalide ($count lignes). Début du fichier :"
    head -c 300 "$TMP.debug" 2>/dev/null; echo
    rm -f "$OUI_FILE.new" "$TMP.debug"
    exit 1
fi
rm -f "$TMP.debug"
mv "$OUI_FILE.new" "$OUI_FILE"
echo "    base des fabricants : $count préfixes"
