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
- [ ] Inventaire des appareils (nom, IP, MAC, fabricant)
- [ ] Présence en ligne / hors ligne
- [ ] Alerte « nouvel appareil »
- [ ] Tableau de bord web (réseau local uniquement)
- [ ] Stockage SQLite sur clé USB, service à démarrage automatique
- [ ] Liste blanche + accès au tableau de bord limité au PC d'administration + mot de passe

### V2 : trafic
- [ ] Bande passante par appareil
- [ ] Destinations par appareil (IP, domaines, pays)
- [ ] Graphiques
- [ ] Notifications Telegram

### V3 : DNS et confidentialité
- [ ] Historique DNS par appareil, catégories, filtrage
- [ ] DNS forcé
- [ ] Consentement, durée de conservation limitée

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

Shell (ash) · OpenWrt · SQLite · HTML/CSS/JavaScript · nftables
