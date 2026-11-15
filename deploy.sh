#!/bin/sh
# Beryl CYBER : déploiement depuis le PC (Git Bash) vers le routeur.
#   ./deploy.sh
# Copie le programme sur la clé USB du routeur, puis lance l'installation.
# Nécessite l'accès SSH par clé à l'hôte "beryl" (voir ~/.ssh/config).

set -e
HOST="${HOST:-beryl}"
cd "$(dirname "$0")"

echo "==> Envoi des fichiers vers $HOST"
tar -cf - router sql web config | ssh "$HOST" '
    mp=$(block info 2>/dev/null | sed -n "/LABEL=\"beryl\"/s/.*MOUNT=\"\([^\"]*\)\".*/\1/p")
    [ -n "$mp" ] || { echo "Clé USB \"beryl\" introuvable ou non montée"; exit 1; }
    mkdir -p "$mp/beryl-cyber/app"
    tar -xf - -C "$mp/beryl-cyber/app"
    sh "$mp/beryl-cyber/app/router/install.sh"
'
