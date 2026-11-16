-- Beryl CYBER : schéma de la base SQLite (V1)
-- Dates stockées en secondes Unix (INTEGER) : simple à produire avec `date +%s`
-- et facile à comparer.

PRAGMA journal_mode = WAL;     -- lecture (tableau de bord) et écriture (collecte) en même temps
PRAGMA foreign_keys = ON;

-- Version du schéma, pour les futures migrations
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', '1');

-- Inventaire : une ligne par appareil, identifié par son adresse MAC
CREATE TABLE IF NOT EXISTS devices (
    mac         TEXT PRIMARY KEY,            -- aa:bb:cc:dd:ee:ff (minuscules)
    hostname    TEXT,                        -- nom annoncé par l'appareil (DHCP)
    alias       TEXT,                        -- nom choisi dans le tableau de bord
    vendor      TEXT,                        -- fabricant (préfixe OUI de la MAC)
    random_mac  INTEGER NOT NULL DEFAULT 0,  -- 1 si MAC aléatoire (bit « local » activé)
    last_ip     TEXT,
    status      TEXT NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'approved', 'blocked')),  -- liste blanche
    online      INTEGER NOT NULL DEFAULT 0,  -- 1 = en ligne
    first_seen  INTEGER NOT NULL,
    last_seen   INTEGER NOT NULL
);

-- Historique de présence : une ligne par période de connexion
-- (plutôt qu'une ligne par minute, pour économiser la clé USB)
CREATE TABLE IF NOT EXISTS sessions (
    id        INTEGER PRIMARY KEY,
    mac       TEXT NOT NULL REFERENCES devices(mac) ON DELETE CASCADE,
    ip        TEXT,
    start_ts  INTEGER NOT NULL,
    end_ts    INTEGER                        -- NULL = session en cours
);
CREATE INDEX IF NOT EXISTS idx_sessions_mac   ON sessions (mac, start_ts);
CREATE INDEX IF NOT EXISTS idx_sessions_open  ON sessions (end_ts) WHERE end_ts IS NULL;

-- Événements : alimente les alertes et le journal du tableau de bord
CREATE TABLE IF NOT EXISTS events (
    id    INTEGER PRIMARY KEY,
    ts    INTEGER NOT NULL,
    mac   TEXT REFERENCES devices(mac) ON DELETE SET NULL,
    type  TEXT NOT NULL
          CHECK (type IN ('new_device', 'online', 'offline', 'ip_change',
                          'approved', 'blocked', 'renamed')),
    detail TEXT,
    seen  INTEGER NOT NULL DEFAULT 0         -- 0 = alerte non lue
);
CREATE INDEX IF NOT EXISTS idx_events_ts      ON events (ts);
CREATE INDEX IF NOT EXISTS idx_events_unseen  ON events (seen) WHERE seen = 0;

-- Notifications Discord : un message par nouvel appareil, en attente d'une réaction
CREATE TABLE IF NOT EXISTS discord_messages (
    message_id  TEXT PRIMARY KEY,               -- identifiant du message Discord
    event_id    INTEGER UNIQUE,                 -- événement "new_device" notifié
    mac         TEXT NOT NULL,
    created     INTEGER NOT NULL,
    state       TEXT NOT NULL DEFAULT 'open'
                CHECK (state IN ('open', 'approved', 'blocked', 'expired'))
);
CREATE INDEX IF NOT EXISTS idx_discord_open ON discord_messages (state) WHERE state = 'open';

-- Consommation par appareil et par jour (octets)
CREATE TABLE IF NOT EXISTS traffic (
    mac  TEXT NOT NULL REFERENCES devices(mac) ON DELETE CASCADE,
    day  TEXT NOT NULL,                     -- AAAA-MM-JJ (heure locale)
    rx   INTEGER NOT NULL DEFAULT 0,        -- reçu par l'appareil (téléchargement)
    tx   INTEGER NOT NULL DEFAULT 0,        -- envoyé par l'appareil (envoi)
    PRIMARY KEY (mac, day)
);
CREATE INDEX IF NOT EXISTS idx_traffic_day ON traffic (day);

-- Destinations : vers où chaque appareil envoie ses données (par jour)
CREATE TABLE IF NOT EXISTS destinations (
    mac    TEXT NOT NULL REFERENCES devices(mac) ON DELETE CASCADE,
    day    TEXT NOT NULL,                   -- AAAA-MM-JJ
    ip     TEXT NOT NULL,                   -- adresse distante
    proto  TEXT NOT NULL,                   -- tcp / udp
    port   INTEGER NOT NULL,                -- port distant (443 = HTTPS...)
    rx     INTEGER NOT NULL DEFAULT 0,      -- reçu de cette destination
    tx     INTEGER NOT NULL DEFAULT 0,      -- envoyé vers cette destination
    conns  INTEGER NOT NULL DEFAULT 0,      -- nombre de connexions
    PRIMARY KEY (mac, day, ip, proto, port)
);
CREATE INDEX IF NOT EXISTS idx_dest_day ON destinations (day);

-- Informations sur les adresses distantes (pays, opérateur), mises en cache
CREATE TABLE IF NOT EXISTS ip_info (
    ip       TEXT PRIMARY KEY,
    country  TEXT,                          -- code pays ISO (FR, US...)
    asn      INTEGER,                       -- numéro de système autonome
    org      TEXT,                          -- organisation (Google LLC, Meta...)
    updated  INTEGER NOT NULL
);

-- Historique DNS : noms de domaine demandés par appareil et par jour (V3)
-- Conservé 7 jours. Les appareils marqués "privés" ne sont pas historisés.
CREATE TABLE IF NOT EXISTS dns_queries (
    mac      TEXT NOT NULL REFERENCES devices(mac) ON DELETE CASCADE,
    day      TEXT NOT NULL,                 -- AAAA-MM-JJ
    domain   TEXT NOT NULL,
    count    INTEGER NOT NULL DEFAULT 0,    -- nombre de requêtes
    blocked  INTEGER NOT NULL DEFAULT 0,    -- dont bloquées (publicité, pistage)
    last_ts  INTEGER NOT NULL,
    PRIMARY KEY (mac, day, domain)
);
CREATE INDEX IF NOT EXISTS idx_dns_day ON dns_queries (day);

-- Correspondance adresse IP -> nom de domaine, par appareil (V3)
-- Tirée des réponses DNS (enregistrements A) du journal AdGuard. Permet de dire quel site
-- se cache derrière une destination (par exemple, quel site derrière une IP Cloudflare).
-- Conservée 7 jours, comme l'historique DNS ; jamais pour un appareil "privé".
CREATE TABLE IF NOT EXISTS dns_ip (
    mac      TEXT NOT NULL REFERENCES devices(mac) ON DELETE CASCADE,
    ip       TEXT NOT NULL,
    domain   TEXT NOT NULL,
    last_ts  INTEGER NOT NULL,
    PRIMARY KEY (mac, ip)
);
