#!/bin/sh
# Beryl CYBER : lanceur du service.
# Attend que la clé USB "beryl" soit montée, met à jour le raccourci /mnt/beryl,
# puis démarre la collecte en boucle.
#
# Installé sur la mémoire du routeur (/usr/sbin/beryl-cyber-launch) :
# le reste du programme est sur la clé USB et n'est disponible qu'une fois celle-ci montée.

LABEL="beryl"
LINK="/mnt/beryl"

mount_point() {
    block info 2>/dev/null | grep "LABEL=\"$LABEL\"" | sed -n 's/.*MOUNT="\([^"]*\)".*/\1/p'
}

# Au démarrage, la clé peut être montée quelques secondes après le service : on attend jusqu'à 60 s
i=0
mp="$(mount_point)"
while [ -z "$mp" ] && [ "$i" -lt 30 ]; do
    sleep 2
    i=$((i + 1))
    mp="$(mount_point)"
done

if [ -z "$mp" ]; then
    logger -t beryl-cyber "clé USB \"$LABEL\" introuvable ou non montée"
    exit 1
fi

[ "$(readlink "$LINK")" = "$mp" ] || ln -sfn "$mp" "$LINK"

exec "$LINK/beryl-cyber/app/router/bin/collect.sh" --loop
