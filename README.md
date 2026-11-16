# Beryl CYBER

Supervision du réseau domestique sur un routeur **GL.iNet Beryl AX (OpenWrt)** :
inventaire des appareils, historique de présence, alertes et tableau de bord web local.

## Objectifs

- Savoir **quels appareils** sont connectés au réseau, et depuis quand
- Être alerté quand un **appareil inconnu** se connecte
- N'autoriser que les **appareils approuvés** (liste blanche)
- Garder un **Wi-Fi rapide** : la supervision ne doit jamais ralentir le réseau

## Feuille de route

### V1 : inventaire et contrôle d'accès
- [x] Inventaire des appareils (nom, IP, MAC, fabricant)
- [x] Présence en ligne / hors ligne, historique des connexions
- [x] Alerte « nouvel appareil »
- [x] Tableau de bord web : renommer, approuver, bloquer
- [x] Stockage SQLite sur clé USB, service à démarrage automatique
- [x] Déploiement en une commande, résistant aux mises à jour du firmware
- [x] Tableau de bord limité au poste d'administration (pare-feu) + mot de passe
- [x] Liste blanche dans le pare-feu (iptables)

### V2 : trafic et notifications
- [x] Bande passante par appareil
- [x] Destinations par appareil (organisation, pays, service)
- [x] Graphiques (consommation sur 30 jours, par appareil, principales destinations)
- [x] Carte du monde des pays contactés
- [x] Notifications Discord et approbation à distance par réaction

### V3 : DNS et confidentialité
- [x] Historique DNS par appareil (AdGuard Home), conservé 7 jours
- [x] Filtrage des publicités et du pistage pour toute la maison
- [x] Mode « appareil privé » : pas d'historique, effacement de l'existant
- [x] DNS forcé (redirection de tout le DNS, blocage du DNS chiffré)
- [ ] Information des occupants

## Installation

Prérequis : routeur GL.iNet sous OpenWrt, clé USB formatée en ext4 avec le label `beryl`,
accès SSH par clé à l'hôte `beryl` (voir `~/.ssh/config`).

```sh
./deploy.sh                                   # depuis le PC : copie et installe
ssh -t beryl sh /mnt/beryl/beryl-cyber/app/router/bin/set-password.sh   # mot de passe du tableau de bord
```

La configuration (poste d'administration, liste blanche, Discord) se trouve sur la clé :
`/mnt/beryl/beryl-cyber/beryl-cyber.conf` (modèle : `config/beryl-cyber.conf.example`).

## Sauvegarde

`backup.sh` (Git Bash, sur le PC) copie la base du routeur dans `~/beryl-backups`, hors du dépôt.
Lancé chaque jour par le Planificateur de tâches Windows, il ne sauvegarde que tous les 30 jours,
garde les 12 dernières copies et compacte la base sur la clé.

Restauration :
```sh
gunzip -c ~/beryl-backups/beryl-AAAA-MM-JJ.db.gz > beryl.db
scp -O beryl.db beryl:/tmp/ && ssh beryl "/etc/init.d/beryl-cyber stop && rm -f /mnt/beryl/beryl-cyber/data/beryl.db-wal /mnt/beryl/beryl-cyber/data/beryl.db-shm && cp /tmp/beryl.db /mnt/beryl/beryl-cyber/data/beryl.db && /etc/init.d/beryl-cyber start"
```

## Sécurité

| Couche | Rôle |
|---|---|
| Wi-Fi WPA2/WPA3 | Première barrière d'accès au réseau |
| Pare-feu (port 8080) | Seul le poste d'administration (MAC + IP) atteint le tableau de bord |
| Authentification HTTP | Mot de passe stocké sous forme d'empreinte uniquement |
| API d'écriture | POST uniquement, Content-Type dédié (anti-CSRF), entrées validées |
| Liste blanche | Seuls les appareils approuvés accèdent à Internet |

## Structure du dépôt

```
router/bin/      scripts exécutés sur le routeur
router/init.d/   service de démarrage (procd)
sql/             schéma de la base SQLite
web/             tableau de bord
config/          exemple de configuration
docs/            documentation (architecture, choix techniques)
```

## Documentation

- [Architecture, sécurité, choix techniques et incidents résolus](docs/architecture.md)

## Stack

Shell (ash) · OpenWrt · SQLite · HTML/CSS/JavaScript · iptables · conntrack · uhttpd · procd · API Discord
