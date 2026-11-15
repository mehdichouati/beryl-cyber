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
