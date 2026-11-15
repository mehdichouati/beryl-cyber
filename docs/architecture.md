# Architecture

## Topologie

```
Internet ── Box Orange (rez) ══ câble mural ══ Beryl AX (2e étage) ── Wi-Fi ── appareils supervisés
```

Le Beryl fonctionne en mode routeur : il a son propre sous-réseau (192.168.8.0/24),
son propre DHCP et fait du NAT. Seuls les appareils connectés au Beryl sont supervisés.

## Matériel

| Élément | Valeur |
|---|---|
| Routeur | GL.iNet Beryl AX (GL-MT3000) |
| Système | OpenWrt 21.02 (firmware GL.iNet), noyau 5.4 |
| Processeur | MediaTek MT7981, ARM 64 bits |
| RAM | 512 Mo |
| Stockage des données | Clé USB 16 Go, ext4, label `beryl` |

## Logiciel : trois couches

| Couche | Technologie | Rôle |
|---|---|---|
| Collecte | Script shell (ash), toutes les 60 s | Lit les baux DHCP et la table de voisinage |
| Stockage | SQLite sur clé USB | Inventaire, historique de présence, événements |
| Affichage | Page HTML/JS + CGI JSON | Tableau de bord accessible uniquement depuis le PC d'administration |

## Principes

- **Le Wi-Fi d'abord** : chaque choix est mesuré. L'accélération matérielle (MediaTek HNAT) a été
  désactivée pour permettre le comptage du trafic : speedtest 86 Mbps avant, 90 Mbps après, processeur
  à 80 % inactif à pleine charge. La connexion (≈ 100 Mbps) reste le facteur limitant, pas le routeur.
- **Rien sur la flash interne** : toutes les données vont sur la clé USB.
- **Réinstallable** : un script d'installation remet tout en place après une mise à jour du firmware.
- **Vie privée** : données minimales, durée de conservation limitée, accès restreint.
