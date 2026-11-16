# Architecture

## Topologie

```
Internet ── Box Orange (rez) ══ câble mural ══ Beryl AX (2e étage) ── Wi-Fi ── appareils supervisés
                  └─ Wi-Fi de la box : appareils non supervisés
```

Le Beryl fonctionne en **mode routeur** : son propre sous-réseau (192.168.8.0/24), son propre
DHCP et du NAT. Il voit donc tout le trafic des appareils qui lui sont connectés, et seulement eux.

## Matériel

| Élément | Valeur |
|---|---|
| Routeur | GL.iNet Beryl AX (GL-MT3000) |
| Système | OpenWrt 21.02 (firmware GL.iNet 4.x), noyau Linux 5.4, BusyBox 1.33 |
| Processeur | MediaTek MT7981, 2 cœurs ARM Cortex-A53 |
| RAM | 512 Mo |
| Stockage des données | Clé USB 16 Go, ext4, label `beryl` |

## Vue d'ensemble

```
                         ┌──────────────── Routeur Beryl AX ────────────────┐
  Appareils ── Wi-Fi ──▶ │  noyau : ARP · DHCP · conntrack · iptables        │
                         │      │                                            │
                         │      ▼  toutes les 60 s (service procd)           │
                         │  collect.sh ─▶ traffic.sh ─▶ destinations.sh      │
                         │      │          maintenance.sh   notify.sh ───────┼──▶ API Discord
                         │      ▼                                            │      (HTTPS sortant)
                         │  SQLite (clé USB) : beryl.db  +  geo.db           │
                         │      ▲                                            │
                         │  uhttpd :8080 ─ api.sh (lecture) / action.sh      │
                         └──────┼────────────────────────────────────────────┘
                                ▼  pare-feu : PC d'administration uniquement + mot de passe
                         Tableau de bord (HTML/JS, graphiques SVG, carte)
```

## Composants

| Fichier | Rôle |
|---|---|
| `router/bin/launch.sh` | Attend la clé USB, recrée le raccourci `/mnt/beryl`, applique la liste blanche, lance la collecte |
| `router/bin/collect.sh` | Boucle principale : appareils (ARP + DHCP), présence, fabricant (OUI), puis appelle les autres modules |
| `router/bin/traffic.sh` | Octets envoyés/reçus par appareil (chaîne iptables `BERYL_ACCT`, compteurs lus et remis à zéro chaque minute) |
| `router/bin/destinations.sh` | Destinations par appareil depuis conntrack, enrichies (pays, organisation) en SQL dans `geo.db` |
| `router/bin/whitelist.sh` | Liste blanche et blocages (chaîne iptables `BERYL_WL`), coupure des connexions en cours via conntrack |
| `router/bin/notify.sh` | Alerte Discord pour chaque nouvel appareil, approbation ou blocage par réaction ✅ / ⛔ |
| `router/bin/dns.sh` | Historique DNS par appareil, lu dans le journal d'AdGuard Home (fichier sur la clé, lecture incrémentale) |
| `router/bin/adguard-setup.sh` | Réglages d'AdGuard : journal 24 h écrit sur la clé, interface (port 3000) réservée au PC d'administration |
| `router/bin/dns-force.sh` | DNS forcé : tout le port 53 du LAN redirigé vers AdGuard, DNS-over-TLS/HTTPS bloqué ; retiré automatiquement si AdGuard s'arrête |
| `router/bin/maintenance.sh` | Mise à jour mensuelle des bases DB-IP et OUI, renouvellement du cache d'adresses |
| `router/bin/firewall.sh` | Bail DHCP fixe et règles d'accès au port 8080 pour le PC d'administration |
| `router/install.sh` | Installation idempotente ; protège le service des mises à jour du firmware (`/etc/sysupgrade.conf`) |
| `web/cgi-bin/api.sh` | API JSON en lecture seule (requêtes choisies dans une liste fixe) |
| `web/cgi-bin/action.sh` | API d'écriture : renommer, approuver, bloquer |
| `deploy.sh` / `backup.sh` | Côté PC : déploiement en une commande, sauvegarde mensuelle de la base |

## Base de données (SQLite, mode WAL)

| Table | Contenu | Conservation |
|---|---|---|
| `devices` | Inventaire : MAC, nom, alias, fabricant, statut liste blanche | permanente |
| `sessions` | Périodes de connexion (une ligne par session, pas par minute) | permanente |
| `events` | Nouvel appareil, en ligne, hors ligne, changement d'IP, approuvé, bloqué | permanente |
| `traffic` | Octets reçus/envoyés par appareil et par jour | permanente (très petite) |
| `destinations` | Destinations par appareil et par jour (IP, port, volume, connexions) | 30 jours |
| `dns_queries` | Domaines demandés par appareil et par jour (requêtes, dont bloquées) ; jamais pour un appareil « privé » | 7 jours |
| `ip_info` | Cache pays / organisation par adresse | renouvelé tous les 30 jours |
| `discord_messages` | Alertes en attente de réaction | expirent après 24 h |

