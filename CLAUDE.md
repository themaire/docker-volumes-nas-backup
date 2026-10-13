# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Two standalone Bash scripts that back up and restore Docker data from this host (a Raspberry Pi running CasaOS) to a NAS over SSH/rsync:

- `backup-docker-volumes.sh <ALL | container...>`: tar.gz each volume/folder, then rsync it to `NAS_BACKUP_PATH/<timestamp>/` and prune old backups.
- `restore-docker-volumes.sh [--list] [--timestamp TS] [--yes] <ALL | container... | --volume ... | --path ...>`: does the reverse.

Both read `docker-backup.conf`, a sourced shell file that sits next to the scripts and can be overridden with `--conf`. `docker-backup.conf.example` is the template. Every new config variable must be added in four places: the `.example` template, the `: "${VAR:=default}"` block in **both** scripts, and the README config table.

The code comments, log messages, usage text and README are all in French, so keep it that way. The original brief is in `claude.md` (lowercase): a bash script to back up Docker volumes to a NAS.

## Checking changes

There are no tests, no build and no linter installed (`shellcheck` is not present). At minimum, run:

```bash
bash -n backup-docker-volumes.sh && bash -n restore-docker-volumes.sh
```

Running either script for real stops and restarts live containers, and a restore **overwrites data**. Never run them to "test" without asking the user. To try a change safely, back up a single throwaway container (`./backup-docker-volumes.sh <container>`) or point `--conf` at a separate config.

## Architecture notes

- **Two kinds of data are covered.** The scripts handle named Docker volumes (`Mounts[].Type == "volume"`) and bind mounts whose source lies under `APPDATA_PATH_PREFIX` (e.g. `/DATA/AppData`, where CasaOS apps keep their data). Bind mounts outside that prefix are ignored.
- **Archive naming is the contract between the two scripts.** A volume is stored as `<volume>.tar.gz`. An app-data folder is stored as `appdata__<key>.tar.gz`, where `key` is the path relative to the prefix with `/` replaced by `__` (`appdata_key` / `appdata_key_to_path`). The restore script decides what each archive is from its filename alone, so any change to the naming must be made in both scripts. The mapping is not reversible for paths that already contain `__`.
- **Backup works per group, never with a global stop.** Containers that share a volume or folder are merged with a small union-find (`PARENT`, `find_root`, `union_containers`, `ITEM_OWNERS`). Each group is then handled in turn: stop its running containers, tar, verify (`tar tzf`), restart at once. In `ALL` mode, orphan volumes (no container mounts them) are archived last, with nothing stopped. The rsync to the NAS runs only after every group has finished.
- **Restore stops only the containers that use the targets.** It finds them with `docker ps --filter volume=<name-or-host-path>`, empties each target's contents (the volume or folder itself stays), then untars into it. It does not recreate deleted containers.
- **All tar work runs inside `ALPINE_IMAGE`** (pinned, default `alpine:3.20`) through `docker run --rm` with `:ro` source mounts, so it never depends on host permissions over the volume data.
- **Safety mechanisms to keep intact:**
  - A `trap cleanup EXIT INT TERM` restarts every container in `STOPPED_CONTAINERS` and calls `NOTIFY_CMD` on failure.
  - A `flock` on `/tmp/docker-volume-backup.lock` (or `-restore.lock`) prevents concurrent runs.
  - `set -euo pipefail` is on, so use the `"${arr[@]-}"` idiom for arrays that may be empty.
- **Retention** keeps the `RETENTION_COUNT` newest timestamp-named directories, both locally and on the NAS (sorted by name, not by `-mtime`). When any item fails, the backup is still uploaded, but as `<timestamp>_incomplet/`:
  - `_incomplet` directories do not count toward retention.
  - Each one is deleted as soon as a newer complete backup exists.
  - Restore never picks one by default.
  - NAS-side pruning is a POSIX `sh -s` heredoc, because the NAS shell is not bash.
- **Restore checks every selected archive with `tar tzf` before the confirmation prompt,** so a corrupt archive aborts the restore before any container is stopped or any data is wiped.
- **`NOTIFY_CMD` runs as `bash -c "$NOTIFY_CMD" notify "<message>"`,** so the message is available as `$1`. The config must use single quotes, because a double-quoted `$1` would be expanded when the config is sourced.
- **SSH** always uses `BatchMode=yes`. If the key is missing, the scripts offer `ssh-keygen` only when stdin and stdout are a TTY, and fail fast otherwise (cron).

## Local config

`docker-backup.conf` is the real config for this machine. It holds the NAS address, the user and the SSH key path, and is gitignored, so read it for host-specific details. Never copy its values into tracked files: the repository is public.
