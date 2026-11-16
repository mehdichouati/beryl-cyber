#!/bin/sh
# Beryl CYBER : restriction d'accès au tableau de bord.
#
# - Réserve une IP fixe au poste d'administration (bail DHCP statique)
# - Pare-feu : seul ce poste (MAC + IP) peut joindre le port du tableau de bord,
#   les autres appareils du LAN sont rejetés.
#
# Idempotent : les règles portent des noms fixes et sont remplacées à chaque exécution.
# Ne touche ni au SSH ni à l'interface GL.iNet.

CONF="${CONF:-/mnt/beryl/beryl-cyber/beryl-cyber.conf}"
[ -f "$CONF" ] && . "$CONF"
WEB_PORT="${WEB_PORT:-8080}"

ADMIN_MAC="$(echo "$ADMIN_MAC" | tr 'A-F' 'a-f')"

valid_mac() { echo "$1" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; }
valid_ip()  { echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }

# Suppression des anciennes règles du projet
uci -q delete firewall.beryl_cyber_admin
uci -q delete firewall.beryl_cyber_deny
uci -q delete dhcp.beryl_cyber_admin

if [ -z "$ADMIN_MAC" ]; then
    echo "    ATTENTION : ADMIN_MAC vide, le tableau de bord est accessible à tout le LAN"
else
    valid_mac "$ADMIN_MAC" || { echo "ADMIN_MAC invalide : $ADMIN_MAC"; exit 1; }
    [ -z "$ADMIN_IP" ] || valid_ip "$ADMIN_IP" || { echo "ADMIN_IP invalide : $ADMIN_IP"; exit 1; }

    # Bail DHCP statique : le poste garde toujours la même IP
    if [ -n "$ADMIN_IP" ]; then
        uci set dhcp.beryl_cyber_admin=host
        # pas d'option "name" : sinon dnsmasq remplacerait le nom annoncé par le PC
        uci set dhcp.beryl_cyber_admin.mac="$ADMIN_MAC"
        uci set dhcp.beryl_cyber_admin.ip="$ADMIN_IP"
    fi

    # Règle 1 : le poste d'administration est autorisé
    uci set firewall.beryl_cyber_admin=rule
    uci set firewall.beryl_cyber_admin.name='Beryl CYBER - admin'
    uci set firewall.beryl_cyber_admin.src='lan'
    uci set firewall.beryl_cyber_admin.proto='tcp'
    uci set firewall.beryl_cyber_admin.dest_port="$WEB_PORT"
    uci set firewall.beryl_cyber_admin.src_mac="$ADMIN_MAC"
    [ -n "$ADMIN_IP" ] && uci set firewall.beryl_cyber_admin.src_ip="$ADMIN_IP"
    uci set firewall.beryl_cyber_admin.target='ACCEPT'

    # Règle 2 : tous les autres appareils du LAN sont rejetés
    uci set firewall.beryl_cyber_deny=rule
    uci set firewall.beryl_cyber_deny.name='Beryl CYBER - refus'
    uci set firewall.beryl_cyber_deny.src='lan'
    uci set firewall.beryl_cyber_deny.proto='tcp'
    uci set firewall.beryl_cyber_deny.dest_port="$WEB_PORT"
    uci set firewall.beryl_cyber_deny.target='REJECT'

    echo "    accès réservé à $ADMIN_MAC${ADMIN_IP:+ ($ADMIN_IP)}"
fi

# Les règles de la liste blanche sont réappliquées à chaque rechargement du pare-feu
mkdir -p /etc/beryl-cyber
cat > /etc/beryl-cyber/firewall.include <<'INC'
#!/bin/sh
# Beryl CYBER : réapplique la liste blanche après un rechargement du pare-feu
BIN=/mnt/beryl/beryl-cyber/app/router/bin
[ -x "$BIN/whitelist.sh" ] && "$BIN/whitelist.sh"
[ -x "$BIN/dns-force.sh" ] && "$BIN/dns-force.sh"
exit 0
INC
chmod 755 /etc/beryl-cyber/firewall.include
uci -q delete firewall.beryl_cyber_include
uci set firewall.beryl_cyber_include=include
uci set firewall.beryl_cyber_include.type='script'
uci set firewall.beryl_cyber_include.path='/etc/beryl-cyber/firewall.include'
uci set firewall.beryl_cyber_include.reload='1'

uci commit dhcp
uci commit firewall
/etc/init.d/dnsmasq reload >/dev/null 2>&1
/etc/init.d/firewall reload >/dev/null 2>&1
