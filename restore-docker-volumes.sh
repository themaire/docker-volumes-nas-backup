#!/usr/bin/env bash
#
# restore-docker-volumes.sh
#
# Restaure des volumes Docker nommés ET des données d'application en bind mount
# (ex : /DATA/AppData/<app> sous CasaOS) depuis une sauvegarde présente sur le NAS
# distant (contrepartie de backup-docker-volumes.sh).
#
# Usage :
#   ./restore-docker-volumes.sh --list [--conf FICHIER]
#   ./restore-docker-volumes.sh [--conf FICHIER] [--timestamp TS] [--yes] <ALL | conteneur [conteneur ...]>
#   ./restore-docker-volumes.sh [--conf FICHIER] [--timestamp TS] [--yes] [--volume nom[,nom...]] [--path chemin[,chemin...]]
#
# Arguments :
#   ALL                 Restaure tous les volumes et toutes les données d'application
#                        présents dans la sauvegarde.
#   conteneur [...]     Restaure uniquement les volumes nommés et les données
#                        APPDATA_PATH_PREFIX utilisés par ces conteneurs (le conteneur
#                        doit exister sur cette machine, arrêté ou non). Seuls les
#                        conteneurs concernés sont arrêtés pendant la restauration.
#
# Options :
#   --list              Liste les sauvegardes disponibles sur le NAS et quitte.
#   --timestamp TS      Sauvegarde à restaurer (par défaut : la plus récente).
#   --volume nom[,...]  Restaure ces volumes Docker par leur nom directement. Utile si
#                        le conteneur d'origine n'existe plus. Combinable avec --path.
#   --path chemin[,...] Restaure ces dossiers d'application (chemins hôte absolus sous
#                        APPDATA_PATH_PREFIX, ex: /DATA/AppData/hermes) directement.
#                        Utile si le conteneur d'origine n'existe plus. Combinable
#                        avec --volume.
#   --yes               Ne pas demander de confirmation avant d'écraser les données.
#   --conf FICHIER      Chemin vers le fichier de config (défaut : docker-backup.conf
#                        à côté du script).
#   -h, --help          Affiche cette aide.
#
# --volume et --path ne peuvent pas être combinés avec une liste de conteneurs.
#
# Exemples :
#   ./restore-docker-volumes.sh --list
#   ./restore-docker-volumes.sh ALL
#   ./restore-docker-volumes.sh mon_conteneur
#   ./restore-docker-volumes.sh --timestamp 2026-08-18_21-30-00 conteneur1 conteneur2
#   ./restore-docker-volumes.sh --volume mon_volume --yes
#   ./restore-docker-volumes.sh --path /DATA/AppData/hermes --yes
#
set -euo pipefail

# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
CONF_FILE="${SCRIPT_DIR}/docker-backup.conf"
ACTION="restore"
TARGET_TIMESTAMP=""
VOLUME_ARG=""
PATH_ARG=""
ASSUME_YES=0

print_usage() {
    cat <<'EOF'
Usage :
  ./restore-docker-volumes.sh --list [--conf FICHIER]
  ./restore-docker-volumes.sh [--conf FICHIER] [--timestamp TS] [--yes] <ALL | conteneur [conteneur ...]>
  ./restore-docker-volumes.sh [--conf FICHIER] [--timestamp TS] [--yes] [--volume nom[,nom...]] [--path chemin[,chemin...]]

Restaure des volumes Docker nommés ET des données d'application en bind mount (ex :
/DATA/AppData/<app> sous CasaOS) depuis une sauvegarde présente sur le NAS distant
(contrepartie de backup-docker-volumes.sh).

Arguments :
  ALL                 Restaure tous les volumes et toutes les données d'application
                       présents dans la sauvegarde.
  conteneur [...]     Restaure uniquement les volumes nommés et les données
                       APPDATA_PATH_PREFIX utilisés par ces conteneurs (le conteneur
                       doit exister sur cette machine, arrêté ou non). Seuls les
                       conteneurs concernés sont arrêtés pendant la restauration.

