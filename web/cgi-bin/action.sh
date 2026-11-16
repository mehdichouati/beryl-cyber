#!/bin/sh
# Beryl CYBER : actions du tableau de bord (écriture)
#
#   POST /cgi-bin/action.sh   corps : action=...&mac=...&value=...
#     action=status  value=approved|blocked|pending   statut d'un appareil (liste blanche)
#     action=rename  value=<nom>                      nom affiché (vide = nom d'origine)
#     action=private value=0|1                        appareil privé (pas d'historique DNS)
#     action=seen                                     marque toutes les alertes comme lues
#
# Protections :
#   - accès déjà limité par le pare-feu et le mot de passe (uhttpd)
#   - POST uniquement, avec un Content-Type propre au projet : un site tiers ne peut pas
#     l'envoyer sans requête préalable CORS, que ce script refuse (protection CSRF)
#   - toutes les valeurs sont validées ou filtrées avant d'entrer dans le SQL

DB="${DB:-/mnt/beryl/beryl-cyber/data/beryl.db}"
APP_DIR="${APP_DIR:-/mnt/beryl/beryl-cyber/app}"
CTYPE="application/x-beryl-form"

reply() {
    printf 'Status: %s\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\n\r\n%s\n' "$1" "$2"
    exit 0
}

[ "$REQUEST_METHOD" = "POST" ] || reply "405 Method Not Allowed" '{"error":"POST uniquement"}'
[ "$CONTENT_TYPE" = "$CTYPE" ] || reply "415 Unsupported Media Type" '{"error":"type de contenu refusé"}'

# Si le navigateur indique l'origine, elle doit être le tableau de bord lui-même
if [ -n "$HTTP_ORIGIN" ] && [ "$HTTP_ORIGIN" != "http://$HTTP_HOST" ]; then
    reply "403 Forbidden" '{"error":"origine refusée"}'
fi

len="${CONTENT_LENGTH:-0}"
case "$len" in ''|*[!0-9]*) len=0 ;; esac
[ "$len" -gt 0 ] && [ "$len" -le 1024 ] || reply "400 Bad Request" '{"error":"requête invalide"}'
body="$(head -c "$len")"

# Lecture d'un champ du formulaire, avec décodage des %XX et des +
field() {
    v="$(printf '%s' "$body" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1)"
    v="$(printf '%s' "$v" | sed 's/+/ /g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"
    printf '%b' "$v"
}

action="$(field action)"
mac="$(field mac | tr 'A-F' 'a-f')"
value="$(field value)"

valid_mac() { echo "$1" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; }

sql() { sqlite3 "$DB" "PRAGMA foreign_keys = ON; $1" 2>/dev/null; }

device_exists() { [ "$(sql "SELECT COUNT(*) FROM devices WHERE mac = '$1';")" = "1" ]; }

now="$(date +%s)"

case "$action" in
    status)
        valid_mac "$mac" && device_exists "$mac" || reply "404 Not Found" '{"error":"appareil inconnu"}'
        case "$value" in approved|blocked|pending) ;; *) reply "400 Bad Request" '{"error":"statut invalide"}' ;; esac
        ev=""
        [ "$value" = "approved" ] && ev="INSERT INTO events (ts, mac, type) VALUES ($now, '$mac', 'approved');"
        [ "$value" = "blocked" ]  && ev="INSERT INTO events (ts, mac, type) VALUES ($now, '$mac', 'blocked');"
        sql "BEGIN; UPDATE devices SET status = '$value' WHERE mac = '$mac'; $ev COMMIT;" \
            || reply "500 Internal Server Error" '{"error":"écriture impossible"}'
        # Application immédiate au pare-feu (liste blanche), si le module est installé
        [ -x "$APP_DIR/router/bin/whitelist.sh" ] && "$APP_DIR/router/bin/whitelist.sh" "$mac" >/dev/null 2>&1
        ;;
    rename)
        valid_mac "$mac" && device_exists "$mac" || reply "404 Not Found" '{"error":"appareil inconnu"}'
        # Caractères dangereux retirés (guillemets, ; \ < > ` $ et caractères de contrôle), 40 octets max
        alias="$(printf '%s' "$value" | tr -d "\"';\\\\<>\`\$" | tr -d '\000-\037' | head -c 40)"
        if [ -z "$alias" ]; then
            sql "UPDATE devices SET alias = NULL WHERE mac = '$mac';"
        else
            sql "BEGIN; UPDATE devices SET alias = '$alias' WHERE mac = '$mac';
                 INSERT INTO events (ts, mac, type, detail) VALUES ($now, '$mac', 'renamed', '$alias'); COMMIT;"
        fi || reply "500 Internal Server Error" '{"error":"écriture impossible"}'
        ;;
    private)
        # Appareil privé : plus d'historique DNS, et l'historique existant est effacé
        valid_mac "$mac" && device_exists "$mac" || reply "404 Not Found" '{"error":"appareil inconnu"}'
        case "$value" in
            1) sql "BEGIN; UPDATE devices SET private = 1 WHERE mac = '$mac'; DELETE FROM dns_queries WHERE mac = '$mac'; DELETE FROM dns_ip WHERE mac = '$mac'; COMMIT;" ;;
            0) sql "UPDATE devices SET private = 0 WHERE mac = '$mac';" ;;
            *) reply "400 Bad Request" '{"error":"valeur invalide"}' ;;
        esac || reply "500 Internal Server Error" '{"error":"écriture impossible"}'
        ;;
    seen)
        sql "UPDATE events SET seen = 1 WHERE seen = 0;" \
            || reply "500 Internal Server Error" '{"error":"écriture impossible"}'
        ;;
    *)
        reply "400 Bad Request" '{"error":"action inconnue"}'
        ;;
esac

reply "200 OK" '{"ok":true}'
