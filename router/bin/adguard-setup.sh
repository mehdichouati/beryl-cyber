#!/bin/sh
# Beryl CYBER : réglages d'AdGuard Home pour la V3 (appelé par install.sh).
#
# 1. Sécurité : l'interface web d'AdGuard (port 3000) n'a pas de mot de passe dans la
#    configuration GL.iNet. Le pare-feu la réserve au poste d'administration, comme le
#    tableau de bord. Le routeur lui-même (interface GL.iNet) y accède toujours en local.
# 2. Journal des requêtes : conservé 24 h par AdGuard (sur la mémoire du routeur).
#    L'API d'AdGuard est protégée par le firmware GL.iNet (401 sans session GL) : le
#    réglage est donc fait directement dans config.yaml, puis AdGuard est redémarré.
#    L'historique du projet (7 jours) est stocké dans la base, sur la clé USB.
#    Les adresses IP des appareils ne sont pas anonymisées : elles servent à relier
#    chaque requête à un appareil.
#
# Sans AdGuard Home actif, ne fait rien.

CONF="${CONF:-/mnt/beryl/beryl-cyber/beryl-cyber.conf}"
[ -f "$CONF" ] && . "$CONF"
AGH_CONF="/etc/AdGuardHome/config.yaml"
ADMIN_MAC="$(echo "$ADMIN_MAC" | tr 'A-F' 'a-f')"

if ! pidof AdGuardHome >/dev/null 2>&1; then
    echo "    AdGuard Home inactif : étape ignorée"
    exit 0
fi

# --- 1. Pare-feu : port 3000 réservé au poste d'administration ---------------------
uci -q delete firewall.beryl_cyber_agh_admin
uci -q delete firewall.beryl_cyber_agh_deny
if [ -n "$ADMIN_MAC" ]; then
    uci set firewall.beryl_cyber_agh_admin=rule
    uci set firewall.beryl_cyber_agh_admin.name='Beryl CYBER - AdGuard admin'
    uci set firewall.beryl_cyber_agh_admin.src='lan'
    uci set firewall.beryl_cyber_agh_admin.proto='tcp'
    uci set firewall.beryl_cyber_agh_admin.dest_port='3000'
    uci set firewall.beryl_cyber_agh_admin.src_mac="$ADMIN_MAC"
    [ -n "$ADMIN_IP" ] && uci set firewall.beryl_cyber_agh_admin.src_ip="$ADMIN_IP"
    uci set firewall.beryl_cyber_agh_admin.target='ACCEPT'

    uci set firewall.beryl_cyber_agh_deny=rule
    uci set firewall.beryl_cyber_agh_deny.name='Beryl CYBER - AdGuard refus'
    uci set firewall.beryl_cyber_agh_deny.src='lan'
    uci set firewall.beryl_cyber_agh_deny.proto='tcp'
    uci set firewall.beryl_cyber_agh_deny.dest_port='3000'
    uci set firewall.beryl_cyber_agh_deny.target='REJECT'
    uci commit firewall
    /etc/init.d/firewall reload >/dev/null 2>&1
    echo "    interface AdGuard réservée à $ADMIN_MAC"
else
    uci commit firewall
    echo "    ATTENTION : ADMIN_MAC vide, l'interface AdGuard reste ouverte à tout le LAN"
fi

# --- 2. Journal des requêtes -------------------------------------------------------
# - conservé 24 h par AdGuard ; l'historique du projet (7 jours) est dans la base
# - écrit dans un fichier SUR LA CLÉ USB (pas sur la mémoire flash du routeur)
# - vidé sur disque toutes les 200 requêtes (au lieu de 1000) : historique plus frais
# - IP des appareils conservées (elles relient chaque requête à un appareil)
# L'API d'AdGuard étant protégée par GL.iNet, les réglages sont faits dans config.yaml.
QLOG_DIR="/mnt/beryl/beryl-cyber/data/adguard"
mkdir -p "$QLOG_DIR"

if [ -f "$AGH_CONF" ]; then
    cp "$AGH_CONF" "$AGH_CONF.beryl-before"
    awk -v dir="$QLOG_DIR" '
        /^[a-z_]+:/ { section = $1 }
        section == "querylog:" && /^  interval:/     { $0 = "  interval: 24h" }
        section == "querylog:" && /^  dir_path:/     { $0 = "  dir_path: \"" dir "\"" }
        section == "querylog:" && /^  size_memory:/  { $0 = "  size_memory: 200" }
        section == "querylog:" && /^  enabled:/      { $0 = "  enabled: true" }
        section == "querylog:" && /^  file_enabled:/ { $0 = "  file_enabled: true" }
        /^ *anonymize_client_ip:/ { sub(/:.*/, ": false") }
        { print }' "$AGH_CONF.beryl-before" > "$AGH_CONF.new"
    if cmp -s "$AGH_CONF.new" "$AGH_CONF.beryl-before"; then
        rm -f "$AGH_CONF.new"
        echo "    journal AdGuard : déjà configuré"
    else
        cat "$AGH_CONF.new" > "$AGH_CONF"      # cat plutôt que mv : garde les droits du fichier
        rm -f "$AGH_CONF.new"
        /etc/init.d/adguardhome restart >/dev/null 2>&1
        echo "    journal AdGuard : 24 h, fichier sur la clé ($QLOG_DIR), AdGuard redémarré"
    fi
fi