Options :
  --list              Liste les sauvegardes disponibles sur le NAS et quitte.
  --timestamp TS      Sauvegarde à restaurer (par défaut : la plus récente).
  --volume nom[,...]  Restaure ces volumes Docker par leur nom directement. Utile si
                       le conteneur d'origine n'existe plus. Combinable avec --path.
  --path chemin[,...] Restaure ces dossiers d'application (chemins hôte absolus sous
                       APPDATA_PATH_PREFIX, ex: /DATA/AppData/hermes) directement.
                       Utile si le conteneur d'origine n'existe plus. Combinable
                       avec --volume.
  --yes               Ne pas demander de confirmation avant d'écraser les données.
  --conf FICHIER      Chemin vers le fichier de config (défaut : docker-backup.conf
                       à côté du script).
  -h, --help          Affiche cette aide.

--volume et --path ne peuvent pas être combinés avec une liste de conteneurs.

Exemples :
  ./restore-docker-volumes.sh --list
  ./restore-docker-volumes.sh ALL
  ./restore-docker-volumes.sh mon_conteneur
  ./restore-docker-volumes.sh --timestamp 2026-08-18_21-30-00 conteneur1 conteneur2
  ./restore-docker-volumes.sh --volume mon_volume --yes
  ./restore-docker-volumes.sh --path /DATA/AppData/hermes --yes
EOF
}

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list) ACTION="list"; shift ;;
        --timestamp) TARGET_TIMESTAMP="$2"; shift 2 ;;
        --volume) VOLUME_ARG="$2"; shift 2 ;;
        --path) PATH_ARG="$2"; shift 2 ;;
        --yes) ASSUME_YES=1; shift ;;
        --conf) CONF_FILE="$2"; shift 2 ;;
        -h|--help) print_usage; exit 0 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

if [[ "${ACTION}" != "list" && "${#POSITIONAL[@]}" -eq 0 && -z "${VOLUME_ARG}" && -z "${PATH_ARG}" ]]; then
    print_usage
    exit 1
fi

if [[ ( -n "${VOLUME_ARG}" || -n "${PATH_ARG}" ) && "${#POSITIONAL[@]}" -gt 0 ]]; then
    echo "--volume/--path ne peuvent pas être combinés avec une liste de conteneurs." >&2
    exit 1
fi

ALL_MODE=0
CONTAINERS=()
for arg in "${POSITIONAL[@]}"; do
    if [[ "${arg}" == "ALL" ]]; then
        ALL_MODE=1
    else
        CONTAINERS+=("${arg}")
    fi
done

if [[ "${ALL_MODE}" -eq 1 && "${#CONTAINERS[@]}" -gt 0 ]]; then
    echo "ALL ne peut pas être combiné avec une liste de conteneurs." >&2
    exit 1
fi

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
if [[ ! -f "${CONF_FILE}" ]]; then
    echo "Fichier de configuration introuvable : ${CONF_FILE}" >&2
    echo "Copiez docker-backup.conf.example vers docker-backup.conf et adaptez-le." >&2
    exit 1
fi
# shellcheck source=docker-backup.conf.example
source "${CONF_FILE}"

: "${NAS_USER:?NAS_USER manquant dans la config}"
: "${NAS_HOST:?NAS_HOST manquant dans la config}"
: "${NAS_SSH_PORT:=22}"
: "${NAS_SSH_KEY:?NAS_SSH_KEY manquant dans la config}"
: "${NAS_BACKUP_PATH:?NAS_BACKUP_PATH manquant dans la config}"
: "${LOCAL_TMP_DIR:?LOCAL_TMP_DIR manquant dans la config}"
: "${LOG_FILE:=/var/log/docker-volume-backup.log}"
: "${APPDATA_PATH_PREFIX:=}"
: "${ALPINE_IMAGE:=alpine:3.20}"
APPDATA_PATH_PREFIX="${APPDATA_PATH_PREFIX%/}"

SSH_OPTS=(-p "${NAS_SSH_PORT}" -i "${NAS_SSH_KEY}" -o BatchMode=yes -o ConnectTimeout=10)
LOCKFILE="/tmp/docker-volume-restore.lock"

STOPPED_CONTAINERS=()

log() {
    local level="$1"; shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" | tee -a "${LOG_FILE}"
}

