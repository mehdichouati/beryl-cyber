#!/bin/sh
# Beryl CYBER : notifications Discord et approbation à distance par réaction.
#
# 1. Chaque nouvel appareil déclenche un message dans un salon Discord privé,
#    sur lequel le bot ajoute les réactions ✅ (approuver) et ⛔ (bloquer).
# 2. À chaque passage, le script relit les réactions des messages en attente :
#    seule une réaction de l'administrateur (DISCORD_ADMIN_ID) est prise en compte.
#
# Aucun port n'est ouvert : le routeur interroge l'API Discord (HTTPS sortant).
# Appelé par collect.sh après chaque collecte. Sans configuration Discord, ne fait rien.

CONF="${CONF:-/mnt/beryl/beryl-cyber/beryl-cyber.conf}"
[ -f "$CONF" ] && . "$CONF"
DATA_DIR="${DATA_DIR:-/mnt/beryl/beryl-cyber/data}"
DB="${DB:-$DATA_DIR/beryl.db}"
APP_DIR="${APP_DIR:-/mnt/beryl/beryl-cyber/app}"
API="https://discord.com/api/v10"
UA="DiscordBot (https://github.com/mehdichouati/beryl-cyber, 1.0)"
OK_EMOJI="%E2%9C%85"      # ✅
NO_EMOJI="%E2%9B%94"      # ⛔
EXPIRE_AFTER=86400        # une demande sans réponse expire après 24 h

numeric() { echo "$1" | grep -qE '^[0-9]{5,25}$'; }
[ -n "$DISCORD_TOKEN" ] && numeric "$DISCORD_CHANNEL_ID" && numeric "$DISCORD_ADMIN_ID" || exit 0
command -v curl >/dev/null 2>&1 || exit 0
command -v jsonfilter >/dev/null 2>&1 || exit 0

log() { logger -t beryl-cyber "discord: $*" 2>/dev/null; }
sql() { sqlite3 -separator '|' "$DB" "$1" 2>/dev/null; }

# Appel à l'API Discord : dc MÉTHODE CHEMIN [JSON]
dc() {
    if [ -n "$3" ]; then
        curl -sS -m 10 -X "$1" -H "Authorization: Bot $DISCORD_TOKEN" -H "User-Agent: $UA" \
             -H "Content-Type: application/json" --data "$3" "$API$2"
    else
        curl -sS -m 10 -X "$1" -H "Authorization: Bot $DISCORD_TOKEN" -H "User-Agent: $UA" \
             -H "Content-Length: 0" "$API$2"
    fi
}

post_message() { dc POST "/channels/$DISCORD_CHANNEL_ID/messages" "$1"; }

reply() {
    post_message "{\"content\":\"$2\",\"message_reference\":{\"message_id\":\"$1\"}}" >/dev/null
}

now="$(date +%s)"

# Point de départ : les événements antérieurs à l'activation ne sont pas notifiés
since="$(sql "SELECT value FROM meta WHERE key = 'discord_since';")"
if [ -z "$since" ]; then
    sql "INSERT OR REPLACE INTO meta (key, value) VALUES ('discord_since', '$now');"
    since="$now"
fi

# --- 1. Envoi des nouveaux appareils -------------------------------------------
if [ "$WHITELIST_ENABLED" = 1 ]; then
    access="Il n'a **pas accès à Internet** tant qu'il n'est pas approuvé."
else
    access="Il a accès à Internet (liste blanche inactive)."
fi

sql "SELECT e.id, e.mac, COALESCE(d.alias, d.hostname, 'Appareil inconnu'), COALESCE(d.last_ip, '?'), d.random_mac
     FROM events e JOIN devices d ON d.mac = e.mac
     WHERE e.type = 'new_device' AND e.ts >= $since
       AND e.id NOT IN (SELECT event_id FROM discord_messages)
     ORDER BY e.id LIMIT 5;" |
while IFS='|' read -r event_id mac name ip rnd; do
    extra=""; [ "$rnd" = 1 ] && extra=" (aléatoire)"
    content="🔔 **Nouvel appareil sur le réseau**\\n**Nom :** $name\\n**IP :** $ip\\n**MAC :** \`$mac\`$extra\\n$access\\n\\nRéagis ✅ pour **approuver** ou ⛔ pour **bloquer**."
    resp="$(post_message "{\"content\":\"$content\"}")"
    msg_id="$(echo "$resp" | jsonfilter -e '@.id' 2>/dev/null)"
    if ! numeric "$msg_id"; then
        log "envoi impossible : $(echo "$resp" | head -c 200)"
        break
    fi
    sql "INSERT INTO discord_messages (message_id, event_id, mac, created) VALUES ('$msg_id', $event_id, '$mac', $now);"
    # Réactions déjà posées par le bot : il suffit de toucher pour répondre
    dc PUT "/channels/$DISCORD_CHANNEL_ID/messages/$msg_id/reactions/$OK_EMOJI/@me" >/dev/null
    sleep 1
    dc PUT "/channels/$DISCORD_CHANNEL_ID/messages/$msg_id/reactions/$NO_EMOJI/@me" >/dev/null
    log "nouvel appareil notifié : $mac"
done

# --- 2. Lecture des réactions de l'administrateur --------------------------------
admin_reacted() {
    dc GET "/channels/$DISCORD_CHANNEL_ID/messages/$1/reactions/$2?limit=100" \
        | jsonfilter -e '@[*].id' 2>/dev/null | grep -qx "$DISCORD_ADMIN_ID"
}

sql "UPDATE discord_messages SET state = 'expired' WHERE state = 'open' AND created < $((now - EXPIRE_AFTER));"

sql "SELECT m.message_id, m.mac, COALESCE(d.alias, d.hostname, m.mac)
     FROM discord_messages m JOIN devices d ON d.mac = m.mac
     WHERE m.state = 'open';" |
while IFS='|' read -r msg_id mac name; do
    decision=""
    if admin_reacted "$msg_id" "$NO_EMOJI"; then
        decision="blocked"          # en cas de double réaction, le blocage l'emporte
    elif admin_reacted "$msg_id" "$OK_EMOJI"; then
        decision="approved"
    fi
    [ -n "$decision" ] || continue

    sql "BEGIN;
         UPDATE devices SET status = '$decision' WHERE mac = '$mac';
         INSERT INTO events (ts, mac, type, detail) VALUES ($now, '$mac', '$decision', 'via Discord');
         UPDATE discord_messages SET state = '$decision' WHERE message_id = '$msg_id';
         COMMIT;"
    [ -x "$APP_DIR/router/bin/whitelist.sh" ] && "$APP_DIR/router/bin/whitelist.sh" "$mac" >/dev/null 2>&1

    if [ "$decision" = approved ]; then
        reply "$msg_id" "✅ **$name** approuvé."
    else
        reply "$msg_id" "⛔ **$name** bloqué."
    fi
    log "$mac : $decision via Discord"
done
