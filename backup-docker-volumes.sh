#!/usr/bin/env bash
#
# backup-docker-volumes.sh
#
# Sauvegarde des volumes Docker nommés ET des données d'application en bind mount
# (ex : /DATA/AppData/<app> sous CasaOS) vers un NAS distant (via SSH/rsync), en
# arrêtant temporairement les conteneurs concernés pour garantir des données cohérentes.
#
# Usage :
#   ./backup-docker-volumes.sh [--conf FICHIER] <ALL | conteneur [conteneur ...]>
#
# Arguments :
#   ALL                 Sauvegarde tous les volumes Docker nommés de la machine, ainsi
#                        que toutes les données sous APPDATA_PATH_PREFIX utilisées par
#                        un conteneur (comportement complet).
#   conteneur [...]     Sauvegarde uniquement les volumes nommés et les données
#                        APPDATA_PATH_PREFIX utilisés par ces conteneurs (noms ou ID
#                        Docker, séparés par des espaces). Chaque conteneur (ou groupe
#                        de conteneurs partageant un volume/dossier) n'est arrêté que le
#                        temps de sa propre sauvegarde, puis redémarré aussitôt — pas
#                        besoin d'attendre la fin de tout le run.
#
# Options :
#   --conf FICHIER      Chemin vers le fichier de config (défaut : docker-backup.conf
#                        à côté du script).
#   -h, --help          Affiche cette aide.
#
# Exemples :
#   ./backup-docker-volumes.sh ALL
#   ./backup-docker-volumes.sh mon_conteneur
#   ./backup-docker-volumes.sh conteneur1 conteneur2
#
set -euo pipefail

# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
CONF_FILE="${SCRIPT_DIR}/docker-backup.conf"

print_usage() {
    cat <<'EOF'
Usage :
  ./backup-docker-volumes.sh [--conf FICHIER] <ALL | conteneur [conteneur ...]>

Sauvegarde des volumes Docker nommés ET des données d'application en bind mount (ex :
/DATA/AppData/<app> sous CasaOS) vers un NAS distant (via SSH/rsync), en arrêtant
temporairement les conteneurs concernés pour garantir des données cohérentes.

Arguments :
  ALL                 Sauvegarde tous les volumes Docker nommés, ainsi que toutes les
                       données sous APPDATA_PATH_PREFIX utilisées par un conteneur
                       (comportement complet).
  conteneur [...]     Sauvegarde uniquement les volumes nommés et les données
                       APPDATA_PATH_PREFIX utilisés par ces conteneurs (noms ou ID
                       Docker, séparés par des espaces). Chaque conteneur (ou groupe
                       de conteneurs partageant un volume/dossier) n'est arrêté que le
                       temps de sa propre sauvegarde, puis redémarré aussitôt.

Options :
  --conf FICHIER      Chemin vers le fichier de config (défaut : docker-backup.conf
                       à côté du script).
  -h, --help          Affiche cette aide.

Exemples :
  ./backup-docker-volumes.sh ALL
  ./backup-docker-volumes.sh mon_conteneur
  ./backup-docker-volumes.sh conteneur1 conteneur2
EOF
}

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --conf) CONF_FILE="$2"; shift 2 ;;
        -h|--help) print_usage; exit 0 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

if [[ "${#POSITIONAL[@]}" -eq 0 ]]; then
    print_usage
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
: "${RETENTION_COUNT:=5}"
: "${LOG_FILE:=/var/log/docker-volume-backup.log}"
: "${EXCLUDE_VOLUMES:=}"
: "${NOTIFY_CMD:=}"
: "${APPDATA_PATH_PREFIX:=}"
: "${EXCLUDE_APPDATA:=}"
: "${ALPINE_IMAGE:=alpine:3.20}"
APPDATA_PATH_PREFIX="${APPDATA_PATH_PREFIX%/}"

TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
BACKUP_DIR="${LOCAL_TMP_DIR}/${TIMESTAMP}"
LOCKFILE="/tmp/docker-volume-backup.lock"
SSH_OPTS=(-p "${NAS_SSH_PORT}" -i "${NAS_SSH_KEY}" -o BatchMode=yes -o ConnectTimeout=10)

STOPPED_CONTAINERS=()
BACKUP_FAILED=0

# --------------------------------------------------------------------------
# Utilitaires
# --------------------------------------------------------------------------
log() {
    local level="$1"; shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" | tee -a "${LOG_FILE}"
}