# Convertit un chemin hôte sous APPDATA_PATH_PREFIX en clé d'archive (ex :
# /DATA/AppData/big-bear-immich/upload -> big-bear-immich__upload).
appdata_key() {
    local path="$1"
    local rel="${path#"${APPDATA_PATH_PREFIX}"/}"
    echo "${rel//\//__}"
}

# Convertit une clé d'archive en chemin hôte absolu (opération inverse d'appdata_key).
appdata_key_to_path() {
    local key="$1"
    echo "${APPDATA_PATH_PREFIX}/${key//__//}"
}

restart_containers() {
    if [[ "${#STOPPED_CONTAINERS[@]}" -gt 0 ]]; then
        log "INFO" "Redémarrage des conteneurs arrêtés (${#STOPPED_CONTAINERS[@]})..."
        docker start "${STOPPED_CONTAINERS[@]}" >/dev/null || \
            log "ERROR" "Échec du redémarrage d'au moins un conteneur : ${STOPPED_CONTAINERS[*]}"
    fi
}

cleanup() {
    local exit_code=$?
    restart_containers
    rm -f "${LOCKFILE}"
    exit "${exit_code}"
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------------------
# Liste des sauvegardes disponibles sur le NAS
# --------------------------------------------------------------------------
list_remote_backups() {
    ssh "${SSH_OPTS[@]}" "${NAS_USER}@${NAS_HOST}" \
        "find '${NAS_BACKUP_PATH}' -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort"
}

# Clé SSH dédiée absente : sur un terminal interactif, proposer de la générer plutôt que
# d'échouer directement (premier lancement typique). En non-interactif, on échoue tout
# de suite avec un message explicite.
if [[ ! -f "${NAS_SSH_KEY}" ]]; then
    if [[ -t 0 && -t 1 ]]; then
        echo "Clé SSH introuvable : ${NAS_SSH_KEY}" >&2
        read -r -p "La générer maintenant (ed25519) ? [y/N] " reply
        if [[ "${reply}" =~ ^[Yy]$ ]]; then
            mkdir -p "$(dirname "${NAS_SSH_KEY}")"
            ssh-keygen -t ed25519 -f "${NAS_SSH_KEY}" -N ""
            echo "Clé générée. Copiez-la sur le NAS avant de relancer :" >&2
            echo "  ssh-copy-id -i ${NAS_SSH_KEY}.pub -p ${NAS_SSH_PORT} ${NAS_USER}@${NAS_HOST}" >&2
            exit 1
        fi
    fi
    log "ERROR" "clé SSH introuvable : ${NAS_SSH_KEY}"
    exit 1
fi

if [[ "${ACTION}" == "list" ]]; then
    echo "Sauvegardes disponibles sur ${NAS_USER}@${NAS_HOST}:${NAS_BACKUP_PATH} :"
    list_remote_backups
    exit 0
fi

# --------------------------------------------------------------------------
# Verrou anti-exécution concurrente
# --------------------------------------------------------------------------
exec 9>"${LOCKFILE}"
if ! flock -n 9; then
    echo "Une restauration est déjà en cours (verrou ${LOCKFILE}). Abandon." >&2
    exit 1
fi

mkdir -p "${LOCAL_TMP_DIR}" "$(dirname "${LOG_FILE}")"

# --------------------------------------------------------------------------
# Détermination des filtres (conteneurs, --volume, --path, ou ALL = pas de filtre)
# --------------------------------------------------------------------------
FILTER_VOLUMES=0
FILTER_APPDATA=0
VOLUME_FILTER=""
APPDATA_FILTER=""

if [[ -n "${VOLUME_ARG}" ]]; then
    FILTER_VOLUMES=1
    VOLUME_FILTER="${VOLUME_ARG}"
fi
if [[ -n "${PATH_ARG}" ]]; then
    FILTER_APPDATA=1
    APPDATA_FILTER="${PATH_ARG}"
fi

if [[ "${#CONTAINERS[@]}" -gt 0 ]]; then
    FILTER_VOLUMES=1
    FILTER_APPDATA=1

    for c in "${CONTAINERS[@]}"; do
        if ! docker inspect "${c}" >/dev/null 2>&1; then
            log "ERROR" "Conteneur introuvable sur cette machine : ${c} (utilisez --volume/--path si le conteneur n'existe plus)."
            exit 1
        fi
    done

    CONTAINER_VOLUMES=()
    CONTAINER_APPDATA_PATHS=()
    for c in "${CONTAINERS[@]}"; do
        mapfile -t vols < <(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' "${c}")
        for v in "${vols[@]}"; do
            [[ -z "${v}" ]] && continue
            already=0
            for existing in "${CONTAINER_VOLUMES[@]-}"; do [[ "${existing}" == "${v}" ]] && already=1 && break; done
            [[ "${already}" -eq 0 ]] && CONTAINER_VOLUMES+=("${v}")
        done

        if [[ -n "${APPDATA_PATH_PREFIX}" ]]; then
            mapfile -t binds < <(docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' "${c}")
            for b in "${binds[@]}"; do
                [[ -z "${b}" ]] && continue
                [[ "${b}" == "${APPDATA_PATH_PREFIX}/"* ]] || continue
                already=0
                for existing in "${CONTAINER_APPDATA_PATHS[@]-}"; do [[ "${existing}" == "${b}" ]] && already=1 && break; done
                [[ "${already}" -eq 0 ]] && CONTAINER_APPDATA_PATHS+=("${b}")
            done
        fi
    done

    if [[ "${#CONTAINER_VOLUMES[@]}" -eq 0 && "${#CONTAINER_APPDATA_PATHS[@]}" -eq 0 ]]; then
        log "ERROR" "Aucun volume nommé ni donnée d'application trouvé pour le(s) conteneur(s) : ${CONTAINERS[*]}."
        exit 1
    fi
    [[ "${#CONTAINER_VOLUMES[@]}" -gt 0 ]] && VOLUME_FILTER="$(IFS=,; echo "${CONTAINER_VOLUMES[*]}")"
    [[ "${#CONTAINER_APPDATA_PATHS[@]}" -gt 0 ]] && APPDATA_FILTER="$(IFS=,; echo "${CONTAINER_APPDATA_PATHS[*]}")"
fi

# --------------------------------------------------------------------------
# Détermination du timestamp à restaurer
# --------------------------------------------------------------------------
if [[ -z "${TARGET_TIMESTAMP}" ]]; then
    # Les sauvegardes partielles ("_incomplet") ne sont jamais choisies par défaut : il
    # faut les demander explicitement avec --timestamp.
    TARGET_TIMESTAMP="$(list_remote_backups | grep -v '_incomplet$' | tail -n 1 || true)"
    if [[ -z "${TARGET_TIMESTAMP}" ]]; then
        log "ERROR" "Aucune sauvegarde complète trouvée sur le NAS (voir --list, puis --timestamp)."
        exit 1
    fi
    log "INFO" "Aucun --timestamp fourni, utilisation de la plus récente complète : ${TARGET_TIMESTAMP}"
fi

REMOTE_DIR="${NAS_BACKUP_PATH}/${TARGET_TIMESTAMP}"
if ! ssh "${SSH_OPTS[@]}" "${NAS_USER}@${NAS_HOST}" "[[ -d '${REMOTE_DIR}' ]]"; then
    log "ERROR" "Sauvegarde introuvable sur le NAS : ${REMOTE_DIR}"
    exit 1
fi

# --------------------------------------------------------------------------
# Rapatriement de la sauvegarde
# --------------------------------------------------------------------------
RESTORE_DIR="${LOCAL_TMP_DIR}/restore-${TARGET_TIMESTAMP}"
mkdir -p "${RESTORE_DIR}"
log "INFO" "Récupération de ${NAS_USER}@${NAS_HOST}:${REMOTE_DIR}/ vers ${RESTORE_DIR}/ ..."
rsync -az --partial -e "ssh ${SSH_OPTS[*]}" \
    "${NAS_USER}@${NAS_HOST}:${REMOTE_DIR}/" \
    "${RESTORE_DIR}/"

mapfile -t ARCHIVES < <(find "${RESTORE_DIR}" -maxdepth 1 -name '*.tar.gz' -printf '%f\n' | sort)
if [[ "${#ARCHIVES[@]}" -eq 0 ]]; then
    log "ERROR" "Aucune archive .tar.gz trouvée dans ${RESTORE_DIR}."
    exit 1
fi

VOLUMES_TO_RESTORE=()
APPDATA_KEYS_TO_RESTORE=()
APPDATA_PATHS_TO_RESTORE=()
for archive in "${ARCHIVES[@]}"; do
    base="${archive%.tar.gz}"
    if [[ "${base}" == appdata__* ]]; then
        key="${base#appdata__}"
        if [[ -z "${APPDATA_PATH_PREFIX}" ]]; then
            log "ERROR" "L'archive '${archive}' est une donnée d'application mais APPDATA_PATH_PREFIX n'est pas configuré."
            exit 1
        fi
        hostpath="$(appdata_key_to_path "${key}")"
        if [[ "${FILTER_APPDATA}" -eq 1 ]]; then
            skip=1
            if [[ -n "${APPDATA_FILTER}" ]]; then
                IFS=',' read -ra wanted <<< "${APPDATA_FILTER}"
                for w in "${wanted[@]}"; do
                    [[ "${hostpath}" == "${w%/}" ]] && skip=0 && break
                done
            fi
            [[ "${skip}" -eq 1 ]] && continue
        fi
        APPDATA_KEYS_TO_RESTORE+=("${key}")
        APPDATA_PATHS_TO_RESTORE+=("${hostpath}")
    else
        vol="${base}"
        if [[ "${FILTER_VOLUMES}" -eq 1 ]]; then
            skip=1
            if [[ -n "${VOLUME_FILTER}" ]]; then
                IFS=',' read -ra wanted <<< "${VOLUME_FILTER}"
                for w in "${wanted[@]}"; do
                    [[ "${vol}" == "${w}" ]] && skip=0 && break
                done
            fi
            [[ "${skip}" -eq 1 ]] && continue
        fi
        VOLUMES_TO_RESTORE+=("${vol}")
    fi
done

if [[ "${#VOLUMES_TO_RESTORE[@]}" -eq 0 && "${#APPDATA_PATHS_TO_RESTORE[@]}" -eq 0 ]]; then
    log "ERROR" "Aucun volume ni donnée d'application à restaurer trouvé dans la sauvegarde '${TARGET_TIMESTAMP}' (vérifiez le(s) conteneur(s), --volume ou --path)."
    exit 1
fi

log "INFO" "Volume(s) à restaurer (${#VOLUMES_TO_RESTORE[@]}) : ${VOLUMES_TO_RESTORE[*]-}"
log "INFO" "Dossier(s) d'application à restaurer (${#APPDATA_PATHS_TO_RESTORE[@]}) : ${APPDATA_PATHS_TO_RESTORE[*]-}"

# --------------------------------------------------------------------------
# Vérification des archives AVANT toute opération destructive : la restauration vide
# la cible avant d'extraire, donc une archive corrompue (ou abîmée pendant le transfert)
# laisserait un volume vide. On abandonne tout ici plutôt qu'à moitié.
# --------------------------------------------------------------------------
ARCHIVES_TO_CHECK=()
for vol in "${VOLUMES_TO_RESTORE[@]-}"; do
    [[ -n "${vol}" ]] && ARCHIVES_TO_CHECK+=("${vol}.tar.gz")
done
for key in "${APPDATA_KEYS_TO_RESTORE[@]-}"; do
    [[ -n "${key}" ]] && ARCHIVES_TO_CHECK+=("appdata__${key}.tar.gz")
done

log "INFO" "Vérification de ${#ARCHIVES_TO_CHECK[@]} archive(s) avant restauration..."
CORRUPTED=0
for archive in "${ARCHIVES_TO_CHECK[@]}"; do
    if ! docker run --rm -v "${RESTORE_DIR}:/backup:ro" "${ALPINE_IMAGE}" \
        tar tzf "/backup/${archive}" >/dev/null; then
        log "ERROR" "Archive corrompue ou illisible : ${archive}"
        CORRUPTED=1
    fi
done
if [[ "${CORRUPTED}" -eq 1 ]]; then
    log "ERROR" "Restauration annulée : aucune donnée n'a été modifiée."
    exit 1
fi

# --------------------------------------------------------------------------
# Confirmation (opération destructive : écrase le contenu actuel des cibles)
# --------------------------------------------------------------------------
if [[ "${ASSUME_YES}" -ne 1 ]]; then
    echo "Ceci va ÉCRASER le contenu actuel de :"
    [[ "${#VOLUMES_TO_RESTORE[@]}" -gt 0 ]] && printf '  - volume : %s\n' "${VOLUMES_TO_RESTORE[@]}"
    [[ "${#APPDATA_PATHS_TO_RESTORE[@]}" -gt 0 ]] && printf '  - dossier : %s\n' "${APPDATA_PATHS_TO_RESTORE[@]}"
    read -r -p "Confirmer la restauration depuis '${TARGET_TIMESTAMP}' ? [y/N] " reply
    [[ "${reply}" =~ ^[Yy]$ ]] || { log "INFO" "Restauration annulée par l'utilisateur."; exit 0; }
fi

# --------------------------------------------------------------------------
# Arrêt des conteneurs utilisant les volumes / dossiers concernés
# --------------------------------------------------------------------------
for target in "${VOLUMES_TO_RESTORE[@]-}" "${APPDATA_PATHS_TO_RESTORE[@]-}"; do
    [[ -z "${target}" ]] && continue
    mapfile -t containers < <(docker ps -q --filter "volume=${target}")
    for c in "${containers[@]}"; do
        [[ " ${STOPPED_CONTAINERS[*]-} " == *" ${c} "* ]] && continue
        STOPPED_CONTAINERS+=("${c}")
    done
done

if [[ "${#STOPPED_CONTAINERS[@]}" -gt 0 ]]; then
    log "INFO" "Arrêt de ${#STOPPED_CONTAINERS[@]} conteneur(s) utilisant les cibles à restaurer..."
    docker stop "${STOPPED_CONTAINERS[@]}" >/dev/null
fi

# --------------------------------------------------------------------------
# Restauration de chaque volume et dossier d'application
# --------------------------------------------------------------------------
RESTORE_FAILED=0
for vol in "${VOLUMES_TO_RESTORE[@]-}"; do
    [[ -z "${vol}" ]] && continue
    log "INFO" "Restauration du volume '${vol}'..."
    docker volume inspect "${vol}" >/dev/null 2>&1 || docker volume create "${vol}" >/dev/null

    if ! docker run --rm \
        -v "${vol}:/target" \
        -v "${RESTORE_DIR}:/backup:ro" \
        "${ALPINE_IMAGE}" \
        sh -c "rm -rf /target/..?* /target/.[!.]* /target/* 2>/dev/null; tar xzf '/backup/${vol}.tar.gz' -C /target" ; then
        log "ERROR" "Échec de la restauration du volume '${vol}'."
        RESTORE_FAILED=1
    fi
done

for i in "${!APPDATA_PATHS_TO_RESTORE[@]}"; do
    hostpath="${APPDATA_PATHS_TO_RESTORE[$i]}"
    key="${APPDATA_KEYS_TO_RESTORE[$i]}"
    log "INFO" "Restauration du dossier '${hostpath}' (appdata__${key})..."

    if ! docker run --rm \
        -v "${hostpath}:/target" \
        -v "${RESTORE_DIR}:/backup:ro" \
        "${ALPINE_IMAGE}" \
        sh -c "rm -rf /target/..?* /target/.[!.]* /target/* 2>/dev/null; tar xzf '/backup/appdata__${key}.tar.gz' -C /target" ; then
        log "ERROR" "Échec de la restauration de '${hostpath}'."
        RESTORE_FAILED=1
    fi
done

# --------------------------------------------------------------------------
# Redémarrage des conteneurs
# --------------------------------------------------------------------------
restart_containers
STOPPED_CONTAINERS=()

rm -rf "${RESTORE_DIR}"

if [[ "${RESTORE_FAILED}" -eq 1 ]]; then
    log "WARN" "=== Restauration terminée avec des erreurs (${TARGET_TIMESTAMP}) ==="
    exit 1
fi

log "INFO" "=== Restauration terminée avec succès depuis ${TARGET_TIMESTAMP} ==="
