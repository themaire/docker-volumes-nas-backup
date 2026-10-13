# backup_docker_volumes

Sauvegarde et restauration des volumes Docker **et des données d'application en bind
mount** (ex : `/DATA/AppData/<app>` sous CasaOS) d'une machine vers un
NAS ou serveur distant, via SSH/rsync. Les conteneurs concernés sont arrêtés le temps de la
sauvegarde ou de la restauration, pour garantir des données cohérentes.

> ⚠️ Beaucoup d'applications (CasaOS notamment : Hermes, Immich, Home Assistant,
> Jellyfin...) ne stockent **pas** leurs données dans un volume Docker nommé mais dans
> un simple dossier de l'hôte monté en bind mount (visible via `docker inspect
> <conteneur>`, `Mounts[].Type == "bind"`). Sans `APPDATA_PATH_PREFIX` configuré, ces
> données ne sont PAS couvertes par la sauvegarde.

## Fichiers

| Fichier                          | Rôle                                                          |
|-----------------------------------|----------------------------------------------------------------|
| `backup-docker-volumes.sh`        | Sauvegarde des volumes vers le NAS                             |
| `restore-docker-volumes.sh`       | Restauration des volumes depuis le NAS                         |
| `docker-backup.conf.example`      | Modèle de configuration                                        |
| `docker-backup.conf`              | Configuration réelle (non versionnée si le dépôt est public)   |

## Prérequis

- `docker`, `ssh`, `rsync` installés localement.
- Une clé SSH déclarée sur le NAS/serveur distant, sans mot de passe (connexion en `BatchMode`).
- L'utilisateur courant doit pouvoir exécuter `docker` (groupe `docker`).

## Configuration

Copier `docker-backup.conf.example` en `docker-backup.conf` (même dossier) et l'adapter :

```bash
cp docker-backup.conf.example docker-backup.conf
```

| Variable          | Description                                                              |
|-------------------|----------------------------------------------------------------------------|
| `NAS_USER`        | Utilisateur SSH sur le NAS                                                |
| `NAS_HOST`        | Adresse du NAS                                                            |
| `NAS_SSH_PORT`    | Port SSH (défaut : 22)                                                    |
| `NAS_SSH_KEY`     | Chemin vers la clé privée SSH                                             |
| `NAS_BACKUP_PATH` | Dossier distant où stocker les sauvegardes                                |
| `LOCAL_TMP_DIR`   | Dossier local temporaire (avant transfert vers le NAS)                    |
| `RETENTION_COUNT` | Nombre de sauvegardes à conserver, les plus récentes (local + NAS)        |
| `LOG_FILE`        | Fichier de log                                                            |
| `EXCLUDE_VOLUMES` | Volumes à exclure en mode `ALL` (séparés par des espaces)                 |
| `APPDATA_PATH_PREFIX` | Préfixe hôte des données d'application à sauvegarder en plus des volumes Docker (ex : `/DATA/AppData`). Vide = désactivé. |
| `EXCLUDE_APPDATA` | Clés à exclure en mode `ALL` (chemin relatif à `APPDATA_PATH_PREFIX`, `/` → `__`, séparées par des espaces) |
| `NOTIFY_CMD`      | Commande shell de notification en cas d'échec (optionnel), message en `"$1"`. Entre guillemets simples, ex : `NOTIFY_CMD='curl -s -d "$1" https://ntfy.sh/mon-sujet'` |
| `ALPINE_IMAGE`    | Image utilisée pour tar/untar les volumes (défaut : `alpine:3.20`, épinglée plutôt que `latest` pour rester reproductible et ne pas dépendre d'un accès à Docker Hub au moment du backup — pensez à la pré-tirer avec `docker pull`) |

Exemple de config :

- NAS : `tatampion@192.168.1.192:28` (alias SSH `nomDeVotreServeur`, voir `~/.ssh/config`)
- Destination : `/VotreChemin/distant/backup_docker_volumes/nomDeVotreServeur/`
- Tmp local & logs : `/home/notreNom/.local/state/docker-volume-backup/`
- `APPDATA_PATH_PREFIX="/DATA/AppData"` (convention CasaOS)

## Sauvegarde

```bash
./backup-docker-volumes.sh ALL                      # tous les volumes Docker
./backup-docker-volumes.sh mon_conteneur             # volumes nommés utilisés par ce conteneur
./backup-docker-volumes.sh conteneur1 conteneur2     # plusieurs conteneurs
```

- Sans argument : affiche l'aide et quitte (code 1). `ALL` doit être tapé explicitement
  pour traiter tous les volumes — aucun comportement "par défaut" implicite.
- **Sauvegarde par groupe, pas d'arrêt global.** Le script ne fait pas "arrêter tous les
  conteneurs concernés → tout sauvegarder → tout redémarrer". Il regroupe les conteneurs
  qui partagent un même volume/dossier (union-find), puis traite groupe par groupe :
  arrêt du groupe → tar de ses volumes/dossiers → redémarrage immédiat → groupe suivant.
  Un conteneur dont la sauvegarde prend 1 seconde n'est donc jamais retenu à l'arrêt
  parce qu'un autre conteneur, ailleurs dans la liste, met 5 minutes. En mode `ALL`, les
  volumes Docker orphelins (aucun conteneur, running ou non, ne les monte) sont
  sauvegardés en tout dernier, sans arrêter quoi que ce soit (rien ne peut les modifier).
- En mode conteneur(s), seuls les volumes nommés **et** bind mounts sous
  `APPDATA_PATH_PREFIX` des conteneurs listés sont concernés (pas ceux du reste de la
  machine, contrairement à `ALL`).
- Chaque volume/dossier est archivé en `.tar.gz` (préfixe `appdata__` pour les données
  d'application, pour les distinguer des volumes Docker), **vérifié immédiatement**
  (`tar tzf`, sans extraction — détecte une archive tronquée/corrompue tout de suite
  plutôt qu'au moment d'une restauration), puis transféré en une fois vers
  `NAS_BACKUP_PATH/<horodatage>/` sur le NAS une fois **tous** les groupes sauvegardés
  (donc après que tous les conteneurs sont déjà repartis). Seules les `RETENTION_COUNT`
  sauvegardes les plus récentes sont ensuite conservées (locales et distantes, triées
  par nom de dossier — pas par âge en jours, pour un nombre fixe même avec des runs
  espacés ou manuels).
- **Sauvegarde partielle** : si un volume/dossier échoue, le reste est quand même envoyé,
  mais dans `NAS_BACKUP_PATH/<horodatage>_incomplet/` (et une notification est envoyée).
  Ces dossiers ne comptent pas dans la rétention, pour qu'une série de nuits ratées ne
  fasse pas disparaître les dernières sauvegardes complètes ; chacun est supprimé dès
  qu'une sauvegarde complète plus récente existe.

## Restauration

```bash
./restore-docker-volumes.sh --list                   # lister les sauvegardes disponibles sur le NAS
./restore-docker-volumes.sh ALL                       # restaurer tous les volumes de la sauvegarde la plus récente
./restore-docker-volumes.sh mon_conteneur             # restaurer les volumes de ce conteneur
./restore-docker-volumes.sh --timestamp 2026-08-18_21-30-00 mon_conteneur
./restore-docker-volumes.sh --volume mon_volume --yes # par nom de volume direct (conteneur disparu)
./restore-docker-volumes.sh --path /DATA/AppData/hermes --yes  # par chemin direct (conteneur disparu)
```

- Sans argument (et sans `--list`) : affiche l'aide et quitte (code 1).
- `--timestamp` : choisit une sauvegarde précise (défaut : la plus récente **complète** ;
  une sauvegarde `_incomplet` doit être demandée explicitement).
- Toutes les archives à restaurer sont vérifiées (`tar tzf`) **avant** la confirmation :
  si l'une est corrompue, rien n'est arrêté ni modifié.
- `--volume nom[,nom...]` : restaure directement un/des volume(s) Docker par leur nom.
- `--path chemin[,chemin...]` : restaure directement un/des dossier(s) d'application par
  leur chemin hôte absolu (sous `APPDATA_PATH_PREFIX`). `--volume` et `--path` sont
  combinables entre eux, utiles si le conteneur d'origine n'existe plus, mais aucun des
  deux ne peut être combiné avec une liste de conteneurs.
- **Opération destructive** : le contenu actuel des cibles est écrasé (le volume ou le
  dossier lui-même n'est pas supprimé, seulement son contenu). Une confirmation
  interactive est demandée, sauf avec `--yes`.
- Seuls les conteneurs utilisant les volumes/dossiers restaurés sont arrêtés puis
  redémarrés (`docker ps --filter volume=...` fonctionne aussi bien pour les volumes
  nommés que pour les sources de bind mount).
- **Le conteneur lui-même n'est pas recréé** : le restore ne remet que les données en
  place. S'il a été supprimé, il faut le relancer (`docker run`/`docker compose up`)
  après restauration.

## Sécurité / points d'attention

- `docker-backup.conf` contient un chemin vers une clé SSH privée : ne pas le committer
  dans un dépôt public.
- Le verrou (`/tmp/docker-volume-backup.lock` / `-restore.lock`) empêche deux exécutions
  concurrentes.
- La restauration écrase les données existantes du volume avant d'extraire l'archive :
  toujours vérifier le `--timestamp` et la liste des volumes affichée avant de confirmer.
- Si `NAS_SSH_KEY` est introuvable, les deux scripts proposent de la générer (ed25519)
  en lançant `ssh-keygen`, mais seulement en terminal interactif ; ils indiquent alors la
  commande `ssh-copy-id` à lancer avant de relancer. En exécution non interactive (cron),
  ils échouent directement avec un message clair plutôt que de tenter une génération.

## Évolution envisagée (peut-être)

Aujourd'hui, chaque sauvegarde est une **copie complète** (`tar.gz` de chaque volume/dossier) :
avec `RETENTION_COUNT=5`, chaque donnée est stockée 5 fois sur le NAS, sans déduplication
ni chiffrement. Tant que le volume de données reste raisonnable, c'est simple et suffisant.

Si l'espace occupé sur le NAS devient un problème, piste à étudier : remplacer l'étape
`tar.gz` + `rsync` par [restic](https://restic.net/) (dépôt sur le NAS via SFTP), qui
apporte :

- la sauvegarde **incrémentale avec déduplication** (seuls les blocs modifiés sont envoyés
  et stockés) ;
- le **chiffrement** du dépôt ;
- une rétention plus fine (`restic forget --keep-daily 7 --keep-weekly 4 ...`).

L'idée serait de **conserver la logique actuelle d'arrêt des conteneurs groupe par groupe**
(union-find, redémarrage immédiat), et de lancer `restic backup` sur les volumes/dossiers
de chaque groupe à la place du `tar czf`. Alternatives similaires : borg / borgmatic.
