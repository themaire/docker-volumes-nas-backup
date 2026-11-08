#!/usr/bin/env bash
#
# acces-lecture-sauvegarde.sh
#
# Guichet SSH en LECTURE SEULE pour un agent de surveillance (ex : Hermes).
# Il est prévu pour être la commande forcée d'une clé SSH dédiée, dans
# ~/.ssh/authorized_keys :
#
#   restrict,from="172.16.0.0/12",command="/chemin/vers/acces-lecture-sauvegarde.sh" ssh-ed25519 AAAA... agent
#
# Quelle que soit la commande demandée par le client (ssh hote <commande>), sshd lance
# CE script, qui reçoit la demande dans $SSH_ORIGINAL_COMMAND. Seules les commandes
# de la liste ci-dessous sont acceptées. Rien n'est passé à un shell (pas d'eval), et
# aucune commande ne modifie, n'arrête ou ne supprime quoi que ce soit.
#
# Commandes acceptées (ssh hote aide pour les afficher) :
#   aide                    cette aide
#   verrou                  sauvegarde / restauration en cours ? (test flock réel)
#   dernier-run             journal du dernier run, depuis « Début de la sauvegarde »
#   journal [N]             N dernières lignes de LOG_FILE (défaut 200, max 5000)
#   cron-log [N]            N dernières lignes de cron.log (défaut 100, max 5000)
#   conteneurs              docker ps -a (nom, état, statut, image)
#   nas-liste               dossiers de sauvegarde sur le NAS, avec leur taille
#   nas-archives DOSSIER    archives d'un dossier du NAS, taille en octets
#   local-liste             dossiers de sauvegarde locaux (LOCAL_TMP_DIR), avec leur taille
#
if [ -z "${BASH_VERSION:-}" ]; then
    echo "Erreur : ce script doit être exécuté avec bash." >&2
    exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
CONF_FILE="${SCRIPT_DIR}/docker-backup.conf"

if [[ ! -f "${CONF_FILE}" ]]; then
    echo "Fichier de configuration introuvable : ${CONF_FILE}" >&2
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

BACKUP_LOCK="/tmp/docker-volume-backup.lock"
RESTORE_LOCK="/tmp/docker-volume-restore.lock"
# cron.log est écrit par la ligne cron, dans le même dossier que LOG_FILE (voir README).
CRON_LOG="$(dirname "${LOG_FILE}")/cron.log"
SSH_OPTS=(-p "${NAS_SSH_PORT}" -i "${NAS_SSH_KEY}" -o BatchMode=yes -o ConnectTimeout=10)
# Nom d'un dossier de sauvegarde : horodatage du script, avec ou sans _incomplet.
BACKUP_DIR_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}(_incomplet)?$'

# Trace chaque demande dans le journal système (journalctl -t acces-lecture-sauvegarde).
logger -t acces-lecture-sauvegarde -- "demande : ${SSH_ORIGINAL_COMMAND:-<aucune>}" 2>/dev/null || true

# Découpe la demande en mots, sans aucune interprétation shell ($, ;, |, `...` restent
# du texte brut et feront simplement échouer la validation).
read -r -a ARGS <<< "${SSH_ORIGINAL_COMMAND:-aide}"
CMD="${ARGS[0]:-aide}"
ARG1="${ARGS[1]:-}"

if [[ "${#ARGS[@]}" -gt 2 ]]; then
    echo "Refusé : trop d'arguments. Tapez « aide »." >&2
    exit 2
fi

# Valide un nombre de lignes : entier de 1 à 5000, ou la valeur par défaut si vide.
line_count() {
    local value="$1" default="$2"
    if [[ -z "${value}" ]]; then
        echo "${default}"
    elif [[ "${value}" =~ ^[0-9]+$ && "${value}" -ge 1 && "${value}" -le 5000 ]]; then
        echo "${value}"
    else
        echo "Refusé : le nombre de lignes doit être un entier entre 1 et 5000." >&2
        exit 2
    fi
}

no_arg() {
    if [[ -n "${ARG1}" ]]; then
        echo "Refusé : « ${CMD} » ne prend pas d'argument." >&2
        exit 2
    fi
}

lock_state() {
    local label="$1" lock="$2"
    if [[ ! -e "${lock}" ]]; then
        echo "${label} : LIBRE (fichier de verrou absent)"
    elif flock -n "${lock}" true; then
        echo "${label} : LIBRE"
    else
        echo "${label} : OCCUPÉ (en cours d'exécution)"
    fi
}

case "${CMD}" in
    aide)
        sed -n '/^# Commandes acceptées/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        ;;
    verrou)
        no_arg
        lock_state "Sauvegarde" "${BACKUP_LOCK}"
        lock_state "Restauration" "${RESTORE_LOCK}"
        ;;
    dernier-run)
        no_arg
        if [[ ! -f "${LOG_FILE}" ]]; then
            echo "Journal introuvable : ${LOG_FILE}" >&2
            exit 1
        fi
        # Garde tout ce qui suit le dernier « Début de la sauvegarde ».
        awk '/=== Début de la sauvegarde/ { buf = ""; found = 1 }
             found { buf = buf $0 "\n" }
             END { if (found) printf "%s", buf; else print "Aucun run trouvé dans le journal." }' \
            "${LOG_FILE}"
        ;;
    journal)
        n="$(line_count "${ARG1}" 200)"
        tail -n "${n}" -- "${LOG_FILE}"
        ;;
    cron-log)
        n="$(line_count "${ARG1}" 100)"
        if [[ ! -f "${CRON_LOG}" ]]; then
            echo "cron.log introuvable : ${CRON_LOG} (le cron n'a peut-être encore jamais tourné)"
            exit 0
        fi
        tail -n "${n}" -- "${CRON_LOG}"
        ;;
    conteneurs)
        no_arg
        docker ps -a --format 'table {{.Names}}\t{{.State}}\t{{.Status}}\t{{.Image}}'
        ;;
    nas-liste)
        no_arg
        # Taille en Kio de chaque dossier de sauvegarde, triés par nom (= par date).
        ssh "${SSH_OPTS[@]}" "${NAS_USER}@${NAS_HOST}" \
            "cd '${NAS_BACKUP_PATH}' && for d in */; do [ -d \"\$d\" ] && du -sk \"\$d\"; done" \
            | sort -k2
        ;;
    nas-archives)
        if [[ ! "${ARG1}" =~ ${BACKUP_DIR_RE} ]]; then
            echo "Refusé : DOSSIER doit être un horodatage, ex : 2026-11-08_03-00-01 (ou ..._incomplet)." >&2
            exit 2
        fi
        ssh "${SSH_OPTS[@]}" "${NAS_USER}@${NAS_HOST}" "cd '${NAS_BACKUP_PATH}/${ARG1}' && ls -l"
        ;;
    local-liste)
        no_arg
        if [[ -d "${LOCAL_TMP_DIR}" ]]; then
            listing="$(find "${LOCAL_TMP_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 \
                | xargs -0 -r du -sk | sort -k2)"
            echo "${listing:-Aucune sauvegarde locale dans ${LOCAL_TMP_DIR}}"
        else
            echo "Dossier local absent : ${LOCAL_TMP_DIR}"
        fi
        ;;
    *)
        echo "Refusé : commande inconnue « ${CMD} ». Tapez « aide » pour la liste." >&2
        exit 2
        ;;
esac
