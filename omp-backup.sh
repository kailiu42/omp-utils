#!/usr/bin/env bash
set -euo pipefail

# ── omp-backup.sh ───────────────────────────────────────────────────────
# Create tar.xz backups of OMP and Pi configuration data.
#
# Modes:
#   --mode core       Archive core OMP/Pi config, auth, and context data.
#   --mode full       Archive the OMP and Pi directories.
#
# Options:
#   --dest DIR        Backup destination directory.
#   --keep N          Number of omp-*.tar.xz backups to retain.
#   --omp-dir DIR     Source OMP directory; defaults to ${HOME}/.omp.
#   --pi-dir DIR      Source Pi directory; defaults to ${HOME}/.pi.
# ─────────────────────────────────────────────────────────────────────────

DEST_DIR="/mnt/data/backup/omp/"
MODE="core"
KEEP="30"
OMP_DIR="${HOME}/.omp"
PI_DIR="${HOME}/.pi"

TMP_PATH=""
OMP_LIST_PATH=""
PI_LIST_PATH=""

# ── helpers ─────────────────────────────────────────────────────────────
die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}
info() { printf '  -> %s\n' "$*"; }

usage() {
    printf '%s\n' \
        "Usage: ${0##*/} [--dest DIR] [--mode core|full] [--keep N] [--omp-dir DIR] [--pi-dir DIR]" \
        "" \
        "Create tar.xz backups of OMP and Pi configuration directories." \
        "" \
        "Options:" \
        "  --dest DIR       Backup destination directory (default: /mnt/data/backup/omp/)." \
        "  --mode MODE      Backup mode: core or full (default: core)." \
        "  --keep N         Retain at most N matching backups (default: 30)." \
        "  --omp-dir DIR    Source OMP directory (default: \${HOME}/.omp)." \
        "  --pi-dir DIR     Source Pi directory (default: \${HOME}/.pi; skipped if absent)." \
        "  --help           Show this help."
}

cleanup() {
    if [[ -n "$TMP_PATH" && -e "$TMP_PATH" ]]; then
        rm -f -- "$TMP_PATH"
    fi
    if [[ -n "$OMP_LIST_PATH" && -e "$OMP_LIST_PATH" ]]; then
        rm -f -- "$OMP_LIST_PATH"
    fi
    if [[ -n "$PI_LIST_PATH" && -e "$PI_LIST_PATH" ]]; then
        rm -f -- "$PI_LIST_PATH"
    fi
}
trap cleanup EXIT

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_value() {
    local opt="$1"
    local value="${2:-}"

    [[ -n "$value" && "$value" != --* ]] || die "${opt} requires a value."
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dest)
                require_value "$1" "${2:-}"
                DEST_DIR="$2"
                shift 2
                ;;
            --mode)
                require_value "$1" "${2:-}"
                MODE="$2"
                shift 2
                ;;
            --keep)
                require_value "$1" "${2:-}"
                KEEP="$2"
                shift 2
                ;;
            --omp-dir)
                require_value "$1" "${2:-}"
                OMP_DIR="$2"
                shift 2
                ;;
            --pi-dir)
                require_value "$1" "${2:-}"
                PI_DIR="$2"
                shift 2
                ;;
            --help | -h)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done
}

