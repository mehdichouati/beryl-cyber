#!/bin/sh
# Beryl CYBER : installation sur le routeur.
# Lancé par deploy.sh depuis le PC, ou à la main après une mise à jour du firmware :
#   sh /mnt/beryl/beryl-cyber/app/router/install.sh
#
# Le programme et les données restent sur la clé USB. Ce script ne place sur la
# mémoire du routeur que le service et son lanceur, et les protège des mises à jour.

set -e

APP="$(cd "$(dirname "$0")/.." && pwd)"     # .../beryl-cyber/app
BASE="$(dirname "$APP")"                    # .../beryl-cyber
MOUNT="$(dirname "$BASE")"                  # point de montage de la clé

step() { echo "==> $*"; }

# Cherche le processus dans /proc plutôt qu'avec ps : sans terminal (via SSH),
# ps coupe les lignes à 80 caractères et le nom du script n'y apparaît pas en entier.
collect_running() {
    for f in /proc/[0-9]*/cmdline; do
        tr '\0' ' ' 2>/dev/null < "$f" | grep -q "[c]ollect.sh --loop" && return 0
    done
    return 1
}

step "Clé USB : $MOUNT"
ln -sfn "$MOUNT" /mnt/beryl
mkdir -p "$BASE/data" "$BASE/logs" "$BASE/backup"

if [ ! -f "$BASE/beryl-cyber.conf" ] && [ -f "$APP/config/beryl-cyber.conf.example" ]; then
    step "Configuration par défaut"
    cp "$APP/config/beryl-cyber.conf.example" "$BASE/beryl-cyber.conf"
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
    step "Installation de sqlite3-cli"
    opkg update >/dev/null
    opkg install sqlite3-cli
fi

if ! command -v curl >/dev/null 2>&1; then
    step "Installation de curl (notifications Discord)"
    opkg update >/dev/null
    opkg install curl ca-bundle
fi

# La configuration peut contenir le jeton Discord : lisible par root uniquement
[ -f "$BASE/beryl-cyber.conf" ] && chmod 600 "$BASE/beryl-cyber.conf"

command -v uhttpd >/dev/null 2>&1 || { echo "uhttpd introuvable : opkg install uhttpd"; exit 1; }

if [ ! -f "$BASE/data/oui.txt" ]; then
    step "Base des fabricants (OUI)"
    sh "$APP/router/bin/update-oui.sh" || echo "    (non bloquant : à relancer plus tard)"
fi

if [ ! -f "$BASE/data/geo.db" ]; then
    step "Base de géolocalisation (DB-IP)"
    sh "$APP/router/bin/update-geoip.sh" || echo "    (non bloquant : à relancer plus tard)"
fi

step "Comptage des octets par connexion (conntrack)"
echo "net.netfilter.nf_conntrack_acct=1" > /etc/sysctl.d/90-beryl-cyber.conf
sysctl -w net.netfilter.nf_conntrack_acct=1 >/dev/null

step "Service et lanceur"
chmod 755 "$APP"/router/bin/*.sh "$APP"/web/cgi-bin/*.sh
cp "$APP/router/bin/launch.sh"      /usr/sbin/beryl-cyber-launch
cp "$APP/router/init.d/beryl-cyber" /etc/init.d/beryl-cyber
chmod 755 /usr/sbin/beryl-cyber-launch /etc/init.d/beryl-cyber
/etc/init.d/beryl-cyber enable

step "Pare-feu du tableau de bord"
sh "$APP/router/bin/firewall.sh"

step "Protection contre les mises à jour du firmware"
for f in /etc/init.d/beryl-cyber /usr/sbin/beryl-cyber-launch /etc/rc.d/S99beryl-cyber /etc/rc.d/K10beryl-cyber /etc/beryl-cyber/ /etc/sysctl.d/90-beryl-cyber.conf; do
    grep -qxF "$f" /etc/sysupgrade.conf 2>/dev/null || echo "$f" >> /etc/sysupgrade.conf
done

step "Démarrage"
/etc/init.d/beryl-cyber stop 2>/dev/null || true
/etc/init.d/beryl-cyber start

# Le lanceur peut mettre quelques secondes à trouver la clé : on attend jusqu'à 20 s
collect_ok=0; web_ok=0; i=0
while [ "$i" -lt 20 ]; do
    collect_running && collect_ok=1
    netstat -tln | grep -q ":8080 " && web_ok=1
    [ "$collect_ok" = 1 ] && { [ "$web_ok" = 1 ] || [ ! -s /etc/beryl-cyber/httpd.conf ]; } && break
    sleep 1
    i=$((i + 1))
done

ok=1
[ "$collect_ok" = 1 ] && echo "    collecte : OK"        || { echo "    collecte : ARRÊTÉE"; ok=0; }
if [ ! -s /etc/beryl-cyber/httpd.conf ]; then
    echo "    tableau de bord : en attente d'un mot de passe"
    echo "    -> ssh -t beryl sh $APP/router/bin/set-password.sh"
    web_ok=skip
elif [ "$web_ok" = 1 ]; then
    echo "    tableau de bord : OK"
else
    echo "    tableau de bord : ARRÊTÉ"; ok=0
fi

lan_ip="$(uci -q get network.lan.ipaddr | cut -d/ -f1)"
[ "$ok" = 1 ] && echo "==> Installation terminée : http://${lan_ip:-192.168.8.1}:8080" \
              || { echo "==> Problème : voir logread -e beryl-cyber"; exit 1; }