`geo.db` (séparée) contient les plages DB-IP, indexées sur leur début.

## Sécurité

| Couche | Mesure |
|---|---|
| Réseau | Wi-Fi WPA2/WPA3 ; liste blanche : seuls les appareils approuvés accèdent à Internet |
| Accès au tableau de bord | Écoute sur l'IP LAN uniquement ; pare-feu limité au PC d'administration (MAC + IP) |
| Authentification | HTTP Basic, mot de passe stocké sous forme d'empreinte (`/etc/beryl-cyber/httpd.conf`, root uniquement) ; sans mot de passe, le tableau de bord ne démarre pas (*fail-closed*) |
| Écriture | POST uniquement, `Content-Type` dédié (protection CSRF), vérification de l'origine |
| Entrées | MAC, IP et noms validés ou filtrés avant tout SQL ; affichage par `textContent` (anti-XSS) |
| Accès SSH | Clé ed25519 depuis le PC |
| Secrets | Jeton Discord dans la configuration sur la clé (`chmod 600`), jamais dans le dépôt |
| Discord | Aucun port ouvert (requêtes sortantes) ; seules les réactions de l'administrateur comptent |
| DNS | Filtrage publicités/pistage (AdGuard Home) ; DNS forcé ; interface AdGuard limitée au PC et protégée par l'authentification GL.iNet |

## Choix techniques mesurés

- **Accélération matérielle désactivée.** Le HNAT MediaTek fait passer les paquets à côté du
  pare-feu : ils ne sont alors ni comptés, ni visibles. Mesures : 86 Mbps avec, 90 Mbps sans,
  processeur à 80 % inactif à pleine charge. La connexion (≈ 100 Mbps) reste le facteur limitant.
- **Recherche géographique en SQL plutôt qu'en awk.** Voir les incidents ci-dessous.
- **Sessions plutôt qu'une ligne par minute** : quelques centaines de lignes par an au lieu de
  plusieurs centaines de milliers, et moins d'écritures sur la clé.
- **Graphiques et carte dessinés en SVG**, sans bibliothèque ni ressource externe : le tableau de
  bord fonctionne sans Internet et ne divulgue rien à un tiers.
- **Données sur la clé, service sur la flash** : la flash n'est jamais usée par les écritures, et le
  service démarre avant que la clé soit montée (le lanceur l'attend).

## Incidents résolus

| Symptôme | Cause | Correction |
|---|---|---|
| Service disparu après une nuit | Mise à jour du firmware : fichiers ajoutés effacés | `install.sh` + ajout à `/etc/sysupgrade.conf` |
| « collecte : ARRÊTÉE » alors qu'elle tournait | Sans terminal, `ps` (BusyBox) coupe les lignes à 80 caractères | Détection via `/proc/*/cmdline` |
| Base des fabricants vide | `awk -F '\t'` interprété différemment selon la version | Analyse indépendante du séparateur |
| Plages géographiques fausses | `awk` (BusyBox) écrit les grands nombres en notation scientifique | `printf "%.0f"` |
| Organisations fausses par lots | Comparaisons texte au lieu de numériques dans `awk` | Recherche déplacée dans SQLite |
| Organisations « inconnues » | Concurrence : base des organisations encore en téléchargement | Recherche seulement quand les deux bases sont prêtes, nouvel essai après 1 h |
| iPad bloqué mais navigue | L'iPad utilisait le Wi-Fi de la box (compteur du pare-feu à 0) | Vérifier le chemin du trafic avant d'accuser le filtre |
| Journal DNS impossible à lire | API AdGuard protégée par GL.iNet (401), journal en mémoire seulement | Journal écrit dans un fichier sur la clé, lu directement |
| Appareils contournant AdGuard | GL.iNet ne redirige que le DNS adressé au routeur (`--dst-type LOCAL`) | Redirection de tout le port 53 + blocage du DNS chiffré |
| Nom du PC remplacé | Le nom du bail DHCP statique écrasait celui du PC | Bail sans option `name` |

## Vie privée

Les destinations et surtout l'historique DNS révèlent les habitudes des personnes connectées.
Le projet applique les principes du RGPD :

- **Minimisation** : jamais le contenu des échanges (HTTPS) ; seulement domaines, destinations, volumes.
- **Conservation limitée** : historique DNS 7 jours, destinations 30 jours, journal AdGuard 24 h.
- **Droit d'opposition et d'effacement** : un appareil « privé » n'est plus historisé et son
  historique est effacé immédiatement ; il reste protégé par le filtrage.
- **Accès restreint** : poste d'administration uniquement, avec mot de passe.
- **Transparence** : les occupants sont informés de la supervision.