# NOTIFY_CMD est une ligne de commande shell complète (arguments, pipes...) : le message
# y est disponible en "$1", ex : curl -s -d "$1" https://ntfy.sh/mon-sujet
notify_failure() {
    local message="$1"
    log "ERROR" "${message}"
    if [[ -n "${NOTIFY_CMD}" ]]; then
        bash -c "${NOTIFY_CMD}" notify "Backup Docker volumes échoué : ${message}" || true
    fi
}

# Convertit un chemin hôte sous APPDATA_PATH_PREFIX en clé d'archive (ex :
# /DATA/AppData/big-bear-immich/upload -> big-bear-immich__upload).
appdata_key() {
    local path="$1"
    local rel="${path#"${APPDATA_PATH_PREFIX}"/}"
    echo "${rel//\//__}"
}

# Vérifie qu'une archive fraîchement créée est lisible (gzip + table des fichiers tar),
# sans l'extraire. Détecte une archive tronquée/corrompue (disque plein, coupure...)
# tout de suite plutôt qu'au moment d'une restauration, potentiellement des mois plus tard.
verify_archive() {
    local archive="$1"
    if ! docker run --rm -v "${archive}:/backup.tar.gz:ro" "${ALPINE_IMAGE}" \
        tar tzf /backup.tar.gz >/dev/null; then
        log "ERROR" "Archive corrompue ou illisible : ${archive}"
        return 1
    fi
}

# Union-find (conteneurs regroupés par volume/dossier partagé) : PARENT associe chaque
# conteneur à son représentant de groupe.
declare -A PARENT
find_root() {
    local x="$1"
    while [[ "${PARENT[$x]}" != "$x" ]]; do x="${PARENT[$x]}"; done
    echo "$x"
}
union_containers() {
    local ra rb
    ra="$(find_root "$1")"
    rb="$(find_root "$2")"
    [[ "${ra}" == "${rb}" ]] && return
    PARENT["${ra}"]="${rb}"
}

# Relance les conteneurs arrêtés par ce script, quoi qu'il arrive (succès, échec, Ctrl+C).
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
    if [[ ${exit_code} -ne 0 ]]; then
        notify_failure "le script s'est terminé avec le code ${exit_code}"
    fi
    rm -f "${LOCKFILE}"
    exit "${exit_code}"
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------------------
# Verrou anti-exécution concurrente
# --------------------------------------------------------------------------
exec 9>"${LOCKFILE}"
if ! flock -n 9; then
    echo "Une sauvegarde est déjà en cours (verrou ${LOCKFILE}). Abandon." >&2
    exit 1
fi

mkdir -p "${LOCAL_TMP_DIR}" "$(dirname "${LOG_FILE}")"
mkdir -p "${BACKUP_DIR}"

log "INFO" "=== Début de la sauvegarde des volumes Docker (${TIMESTAMP}) ==="

# --------------------------------------------------------------------------
# Pré-vérifications
# --------------------------------------------------------------------------
if ! command -v docker >/dev/null; then
    notify_failure "docker introuvable sur cette machine"
    exit 1
fi

# Clé SSH dédiée absente : sur un terminal interactif, proposer de la générer plutôt que
# d'échouer directement (premier lancement typique). En non-interactif (cron), on échoue
# tout de suite avec un message explicite.
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
    notify_failure "clé SSH introuvable : ${NAS_SSH_KEY}"
    exit 1
fi

if ! ssh "${SSH_OPTS[@]}" "${NAS_USER}@${NAS_HOST}" "mkdir -p '${NAS_BACKUP_PATH}'" ; then
    notify_failure "impossible de se connecter au NAS (${NAS_USER}@${NAS_HOST}:${NAS_SSH_PORT})"
    exit 1
fi

# --------------------------------------------------------------------------
# Détermination des conteneurs à scanner
# --------------------------------------------------------------------------
if [[ "${ALL_MODE}" -eq 1 ]]; then
    mapfile -t SCAN_CONTAINERS < <(docker ps -aq)
else
    for c in "${CONTAINERS[@]}"; do
        if ! docker inspect "${c}" >/dev/null 2>&1; then
            notify_failure "conteneur introuvable : ${c}"
            exit 1
        fi
    done
    SCAN_CONTAINERS=("${CONTAINERS[@]}")
fi

