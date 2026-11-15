#!/bin/sh
# Beryl CYBER : définit l'identifiant et le mot de passe du tableau de bord.
#   ssh -t beryl sh /mnt/beryl/beryl-cyber/app/router/bin/set-password.sh [identifiant]
#
# Le mot de passe n'est jamais stocké en clair : seule son empreinte (MD5-crypt,
# générée par uhttpd) est écrite dans /etc/beryl-cyber/httpd.conf, lisible par root uniquement.
# Ce fichier est sur la mémoire du routeur (disponible dès le démarrage) et protégé
# des mises à jour du firmware par install.sh.

AUTH_DIR=/etc/beryl-cyber
AUTH_FILE="$AUTH_DIR/httpd.conf"
user="${1:-admin}"

echo "$user" | grep -qE '^[A-Za-z0-9_-]{1,32}$' || { echo "Identifiant invalide (lettres, chiffres, _ et - uniquement)"; exit 1; }
[ -t 0 ] || { echo "Lancer ce script dans un terminal : ssh -t beryl ..."; exit 1; }

# Saisie masquée avec "read -s" (intégré au shell : le firmware GL.iNet n'a pas stty)
ask() {
    printf '%s' "$1"
    if ! read -rs answer 2>/dev/null; then
        printf '(saisie visible) '
        read -r answer
    fi
    echo
}

ask "Nouveau mot de passe pour \"$user\" : "; p1="$answer"
ask "Confirmer le mot de passe : ";             p2="$answer"

[ "$p1" = "$p2" ] || { echo "Les mots de passe ne correspondent pas."; exit 1; }
[ "${#p1}" -ge 10 ] || { echo "Mot de passe trop court (10 caractères minimum)."; exit 1; }

hash="$(uhttpd -m "$p1")"
case "$hash" in
    \$1\$*) ;;
    *) echo "Impossible de générer l'empreinte du mot de passe."; exit 1 ;;
esac

mkdir -p "$AUTH_DIR"
umask 077
printf '/:%s:%s\n' "$user" "$hash" > "$AUTH_FILE"
chmod 600 "$AUTH_FILE"

/etc/init.d/beryl-cyber restart 2>/dev/null
echo "Mot de passe enregistré. Tableau de bord protégé (identifiant : $user)."