validate_args() {
    case "$MODE" in
        core | full) ;;
        *) die "--mode must be one of: core, full" ;;
    esac

    [[ "$KEEP" =~ ^[0-9]+$ ]] || die "--keep must be a non-negative integer."
    KEEP=$((10#$KEEP))

    OMP_DIR="${OMP_DIR%/}"
    [[ -n "$OMP_DIR" ]] || die "--omp-dir must not be empty."
    [[ -d "$OMP_DIR" ]] || die "OMP directory does not exist: $OMP_DIR"

    PI_DIR="${PI_DIR%/}"
    [[ -n "$PI_DIR" ]] || die "--pi-dir must not be empty."
    if [[ -e "$PI_DIR" && ! -d "$PI_DIR" ]]; then
        die "Pi directory exists but is not a directory: $PI_DIR"
    fi
}

source_parent() {
    local dir="$1"
    local parent="${dir%/*}"

    if [[ "$parent" == "$dir" ]]; then
        printf '%s\n' "."
    elif [[ -z "$parent" ]]; then
        printf '%s\n' "/"
    else
        printf '%s\n' "$parent"
    fi
}

source_basename() {
    local dir="$1"
    local base="${dir##*/}"

    [[ -n "$base" ]] || die "Refusing to archive the filesystem root as a configuration directory."
    printf '%s\n' "$base"
}

is_runtime_entry() {
    local rel="$1"

    case "$rel" in
        logs/* | agent/sessions/* | wt/* | puppeteer/* | plugins/cache/*) return 0 ;;
        *.db-wal | *.db-shm | *.sqlite-wal | *.sqlite-shm) return 0 ;;
    esac

    return 1
}

add_core_entry() {
    local source_dir="$1"
    local source_base="$2"
    local list_path="$3"
    local path="$4"
    local rel entry

    [[ -e "$path" ]] || return 0

    if [[ "$path" == "$source_dir" ]]; then
        rel=""
    elif [[ "$path" == "$source_dir/"* ]]; then
        rel="${path#"$source_dir"/}"
    else
        die "Internal error: path is outside source directory: $path"
    fi

    if [[ -n "$rel" ]] && is_runtime_entry "$rel"; then
        return 0
    fi

    if [[ -z "$rel" ]]; then
        entry="$source_base"
    else
        entry="${source_base}/${rel}"
    fi

    if [[ -z "${SEEN_ENTRIES[$entry]+x}" ]]; then
        SEEN_ENTRIES["$entry"]=1
        printf '%s\0' "$entry" >>"$list_path"
        CORE_ENTRY_COUNT=$((CORE_ENTRY_COUNT + 1))
    fi
}

collect_find_entries() {
    local source_dir="$1"
    local source_base="$2"
    local list_path="$3"
    local dir="$4"
    shift 4

    [[ -d "$dir" ]] || return 0

    while IFS= read -r -d '' path; do
        add_core_entry "$source_dir" "$source_base" "$list_path" "$path"
    done < <(find "$dir" "$@" -print0)
}

collect_source_core_entries() {
    local source_dir="$1"
    local source_base="$2"
    local list_path="$3"
    local plugin_file

    collect_find_entries "$source_dir" "$source_base" "$list_path" "$source_dir" \
        -maxdepth 1 \
        -type f \
        \( \
        -name '.env' \
        -o -name '*.env' \
        -o -name '*.json' \
        -o -name '*.yml' \
        -o -name '*.yaml' \
        -o -name '*.toml' \
        -o -name 'install-id' \
        -o -iname '*auth*' \
        -o -iname '*token*' \
        -o -iname '*credential*' \
        -o -iname '*secret*' \
        \)

    collect_find_entries "$source_dir" "$source_base" "$list_path" "${source_dir}/agent" \
        -maxdepth 1 \
        -type f \
        \( \
        -name '*.json' \
        -o -name '*.yml' \
        -o -name '*.yaml' \
        -o -name '*.toml' \
        -o -name '*.md' \
        -o -iname '*auth*' \
        -o -iname '*token*' \
        -o -iname '*credential*' \
        -o -iname '*secret*' \
        \)

    collect_find_entries "$source_dir" "$source_base" "$list_path" "${source_dir}/agent/memories"

    for plugin_file in package.json installed_plugins.json omp-plugins.lock.json bun.lock; do
        add_core_entry "$source_dir" "$source_base" "$list_path" "${source_dir}/plugins/${plugin_file}"
    done
}

collect_core_entries() {
    declare -gA SEEN_ENTRIES=()
    declare -g CORE_ENTRY_COUNT=0

    : >"$OMP_LIST_PATH"
    : >"$PI_LIST_PATH"

    collect_source_core_entries "$OMP_DIR" "$OMP_SOURCE_BASE" "$OMP_LIST_PATH"
    if [[ -d "$PI_DIR" ]]; then
        collect_source_core_entries "$PI_DIR" "$PI_SOURCE_BASE" "$PI_LIST_PATH"
    fi

    [[ "$CORE_ENTRY_COUNT" -gt 0 ]] || die "No core backup entries found under: $OMP_DIR or $PI_DIR"
}

archive_core() {
    local -a tar_args=(
        --null
        --no-recursion
        -cJf "$TMP_PATH"
        -C "$OMP_SOURCE_PARENT"
        -T "$OMP_LIST_PATH"
    )

    collect_core_entries

    if [[ -d "$PI_DIR" ]]; then
        tar_args+=(
            -C "$PI_SOURCE_PARENT"
            -T "$PI_LIST_PATH"
        )
    fi

    tar "${tar_args[@]}"
}

archive_full() {
    local -a tar_args=(
        -C "$OMP_SOURCE_PARENT"
        --exclude="${OMP_SOURCE_BASE}/puppeteer"
        --exclude="${OMP_SOURCE_BASE}/puppeteer/*"
        -cJf "$TMP_PATH"
        "$OMP_SOURCE_BASE"
    )

    if [[ -d "$PI_DIR" ]]; then
        tar_args+=(
            -C "$PI_SOURCE_PARENT"
            "$PI_SOURCE_BASE"
        )
    fi

    tar "${tar_args[@]}"
}

next_archive_path() {
    local timestamp archive_name archive_path

    timestamp=$(date +%Y%m%d-%H%M%S)
    archive_name="omp-${MODE}-${timestamp}.tar.xz"
    archive_path="${DEST_DIR%/}/${archive_name}"

    while [[ -e "$archive_path" ]]; do
        sleep 1
        timestamp=$(date +%Y%m%d-%H%M%S)
        archive_name="omp-${MODE}-${timestamp}.tar.xz"
        archive_path="${DEST_DIR%/}/${archive_name}"
    done

    printf '%s\n' "$archive_path"
}

prune_old_backups() {
    local -a backups=()
    local record backup_path delete_count i

    mapfile -d '' -t backups < <(
        find "$DEST_DIR" -maxdepth 1 -type f -name 'omp-*.tar.xz' -printf '%T@ %p\0' |
            sort -z -n
    )

    if [[ ${#backups[@]} -le "$KEEP" ]]; then
        return
    fi

    delete_count=$((${#backups[@]} - KEEP))
    for ((i = 0; i < delete_count; i++)); do
        record="${backups[$i]}"
        backup_path="${record#* }"
        rm -f -- "$backup_path"
        info "Pruned old backup: $backup_path"
    done
}

main() {
    local archive_path

    parse_args "$@"
    validate_args

    need_cmd date
    need_cmd find
    need_cmd mkdir
    need_cmd mv
    need_cmd rm
    need_cmd sort
    need_cmd tar
    need_cmd xz

    mkdir -p -- "$DEST_DIR"

    OMP_SOURCE_PARENT=$(source_parent "$OMP_DIR")
    OMP_SOURCE_BASE=$(source_basename "$OMP_DIR")
    PI_SOURCE_PARENT=$(source_parent "$PI_DIR")
    PI_SOURCE_BASE=$(source_basename "$PI_DIR")
    readonly OMP_SOURCE_PARENT OMP_SOURCE_BASE PI_SOURCE_PARENT PI_SOURCE_BASE

    archive_path=$(next_archive_path)
    TMP_PATH="${DEST_DIR%/}/.${archive_path##*/}.$$.tmp"
    OMP_LIST_PATH="${DEST_DIR%/}/.${archive_path##*/}.$$.omp.files"
    PI_LIST_PATH="${DEST_DIR%/}/.${archive_path##*/}.$$.pi.files"

    case "$MODE" in
        core) archive_core ;;
        full) archive_full ;;
    esac

    mv -f -- "$TMP_PATH" "$archive_path"
    TMP_PATH=""

    prune_old_backups

    info "Created backup: $archive_path"
}

main "$@"
