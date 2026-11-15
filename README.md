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
- [ ] Bande passante par appareil
- [ ] Destinations par appareil (IP, domaines, pays)
- [ ] Graphiques
- [x] Notifications Discord et approbation à distance par réaction

### V3 : DNS et confidentialité
- [ ] Historique DNS par appareil, catégories, filtrage
- [ ] DNS forcé
- [ ] Consentement, durée de conservation limitée

## Installation

Prérequis : routeur GL.iNet sous OpenWrt, clé USB formatée en ext4 avec le label `beryl`,
accès SSH par clé à l'hôte `beryl` (voir `~/.ssh/config`).

```sh
./deploy.sh                                   # depuis le PC : copie et installe
ssh -t beryl sh /mnt/beryl/beryl-cyber/app/router/bin/set-password.sh   # mot de passe du tableau de bord
```

La configuration (poste d'administration, liste blanche, Discord) se trouve sur la clé :
`/mnt/beryl/beryl-cyber/beryl-cyber.conf` (modèle : `config/beryl-cyber.conf.example`).

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

- [Architecture](docs/architecture.md)

## Stack

Shell (ash) · OpenWrt · SQLite · HTML/CSS/JavaScript · iptables · uhttpd · procd
