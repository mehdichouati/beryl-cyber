#!/bin/sh
# Beryl CYBER : DNS forcé (V3).
#
# Sans cette règle, un appareil peut contourner AdGuard (historique ET filtrage) :
#   - en interrogeant directement un autre DNS (8.8.8.8, 1.1.1.1...) : GL.iNet ne
#     redirige que les requêtes adressées au routeur
#   - en utilisant le DNS chiffré : DNS-over-TLS (port 853) ou DNS-over-HTTPS (port 443
#     vers des résolveurs publics connus)
#
# Ce script :
#   1. redirige TOUT le DNS classique (port 53) venant du LAN vers AdGuard (port 3053),
#      quelle que soit la destination demandée par l'appareil (chaîne nat BERYL_DNS)
#   2. bloque le DNS-over-TLS et le DNS-over-HTTPS vers les résolveurs publics connus
#      (chaîne BERYL_DOH) : les appareils reviennent alors au DNS classique
#
# Sécurité de fonctionnement : si AdGuard ne tourne pas, la redirection est RETIRÉE
# (sinon plus aucun appareil n'aurait de DNS). Appelé à chaque cycle par maintenance.sh,
# il s'adapte tout seul. IPv6 non traité : le réseau n'a pas d'adressage IPv6 public.

CONF="${CONF:-/mnt/beryl/beryl-cyber/beryl-cyber.conf}"
[ -f "$CONF" ] && . "$CONF"
DNS_FORCE="${DNS_FORCE:-1}"
LAN_IF="${LAN_IF:-br-lan}"
AGH_PORT=3053

# Résolveurs DNS-over-HTTPS / DNS-over-TLS publics les plus courants
DOH_IPS="8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 1.1.1.2 1.0.0.2 1.1.1.3 1.0.0.3 9.9.9.9 149.112.112.112 \
9.9.9.11 149.112.112.11 208.67.222.222 208.67.220.220 94.140.14.14 94.140.15.15 \
45.90.28.0 45.90.30.0 76.76.2.0 76.76.10.0 185.228.168.168 185.228.169.168"

log() { logger -t beryl-cyber "dns-force: $*" 2>/dev/null; }

agh_up() { pidof AdGuardHome >/dev/null 2>&1 && netstat -ln 2>/dev/null | grep -q ":$AGH_PORT "; }

remove_all() {
    iptables -t nat -D PREROUTING -i "$LAN_IF" -j BERYL_DNS 2>/dev/null
    iptables -t nat -F BERYL_DNS 2>/dev/null
    iptables -D FORWARD -i "$LAN_IF" -j BERYL_DOH 2>/dev/null
    iptables -F BERYL_DOH 2>/dev/null
}

if [ "$DNS_FORCE" != 1 ]; then
    remove_all
    exit 0
fi

if ! agh_up; then
    if iptables -t nat -C PREROUTING -i "$LAN_IF" -j BERYL_DNS 2>/dev/null; then
        remove_all
        log "AdGuard Home arrêté : redirection DNS retirée"
    fi
    exit 0
fi

# Déjà en place et complet : rien à faire (cas normal, à chaque cycle)
if iptables -t nat -C PREROUTING -i "$LAN_IF" -j BERYL_DNS 2>/dev/null \
   && iptables -C FORWARD -i "$LAN_IF" -j BERYL_DOH 2>/dev/null \
   && [ "$(iptables -S BERYL_DOH 2>/dev/null | grep -c '^-A')" -gt 0 ]; then
    exit 0
fi

# --- 1. Redirection de tout le DNS classique vers AdGuard ------------------------
iptables -t nat -N BERYL_DNS 2>/dev/null
iptables -t nat -F BERYL_DNS
iptables -t nat -A BERYL_DNS -p udp --dport 53 -j REDIRECT --to-ports "$AGH_PORT"
iptables -t nat -A BERYL_DNS -p tcp --dport 53 -j REDIRECT --to-ports "$AGH_PORT"
iptables -t nat -C PREROUTING -i "$LAN_IF" -j BERYL_DNS 2>/dev/null \
    || iptables -t nat -I PREROUTING 1 -i "$LAN_IF" -j BERYL_DNS

# --- 2. Blocage du DNS chiffré ------------------------------------------------------
iptables -N BERYL_DOH 2>/dev/null
iptables -F BERYL_DOH
iptables -A BERYL_DOH -p tcp --dport 853 -j REJECT --reject-with tcp-reset      # DNS-over-TLS
iptables -A BERYL_DOH -p udp --dport 853 -j REJECT                              # DNS-over-QUIC
for ip in $DOH_IPS; do
    iptables -A BERYL_DOH -d "$ip" -p tcp --dport 443 -j REJECT --reject-with tcp-reset
    iptables -A BERYL_DOH -d "$ip" -p udp --dport 443 -j REJECT
done
iptables -C FORWARD -i "$LAN_IF" -j BERYL_DOH 2>/dev/null \
    || iptables -I FORWARD 1 -i "$LAN_IF" -j BERYL_DOH

log "DNS forcé : redirection vers AdGuard et blocage du DNS chiffré actifs"
exit 0