# --------------------------------------------------------------------------
# Pour chaque conteneur scanné : ses volumes nommés + ses données APPDATA_PATH_PREFIX
# (après exclusions), et regroupement (union-find) des conteneurs qui partagent un même
# volume/dossier — pour n'arrêter ensemble que ce qui doit vraiment l'être, et pouvoir
# redémarrer chaque groupe dès sa sauvegarde terminée plutôt qu'à la toute fin.
# --------------------------------------------------------------------------
declare -A CONTAINER_VOLS CONTAINER_APPS ITEM_OWNERS

for c in "${SCAN_CONTAINERS[@]}"; do
    PARENT["${c}"]="${c}"

    vols=""
    mapfile -t raw_vols < <(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' "${c}")
    for v in "${raw_vols[@]}"; do
        [[ -z "${v}" ]] && continue
        skip=0
        for excl in ${EXCLUDE_VOLUMES}; do [[ "${v}" == "${excl}" ]] && skip=1 && break; done
        [[ "${skip}" -eq 1 ]] && continue
        vols="${vols} ${v}"
        ITEM_OWNERS["vol:${v}"]="${ITEM_OWNERS["vol:${v}"]-}${ITEM_OWNERS["vol:${v}"]:+ }${c}"
    done
    CONTAINER_VOLS["${c}"]="${vols}"

    apps=""
    if [[ -n "${APPDATA_PATH_PREFIX}" ]]; then
        mapfile -t raw_binds < <(docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' "${c}")
        for b in "${raw_binds[@]}"; do
            [[ -z "${b}" ]] && continue
            [[ "${b}" == "${APPDATA_PATH_PREFIX}/"* ]] || continue
            key="$(appdata_key "${b}")"
            skip=0
            for excl in ${EXCLUDE_APPDATA}; do [[ "${key}" == "${excl}" ]] && skip=1 && break; done
            [[ "${skip}" -eq 1 ]] && continue
            apps="${apps} ${b}"
            ITEM_OWNERS["app:${b}"]="${ITEM_OWNERS["app:${b}"]-}${ITEM_OWNERS["app:${b}"]:+ }${c}"
        done
    fi
    CONTAINER_APPS["${c}"]="${apps}"
done

for item in "${!ITEM_OWNERS[@]}"; do
    owners=(${ITEM_OWNERS[$item]})
    for ((i = 1; i < ${#owners[@]}; i++)); do
        union_containers "${owners[0]}" "${owners[i]}"
    done
done

declare -A UNIT_CONTAINERS
for c in "${SCAN_CONTAINERS[@]}"; do
    root="$(find_root "${c}")"
    UNIT_CONTAINERS["${root}"]="${UNIT_CONTAINERS["${root}"]-}${UNIT_CONTAINERS["${root}"]:+ }${c}"
done

# Volumes orphelins (mode ALL uniquement) : présents sur la machine mais rattachés à
# aucun conteneur. Rien ne les modifie : sauvegardés sans arrêter quoi que ce soit.
ORPHAN_VOLUMES=()
if [[ "${ALL_MODE}" -eq 1 ]]; then
    mapfile -t ALL_VOLUMES < <(docker volume ls -q | sort)
    for vol in "${ALL_VOLUMES[@]}"; do
        [[ -n "${ITEM_OWNERS["vol:${vol}"]-}" ]] && continue
        skip=0
        for excl in ${EXCLUDE_VOLUMES}; do [[ "${vol}" == "${excl}" ]] && skip=1 && break; done
        [[ "${skip}" -eq 1 ]] && continue
        ORPHAN_VOLUMES+=("${vol}")
    done
fi

TOTAL_VOLUMES="${#ORPHAN_VOLUMES[@]}"
TOTAL_APPDATA=0
for item in "${!ITEM_OWNERS[@]}"; do
    case "${item}" in
        vol:*) TOTAL_VOLUMES=$((TOTAL_VOLUMES + 1)) ;;
        app:*) TOTAL_APPDATA=$((TOTAL_APPDATA + 1)) ;;
    esac
done

if [[ "${TOTAL_VOLUMES}" -eq 0 && "${TOTAL_APPDATA}" -eq 0 ]]; then
    if [[ "${ALL_MODE}" -eq 1 ]]; then
        log "WARN" "Aucun volume ni donnée d'application trouvé. Rien à sauvegarder."
    else
        log "WARN" "Aucun volume nommé ni donnée d'application (sous ${APPDATA_PATH_PREFIX:-<non défini>}) trouvé pour le(s) conteneur(s) : ${CONTAINERS[*]}. Rien à sauvegarder."
    fi
    exit 0
fi

log "INFO" "${TOTAL_VOLUMES} volume(s) et ${TOTAL_APPDATA} dossier(s) d'application à sauvegarder, en ${#UNIT_CONTAINERS[@]} groupe(s) (+${#ORPHAN_VOLUMES[@]} volume(s) orphelin(s))."

# --------------------------------------------------------------------------
# Sauvegarde groupe par groupe : arrêt seulement des conteneurs du groupe, tar de ses
# volumes/dossiers, redémarrage immédiat — au lieu d'arrêter tout le monde d'un coup
# pour toute la durée du run.
# --------------------------------------------------------------------------
for root in "${!UNIT_CONTAINERS[@]}"; do
    unit_containers=(${UNIT_CONTAINERS[$root]})

    unit_vols=()
    unit_apps=()
    for c in "${unit_containers[@]}"; do
        for v in ${CONTAINER_VOLS[$c]}; do
            already=0
            for existing in "${unit_vols[@]-}"; do [[ "${existing}" == "${v}" ]] && already=1 && break; done
            [[ "${already}" -eq 0 ]] && unit_vols+=("${v}")
        done
        for a in ${CONTAINER_APPS[$c]}; do
            already=0
            for existing in "${unit_apps[@]-}"; do [[ "${existing}" == "${a}" ]] && already=1 && break; done
            [[ "${already}" -eq 0 ]] && unit_apps+=("${a}")
        done
    done

    # Conteneur sans volume ni donnée d'application concernée : rien à faire pour lui.
    [[ "${#unit_vols[@]}" -eq 0 && "${#unit_apps[@]}" -eq 0 ]] && continue

    unit_running=()
    for c in "${unit_containers[@]}"; do
        if [[ "$(docker inspect -f '{{.State.Running}}' "${c}")" == "true" ]]; then
            unit_running+=("${c}")
        fi
    done

    log "INFO" "--- Groupe [${unit_containers[*]}] : ${#unit_vols[@]} volume(s), ${#unit_apps[@]} dossier(s) ---"

    if [[ "${#unit_running[@]}" -gt 0 ]]; then
        docker stop "${unit_running[@]}" >/dev/null
        STOPPED_CONTAINERS=("${unit_running[@]}")
    fi

    for vol in "${unit_vols[@]}"; do
        log "INFO" "Sauvegarde du volume '${vol}'..."
        if docker run --rm \
            -v "${vol}:/source:ro" \
            -v "${BACKUP_DIR}:/backup" \
            "${ALPINE_IMAGE}" \
            tar czf "/backup/${vol}.tar.gz" -C /source . ; then
            verify_archive "${BACKUP_DIR}/${vol}.tar.gz" || BACKUP_FAILED=1
        else
            log "ERROR" "Échec de la sauvegarde du volume '${vol}'."
            BACKUP_FAILED=1
        fi
    done

    for path in "${unit_apps[@]}"; do
        key="appdata__$(appdata_key "${path}")"
        log "INFO" "Sauvegarde du dossier '${path}' (${key})..."
        if docker run --rm \
            -v "${path}:/source:ro" \
            -v "${BACKUP_DIR}:/backup" \
            "${ALPINE_IMAGE}" \
            tar czf "/backup/${key}.tar.gz" -C /source . ; then
            verify_archive "${BACKUP_DIR}/${key}.tar.gz" || BACKUP_FAILED=1
        else
            log "ERROR" "Échec de la sauvegarde de '${path}'."
            BACKUP_FAILED=1
        fi
    done

    restart_containers
    STOPPED_CONTAINERS=()
done

for vol in "${ORPHAN_VOLUMES[@]-}"; do
    [[ -z "${vol}" ]] && continue
    log "INFO" "Sauvegarde du volume orphelin '${vol}' (aucun conteneur, pas d'arrêt nécessaire)..."
    if docker run --rm \
        -v "${vol}:/source:ro" \
        -v "${BACKUP_DIR}:/backup" \
        "${ALPINE_IMAGE}" \
        tar czf "/backup/${vol}.tar.gz" -C /source . ; then
        verify_archive "${BACKUP_DIR}/${vol}.tar.gz" || BACKUP_FAILED=1
    else
        log "ERROR" "Échec de la sauvegarde du volume '${vol}'."
        BACKUP_FAILED=1
    fi
done

# Sauvegarde partielle : envoyée quand même (les éléments réussis restent utiles), mais
# sous un nom suffixé "_incomplet" pour qu'elle ne compte pas dans la rétention et ne
# fasse pas disparaître une sauvegarde complète plus ancienne.
REMOTE_NAME="${TIMESTAMP}"
if [[ "${BACKUP_FAILED}" -eq 1 ]]; then
    notify_failure "un ou plusieurs éléments n'ont pas pu être sauvegardés (voir ${LOG_FILE})"
    REMOTE_NAME="${TIMESTAMP}_incomplet"
fi

# --------------------------------------------------------------------------
# Transfert vers le NAS via rsync/SSH
# --------------------------------------------------------------------------
log "INFO" "Transfert de la sauvegarde vers ${NAS_USER}@${NAS_HOST}:${NAS_BACKUP_PATH}/${REMOTE_NAME}/ ..."
if ! rsync -az --partial -e "ssh ${SSH_OPTS[*]}" \
    "${BACKUP_DIR}/" \
    "${NAS_USER}@${NAS_HOST}:${NAS_BACKUP_PATH}/${REMOTE_NAME}/"; then
    notify_failure "échec du transfert rsync vers le NAS"
    exit 1
fi
log "INFO" "Transfert terminé."

# Nettoyage du répertoire temporaire local une fois le transfert réussi
rm -rf "${BACKUP_DIR}"

# --------------------------------------------------------------------------
# Rétention : ne garder que les RETENTION_COUNT sauvegardes les plus récentes (les
# noms de dossiers sont des horodatages YYYY-MM-DD_HH-MM-SS, donc triables tels quels).
# Pas de "-mtime +N" en jours : avec des runs espacés ou manuels, ça garderait un nombre
# imprévisible de sauvegardes plutôt qu'un nombre fixe.
# --------------------------------------------------------------------------
log "INFO" "Nettoyage : conservation des ${RETENTION_COUNT} sauvegarde(s) la/les plus récente(s)..."

local_total="$(find "${LOCAL_TMP_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '.\n' 2>/dev/null | wc -l)"
if [[ "${local_total}" -gt "${RETENTION_COUNT}" ]]; then
    find "${LOCAL_TMP_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort \
        | head -n "$((local_total - RETENTION_COUNT))" \
        | while read -r d; do rm -rf -- "${LOCAL_TMP_DIR:?}/${d}"; done
fi

# Sur le NAS, seules les sauvegardes complètes (nom = horodatage exact) comptent dans la
# rétention. Une sauvegarde "_incomplet" est supprimée dès qu'une sauvegarde complète
# plus récente existe ; tant que ce n'est pas le cas, elle est gardée (c'est alors ce
# qu'il y a de plus récent pour les éléments qui ont réussi). Script POSIX (sh du NAS).
ssh "${SSH_OPTS[@]}" "${NAS_USER}@${NAS_HOST}" \
    "sh -s -- '${NAS_BACKUP_PATH}' '${RETENTION_COUNT}'" <<'EOF' || log "WARN" "Échec du nettoyage des anciennes sauvegardes sur le NAS."
cd "$1" || exit 1
keep="$2"
complets=$(find . -mindepth 1 -maxdepth 1 -type d -name '????-??-??_??-??-??' -printf '%f\n' | sort)
total=$(printf '%s\n' "${complets}" | grep -c .)
if [ "${total}" -gt "${keep}" ]; then
    printf '%s\n' "${complets}" | head -n $((total - keep)) \
        | while read -r d; do rm -rf -- "${d}"; done
fi
dernier=$(printf '%s\n' "${complets}" | tail -n 1)
[ -n "${dernier}" ] || exit 0
find . -mindepth 1 -maxdepth 1 -type d -name '*_incomplet' -printf '%f\n' \
    | while read -r d; do
        ts="${d%_incomplet}"
        plus_ancien=$(printf '%s\n%s\n' "${ts}" "${dernier}" | sort | head -n 1)
        if [ "${plus_ancien}" = "${ts}" ] && [ "${ts}" != "${dernier}" ]; then
            rm -rf -- "${d}"
        fi
    done
EOF

if [[ "${BACKUP_FAILED}" -eq 1 ]]; then
    log "WARN" "=== Sauvegarde terminée avec des erreurs (${TIMESTAMP}) ==="
    exit 1
fi

log "INFO" "=== Sauvegarde terminée avec succès (${TIMESTAMP}) ==="
