#!/usr/bin/env bash
set -euo pipefail

# ── omp-session-mgmt.sh ─────────────────────────────────────────────────
# Manage OMP session buckets — merge split buckets or move sessions when
# a project directory is relocated.
#
# Modes:
#   --merge               Detect and merge session buckets split by
#                         symlink/bind-mount aliasing (original behavior).
#
#   --move OLD_PATH NEW_PATH
#                         Migrate session data when one project directory
#                         is moved from OLD_PATH to NEW_PATH, so that
#                         /resume works from the new location.
#
#   --move-prefix OLD_PREFIX NEW_PREFIX
#                         Migrate every session whose cwd is OLD_PREFIX or
#                         under OLD_PREFIX to the matching NEW_PREFIX path.
#
# All modes accept:
#   --dry-run             Show what would be done without making changes.
#   --yes / -y            Skip confirmation prompts (use with caution).
# ─────────────────────────────────────────────────────────────────────────

DRY_RUN=false
AUTO_YES=false
MODE=""

# Parse global flags
REST_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --yes|-y)  AUTO_YES=true; shift ;;
        --merge)   MODE="merge"; shift ;;
        --move)    MODE="move"; shift; break ;;
        --move-prefix) MODE="move_prefix"; shift; break ;;
        *)         REST_ARGS+=("$1"); shift ;;
    esac
done
# After --mode flags, collect remaining positional args from the break above.
if [[ "$MODE" == "move" || "$MODE" == "move_prefix" ]]; then
    REST_ARGS+=("$@")
fi
set -- "${REST_ARGS[@]}"

OMP_DIR="${HOME}/.omp"
SESSIONS_DIR="${OMP_DIR}/agent/sessions"
AGENT_DB="${OMP_DIR}/agent/agent.db"
HISTORY_DB="${OMP_DIR}/agent/history.db"
STATS_DB="${OMP_DIR}/stats.db"
TERMINAL_DIR="${OMP_DIR}/agent/terminal-sessions"

# ── helpers ─────────────────────────────────────────────────────────────
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  → $*"; }
warn() { echo "  ⚠ $*"; }
run()  {
    if $DRY_RUN; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

normalize_cwd_text() {
    realpath -m "$1"
}

canonical_path() {
    local path="$1"
    realpath "$path" 2>/dev/null || normalize_cwd_text "$path"
}

encode_absolute_bucket_name() {
    local path="${1#/}"       # strip leading /
    path="${path%/}"          # strip trailing /
    path="${path//\//-}"
    path="${path//:/-}"
    printf -- '--%s--' "$path"
}

legacy_absolute_bucket_name() {
    encode_absolute_bucket_name "$(normalize_cwd_text "$1")"
}

canonical_absolute_bucket_name() {
    encode_absolute_bucket_name "$(canonical_path "$1")"
}
# Escape a string for safe use in SQLite single-quoted literals.
sql_escape() { printf '%s' "${1//\'/\'\'}"; }

# OMP bucket name from a workdir path.
# Current OMP stores paths under $HOME as home-relative buckets:
#   /home/kai/repo/ai/foo -> -repo-ai-foo
# Non-home paths keep the legacy absolute encoding:
#   /mnt/data/repo/ai/foo -> --mnt-data-repo-ai-foo--
omp_bucket_name() {
    local path home tmp_root relative
    path=$(canonical_path "$1")
    home=$(canonical_path "$HOME")
    tmp_root=$(canonical_path "${TMPDIR:-/tmp}")

    if path_under_prefix "$path" "$home"; then
        if [[ "$path" == "$home" ]]; then
            printf '%s' "-"
            return
        fi
        relative="${path#"$home"/}"
        relative="${relative//\//-}"
        relative="${relative//:/-}"
        printf -- '-%s' "$relative"
        return
    fi

    if path_under_prefix "$path" "$tmp_root"; then
        if [[ "$path" == "$tmp_root" ]]; then
            printf '%s' "-tmp"
            return
        fi
        relative="${path#"$tmp_root"/}"
        relative="${relative//\//-}"
        relative="${relative//:/-}"
        printf -- '-tmp-%s' "$relative"
        return
    fi

    canonical_absolute_bucket_name "$path"
}

path_under_prefix() {
    local path="$1"
    local prefix="$2"
    [[ "$path" == "$prefix" || "$path" == "$prefix/"* ]]
}

bucket_candidates() {
    local path="$1"
    local bucket
    declare -A seen=()

    for bucket in "$(omp_bucket_name "$path")" "$(legacy_absolute_bucket_name "$path")" "$(canonical_absolute_bucket_name "$path")"; do
        if [[ -z "${seen[$bucket]:-}" ]]; then
            printf '%s\n' "$bucket"
            seen[$bucket]=1
        fi
    done
}

replace_path_prefix() {
    local path="$1"
    local old_prefix="$2"
    local new_prefix="$3"

    if [[ "$path" == "$old_prefix" ]]; then
        printf '%s' "$new_prefix"
    else
        printf '%s/%s' "$new_prefix" "${path#"$old_prefix"/}"
    fi
}

# ── usage ───────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run] [--yes|-y] --merge
       $(basename "$0") [--dry-run] [--yes|-y] --move OLD_PATH NEW_PATH
       $(basename "$0") [--dry-run] [--yes|-y] --move-prefix OLD_PREFIX NEW_PREFIX

Modes:
  --merge           Detect and merge session buckets split by workdir
                    symlink/bind-mount aliasing.
  --move OLD NEW
                    Migrate all session data for one project that moved from
                    OLD_PATH to NEW_PATH, enabling /resume from the new path.
  --move-prefix OLD NEW
                    Migrate every session whose cwd is OLD_PATH or under
                    OLD_PATH to the matching NEW_PATH location.

Options:
  --dry-run     Show actions without executing them.
  --yes / -y    Skip confirmation prompts.
EOF
    exit 0
}

# ── pre-flight OMP check ───────────────────────────────────────────────
preflight_check() {
    if $DRY_RUN; then
        return
    fi
    local omp_pids
    omp_pids=$(pgrep -f '/usr/bin/omp|/bin/omp' 2>/dev/null || true)
    if [[ -n "$omp_pids" ]]; then
        warn "OMP appears to be running (pids: $omp_pids)"
        warn "Session and DB files may be locked. Exit all OMP sessions first."
        if ! $AUTO_YES; then
            read -r -p "Continue anyway? [y/N] " answer
            [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
        fi
    fi
}

# ── move mode ───────────────────────────────────────────────────────────
do_move() {
    local old_path="$1"
    local new_path="$2"

    # Validate that both paths are absolute.
    if [[ "$old_path" != /* ]] || [[ "$new_path" != /* ]]; then
        die "Both OLD_PATH and NEW_PATH must be absolute paths."
    fi

    # Normalise cwd text like OMP stores it in JSONL/DB: lexical absolute path,
    # without resolving symlink aliases. Bucket naming is canonicalised separately.
    old_path=$(normalize_cwd_text "$old_path")
    new_path=$(normalize_cwd_text "$new_path")

    local old_bucket new_bucket
    local -a old_buckets old_path_prefixes
    old_bucket=$(omp_bucket_name "$old_path")
    new_bucket=$(omp_bucket_name "$new_path")
    mapfile -t old_buckets < <(bucket_candidates "$old_path")

    local old_dir="${SESSIONS_DIR}/${old_bucket}"
    local new_dir="${SESSIONS_DIR}/${new_bucket}"

    echo "=== OMP Session Move Plan ===================================="
    echo "  Old path:   ${old_path}"
    echo "  New path:   ${new_path}"
    echo "  Old bucket: ${old_bucket}"
    if [[ ${#old_buckets[@]} -gt 1 ]]; then
        echo "  Old bucket candidates: ${old_buckets[*]}"
    fi
    echo "  New bucket: ${new_bucket}"
    echo "=============================================================="

    if $DRY_RUN; then
        echo ""
        echo "Dry run complete. Re-run without --dry-run to execute."
        exit 0
    fi

    if ! $AUTO_YES; then
        echo ""
        read -r -p "Proceed with migration? [y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    fi

    # ── 1. Create new bucket directory if it doesn't exist ───────────
    if [[ ! -d "$new_dir" ]]; then
        info "Creating bucket directory: ${new_bucket}"
        run mkdir -p "$new_dir"
    fi

    # ── 2. Update cwd inside JSONL session files (regardless of bucket location) ──
    info "Updating cwd in session JSONL files …"
    # Walk every JSONL in every bucket — some sessions may exist under old bucket,
    # some under new bucket if partially created, etc.
    find "$SESSIONS_DIR" -maxdepth 2 -name '*.jsonl' -print0 2>/dev/null \
        | while IFS= read -r -d '' jsonl; do
              # Check whether the first line (session header) has the old cwd.
              local first_line
              first_line=$(head -1 "$jsonl")
              local old_json_cwd
              old_json_cwd=$(echo "$first_line" | jq -r '.cwd // empty' 2>/dev/null || true)
              if [[ "$old_json_cwd" != "$old_path" ]]; then
                  continue
              fi
              local tmp
              tmp="${jsonl}.tmp"
              echo "$first_line" | jq -c --arg cwd "$new_path" '.cwd = $cwd' > "$tmp"
              echo >> "$tmp"
              tail -n +2 "$jsonl" >> "$tmp"
              run mv "$tmp" "$jsonl"
          done

    # ── 3. Move session files from every old bucket candidate ─────────
    for old_bucket in "${old_buckets[@]}"; do
        old_dir="${SESSIONS_DIR}/${old_bucket}"
        if [[ "$old_dir" == "$new_dir" ]]; then
            continue
        fi

        if [[ -d "$old_dir" ]]; then
            shopt -s nullglob
            local sessions_to_move=("$old_dir"/*.jsonl)
            shopt -u nullglob
            if [[ ${#sessions_to_move[@]} -gt 0 ]]; then
                for session_jsonl in "${sessions_to_move[@]}"; do
                    local session_id
                    session_id=$(basename "$session_jsonl" .jsonl)
                    local companion="${old_dir}/${session_id}"
                    info "Moving session ${session_id} from ${old_bucket} to ${new_bucket}"
                    run mv "$session_jsonl" "$new_dir/"
                    if [[ -d "$companion" ]]; then
                        run mv "$companion" "$new_dir/"
                    fi
                done
            fi

            # Remove old bucket if empty
            local remaining
            remaining=$(find "$old_dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
            if [[ "$remaining" -eq 0 ]]; then
                info "Removing empty bucket: ${old_bucket}"
                run rmdir "$old_dir"
            else
                warn "Bucket ${old_bucket} not empty after move ($remaining entries) — skipping rmdir"
            fi
        else
            info "Old bucket ${old_bucket} does not exist on disk — only updating DB records"
        fi
    done

    # Build path prefixes for session_file rewrites. Include legacy bucket
    # candidates because older OMP versions stored home paths as --home-...--.
    for old_bucket in "${old_buckets[@]}"; do
        old_path_prefixes+=("${SESSIONS_DIR}/${old_bucket}")
    done
    local new_path_prefix="${SESSIONS_DIR}/${new_bucket}"
    local e_old_cwd e_new_cwd e_new_prefix
    e_old_cwd=$(sql_escape "$old_path")
    e_new_cwd=$(sql_escape "$new_path")
    e_new_prefix=$(sql_escape "$new_path_prefix")

    # ── 4. Update agent.db ──────────────────────────────────────────
    if [[ -f "$AGENT_DB" ]]; then
        info "Updating agent.db …"
        run sqlite3 "$AGENT_DB" <<SQL
UPDATE threads
SET cwd = '${e_new_cwd}'
WHERE cwd = '${e_old_cwd}';
SQL
        for old_path_prefix in "${old_path_prefixes[@]}"; do
            local e_old_prefix
            e_old_prefix=$(sql_escape "$old_path_prefix")
            run sqlite3 "$AGENT_DB" <<SQL
UPDATE threads
SET rollout_path = replace(rollout_path, '${e_old_prefix}/', '${e_new_prefix}/')
WHERE rollout_path LIKE '${e_old_prefix}/%';
SQL
        done
    fi

    # ── 5. Update history.db ────────────────────────────────────────
    if [[ -f "$HISTORY_DB" ]]; then
        info "Updating history.db …"
        run sqlite3 "$HISTORY_DB" <<SQL
UPDATE history
SET cwd = '${e_new_cwd}'
WHERE cwd = '${e_old_cwd}';
SQL
    fi

    # ── 6. Update stats.db ──────────────────────────────────────────
    if [[ -f "$STATS_DB" ]]; then
        info "Updating stats.db …"
        for old_path_prefix in "${old_path_prefixes[@]}"; do
            local e_old_prefix
            e_old_prefix=$(sql_escape "$old_path_prefix")
            run sqlite3 "$STATS_DB" <<SQL
UPDATE messages
SET session_file = replace(session_file, '${e_old_prefix}/', '${e_new_prefix}/'),
    folder       = CASE WHEN folder = '${e_old_cwd}' THEN '${e_new_cwd}' ELSE folder END
WHERE folder = '${e_old_cwd}' OR session_file LIKE '${e_old_prefix}/%';

UPDATE user_messages
SET session_file = replace(session_file, '${e_old_prefix}/', '${e_new_prefix}/'),
    folder       = CASE WHEN folder = '${e_old_cwd}' THEN '${e_new_cwd}' ELSE folder END
WHERE folder = '${e_old_cwd}' OR session_file LIKE '${e_old_prefix}/%';

DELETE FROM file_offsets
WHERE session_file LIKE '${e_old_prefix}/%';
SQL
        done
    fi

    # ── 7. Update terminal-sessions ─────────────────────────────────
    if [[ -d "$TERMINAL_DIR" ]]; then
        info "Updating terminal-sessions …"
        for ts_file in "$TERMINAL_DIR"/pts-*; do
            [[ -f "$ts_file" ]] || continue
            local line1 line2 new_line1 new_line2 updated
            line1=$(head -1 "$ts_file")
            line2=$(tail -1 "$ts_file")
            new_line1="$line1"
            new_line2="$line2"
            updated=false

            if [[ "$line1" == "$old_path" ]]; then
                new_line1="$new_path"
                updated=true
            fi

            for old_path_prefix in "${old_path_prefixes[@]}"; do
                if [[ "$line2" == "${old_path_prefix}/"* ]]; then
                    new_line2="${new_path_prefix}/${line2#"${old_path_prefix}"/}"
                    updated=true
                    break
                fi
            done

            if $updated; then
                printf '%s\n%s\n' "$new_line1" "$new_line2" > "${ts_file}.tmp"
                run mv "${ts_file}.tmp" "$ts_file"
            fi
        done
    fi

    echo ""
    echo "=== Move complete ============================================="
    echo "Session data migrated: ${old_path} → ${new_path}"
    echo "You should now be able to /resume sessions from the new workdir."
}

do_move_prefix() {
    local old_prefix="$1"
    local new_prefix="$2"

    # Validate that both paths are absolute.
    if [[ "$old_prefix" != /* ]] || [[ "$new_prefix" != /* ]]; then
        die "Both OLD_PREFIX and NEW_PREFIX must be absolute paths."
    fi

    # Normalise cwd text like OMP stores it in JSONL/DB: lexical absolute path,
    # without resolving symlink aliases. Bucket naming is canonicalised separately.
    old_prefix=$(normalize_cwd_text "$old_prefix")
    new_prefix=$(normalize_cwd_text "$new_prefix")

    declare -A MOVE_PATHS=()
    local jsonl first_line cwd db_path folder

    if [[ -d "$SESSIONS_DIR" ]]; then
        while IFS= read -r -d '' jsonl; do
            first_line=$(head -1 "$jsonl")
            cwd=$(echo "$first_line" | jq -r '.cwd // empty' 2>/dev/null || true)
            if [[ -n "$cwd" ]] && path_under_prefix "$cwd" "$old_prefix"; then
                MOVE_PATHS[$cwd]=$(replace_path_prefix "$cwd" "$old_prefix" "$new_prefix")
            fi
        done < <(find "$SESSIONS_DIR" -maxdepth 2 -name '*.jsonl' -print0 2>/dev/null)
    fi

    if [[ -f "$AGENT_DB" ]]; then
        while IFS= read -r db_path; do
            if [[ -n "$db_path" ]] && path_under_prefix "$db_path" "$old_prefix"; then
                MOVE_PATHS[$db_path]=$(replace_path_prefix "$db_path" "$old_prefix" "$new_prefix")
            fi
        done < <(sqlite3 "$AGENT_DB" "SELECT DISTINCT cwd FROM threads WHERE cwd IS NOT NULL AND cwd != '';" 2>/dev/null || true)
    fi

    if [[ -f "$HISTORY_DB" ]]; then
        while IFS= read -r db_path; do
            if [[ -n "$db_path" ]] && path_under_prefix "$db_path" "$old_prefix"; then
                MOVE_PATHS[$db_path]=$(replace_path_prefix "$db_path" "$old_prefix" "$new_prefix")
            fi
        done < <(sqlite3 "$HISTORY_DB" "SELECT DISTINCT cwd FROM history WHERE cwd IS NOT NULL AND cwd != '';" 2>/dev/null || true)
    fi

    if [[ -f "$STATS_DB" ]]; then
        while IFS= read -r folder; do
            if [[ -n "$folder" ]] && path_under_prefix "$folder" "$old_prefix"; then
                MOVE_PATHS[$folder]=$(replace_path_prefix "$folder" "$old_prefix" "$new_prefix")
            fi
        done < <(sqlite3 "$STATS_DB" "SELECT DISTINCT folder FROM messages WHERE folder IS NOT NULL AND folder != '' UNION SELECT DISTINCT folder FROM user_messages WHERE folder IS NOT NULL AND folder != '';" 2>/dev/null || true)
    fi

    if [[ ${#MOVE_PATHS[@]} -eq 0 ]]; then
        echo "No sessions found under ${old_prefix}. Nothing to move."
        exit 0
    fi

    mapfile -t move_sources < <(printf '%s\n' "${!MOVE_PATHS[@]}" | sort)

    echo "=== OMP Session Prefix Move Plan ============================="
    echo "  Old prefix: ${old_prefix}"
    echo "  New prefix: ${new_prefix}"
    echo ""
    for old_path in "${move_sources[@]}"; do
        new_path="${MOVE_PATHS[$old_path]}"
        echo "  ${old_path}"
        echo "    → ${new_path}"
        echo "    bucket: $(omp_bucket_name "$old_path") → $(omp_bucket_name "$new_path")"
    done
    echo "=============================================================="

    if $DRY_RUN; then
        echo ""
        echo "Dry run complete. Re-run without --dry-run to execute."
        exit 0
    fi

    if ! $AUTO_YES; then
        echo ""
        read -r -p "Proceed with prefix migration? [y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    fi

    # ── 1. Update cwd inside JSONL session files before moving buckets ──
    if [[ -d "$SESSIONS_DIR" ]]; then
        info "Updating cwd in session JSONL files …"
        while IFS= read -r -d '' jsonl; do
            first_line=$(head -1 "$jsonl")
            cwd=$(echo "$first_line" | jq -r '.cwd // empty' 2>/dev/null || true)
            if [[ -z "${MOVE_PATHS[$cwd]:-}" ]]; then
                continue
            fi
            local tmp
            tmp="${jsonl}.tmp"
            echo "$first_line" | jq -c --arg cwd "${MOVE_PATHS[$cwd]}" '.cwd = $cwd' > "$tmp"
            echo >> "$tmp"
            tail -n +2 "$jsonl" >> "$tmp"
            run mv "$tmp" "$jsonl"
        done < <(find "$SESSIONS_DIR" -maxdepth 2 -name '*.jsonl' -print0 2>/dev/null)
    fi

    # ── 2. Move session buckets and update records per discovered cwd ──
    for old_path in "${move_sources[@]}"; do
        local new_path old_bucket new_bucket old_dir new_dir old_path_prefix new_path_prefix
        local e_old_cwd e_new_cwd e_new_prefix
        local -a old_buckets=() old_path_prefixes=()

        new_path="${MOVE_PATHS[$old_path]}"
        old_bucket=$(omp_bucket_name "$old_path")
        new_bucket=$(omp_bucket_name "$new_path")
        mapfile -t old_buckets < <(bucket_candidates "$old_path")
        new_dir="${SESSIONS_DIR}/${new_bucket}"

        echo ""
        echo "── Moving ${old_path} → ${new_path} ──"

        if [[ ! -d "$new_dir" ]]; then
            info "Creating bucket directory: ${new_bucket}"
            run mkdir -p "$new_dir"
        fi

        for old_bucket in "${old_buckets[@]}"; do
            old_dir="${SESSIONS_DIR}/${old_bucket}"
            if [[ "$old_dir" == "$new_dir" ]]; then
                continue
            fi

            if [[ -d "$old_dir" ]]; then
                shopt -s nullglob
                local sessions_to_move=("$old_dir"/*.jsonl)
                shopt -u nullglob
                if [[ ${#sessions_to_move[@]} -gt 0 ]]; then
                    for session_jsonl in "${sessions_to_move[@]}"; do
                        local session_id companion
                        session_id=$(basename "$session_jsonl" .jsonl)
                        companion="${old_dir}/${session_id}"
                        info "Moving session ${session_id} from ${old_bucket} to ${new_bucket}"
                        run mv "$session_jsonl" "$new_dir/"
                        if [[ -d "$companion" ]]; then
                            run mv "$companion" "$new_dir/"
                        fi
                    done
                fi

                local remaining
                remaining=$(find "$old_dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
                if [[ "$remaining" -eq 0 ]]; then
                    info "Removing empty bucket: ${old_bucket}"
                    run rmdir "$old_dir"
                else
                    warn "Bucket ${old_bucket} not empty after move ($remaining entries) — skipping rmdir"
                fi
            else
                info "Old bucket ${old_bucket} does not exist on disk — only updating DB records"
            fi
        done

        for old_bucket in "${old_buckets[@]}"; do
            old_path_prefixes+=("${SESSIONS_DIR}/${old_bucket}")
        done
        new_path_prefix="${SESSIONS_DIR}/${new_bucket}"
        e_old_cwd=$(sql_escape "$old_path")
        e_new_cwd=$(sql_escape "$new_path")
        e_new_prefix=$(sql_escape "$new_path_prefix")

        if [[ -f "$AGENT_DB" ]]; then
            info "Updating agent.db …"
            run sqlite3 "$AGENT_DB" <<SQL
UPDATE threads
SET cwd = '${e_new_cwd}'
WHERE cwd = '${e_old_cwd}';
SQL
            for old_path_prefix in "${old_path_prefixes[@]}"; do
                local e_old_prefix
                e_old_prefix=$(sql_escape "$old_path_prefix")
                run sqlite3 "$AGENT_DB" <<SQL
UPDATE threads
SET rollout_path = replace(rollout_path, '${e_old_prefix}/', '${e_new_prefix}/')
WHERE rollout_path LIKE '${e_old_prefix}/%';
SQL
            done
        fi

        if [[ -f "$HISTORY_DB" ]]; then
            info "Updating history.db …"
            run sqlite3 "$HISTORY_DB" <<SQL
UPDATE history
SET cwd = '${e_new_cwd}'
WHERE cwd = '${e_old_cwd}';
SQL
        fi

        if [[ -f "$STATS_DB" ]]; then
            info "Updating stats.db …"
            for old_path_prefix in "${old_path_prefixes[@]}"; do
                local e_old_prefix
                e_old_prefix=$(sql_escape "$old_path_prefix")
                run sqlite3 "$STATS_DB" <<SQL
UPDATE messages
SET session_file = replace(session_file, '${e_old_prefix}/', '${e_new_prefix}/'),
    folder       = CASE WHEN folder = '${e_old_cwd}' THEN '${e_new_cwd}' ELSE folder END
WHERE folder = '${e_old_cwd}' OR session_file LIKE '${e_old_prefix}/%';

UPDATE user_messages
SET session_file = replace(session_file, '${e_old_prefix}/', '${e_new_prefix}/'),
    folder       = CASE WHEN folder = '${e_old_cwd}' THEN '${e_new_cwd}' ELSE folder END
WHERE folder = '${e_old_cwd}' OR session_file LIKE '${e_old_prefix}/%';

DELETE FROM file_offsets
WHERE session_file LIKE '${e_old_prefix}/%';
SQL
            done
        fi

        if [[ -d "$TERMINAL_DIR" ]]; then
            info "Updating terminal-sessions …"
            for ts_file in "$TERMINAL_DIR"/pts-*; do
                [[ -f "$ts_file" ]] || continue
                local line1 line2 new_line1 new_line2 updated
                line1=$(head -1 "$ts_file")
                line2=$(tail -1 "$ts_file")
                new_line1="$line1"
                new_line2="$line2"
                updated=false

                if [[ "$line1" == "$old_path" ]]; then
                    new_line1="$new_path"
                    updated=true
                fi

                for old_path_prefix in "${old_path_prefixes[@]}"; do
                    if [[ "$line2" == "${old_path_prefix}/"* ]]; then
                        new_line2="${new_path_prefix}/${line2#"${old_path_prefix}"/}"
                        updated=true
                        break
                    fi
                done

                if $updated; then
                    printf '%s\n%s\n' "$new_line1" "$new_line2" > "${ts_file}.tmp"
                    run mv "${ts_file}.tmp" "$ts_file"
                fi
            done
        fi
    done

    echo ""
    echo "=== Prefix move complete ====================================="
    echo "Session data migrated: ${old_prefix}/* → ${new_prefix}/*"
    echo "You should now be able to /resume sessions from the new workdirs."
}

# ── merge mode ──────────────────────────────────────────────────────────
do_merge() {
    declare -A BUCKET_CWD    # bucket_name → cwd (from first JSONL)
    declare -A BUCKET_REAL   # bucket_name → realpath(cwd) if exists
    declare -A CWD_BUCKET    # (canonical) cwd → bucket_name

    # Read every non-empty bucket's cwd from its first session file.
    for bucket_dir in "$SESSIONS_DIR"/*/; do
        [[ -d "$bucket_dir" ]] || continue
        bucket_name=$(basename "$bucket_dir")

        # pick first jsonl
        jsonl=$(find "$bucket_dir" -maxdepth 1 -name '*.jsonl' -print -quit 2>/dev/null || true)
        if [[ -z "$jsonl" ]]; then
            BUCKET_CWD[$bucket_name]=""
            continue
        fi

        cwd=$(head -1 "$jsonl" | jq -r '.cwd // empty' 2>/dev/null || true)
        BUCKET_CWD[$bucket_name]="$cwd"

        if [[ -n "$cwd" ]]; then
            real=$(realpath "$cwd" 2>/dev/null || echo "")
            BUCKET_REAL[$bucket_name]="$real"
            # register under the real/physical path as canonical
            if [[ -n "$real" && -z "${CWD_BUCKET[$real]:-}" ]]; then
                CWD_BUCKET[$real]="$bucket_name"
            fi
        fi
    done

    # ── find merge candidates ────────────────────────────────────────
    local -A MERGE_PLAN=()

    for old_bucket in "${!BUCKET_CWD[@]}"; do
        cwd="${BUCKET_CWD[$old_bucket]}"
        [[ -n "$cwd" ]] || continue

        # Try matching by realpath first.
        real="${BUCKET_REAL[$old_bucket]:-}"
        if [[ -n "$real" ]] && [[ -n "${CWD_BUCKET[$real]:-}" ]]; then
            canon="${CWD_BUCKET[$real]}"
            if [[ "$canon" != "$old_bucket" ]]; then
                MERGE_PLAN[$old_bucket]="$canon"
                continue
            fi
        fi

        # Fallback A: if cwd starts with HOME, compute /mnt/data equivalent
        # and check whether a matching bucket already exists in BUCKET_CWD.
        if [[ "$cwd" == "${HOME}/"* ]]; then
            alt_cwd="${cwd/#$HOME\//\/mnt\/data\/}"

            # A1: check if another bucket already has this cwd
            for canon in "${!BUCKET_CWD[@]}"; do
                if [[ "${BUCKET_CWD[$canon]}" == "$alt_cwd" ]]; then
                    if [[ "$canon" != "$old_bucket" ]]; then
                        MERGE_PLAN[$old_bucket]="$canon"
                        break 2
                    fi
                fi
            done

            # A2: check if the canonical bucket name exists on disk
            #     (handles empty canonical buckets with no JSONL files)
            canon_name=$(omp_bucket_name "$alt_cwd")
            if [[ -d "${SESSIONS_DIR}/${canon_name}" && "$canon_name" != "$old_bucket" ]]; then
                BUCKET_CWD[$canon_name]="$alt_cwd"
                BUCKET_REAL[$canon_name]="$alt_cwd"
                CWD_BUCKET["$alt_cwd"]="$canon_name"
                MERGE_PLAN[$old_bucket]="$canon_name"
                continue
            fi
        fi
    done

    # ── nothing to do ────────────────────────────────────────────────
    if [[ ${#MERGE_PLAN[@]} -eq 0 ]]; then
        echo "No split session buckets found. Nothing to merge."
        exit 0
    fi

    echo "=== OMP Session Merge Plan =================================="
    for old in "${!MERGE_PLAN[@]}"; do
        canon="${MERGE_PLAN[$old]}"
        echo "  ${old}"
        echo "    → ${canon}"
        echo "    cwd: ${BUCKET_CWD[$old]:-?}  →  ${BUCKET_CWD[$canon]:-?}"
    done
    echo "============================================================="

    if $DRY_RUN; then
        echo "Dry run complete. Re-run without --dry-run to execute."
        exit 0
    fi

    if ! $AUTO_YES; then
        read -r -p "Proceed with merge? [y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    fi

    # ── execute merges ───────────────────────────────────────────────
    for old_bucket in "${!MERGE_PLAN[@]}"; do
        canon_bucket="${MERGE_PLAN[$old_bucket]}"
        old_cwd="${BUCKET_CWD[$old_bucket]}"
        canon_cwd="${BUCKET_CWD[$canon_bucket]}"

        old_dir="${SESSIONS_DIR}/${old_bucket}"
        canon_dir="${SESSIONS_DIR}/${canon_bucket}"

        echo ""
        echo "── Merging ${old_bucket} → ${canon_bucket} ──"

        # Build path substitution patterns.
        old_path_prefix="${SESSIONS_DIR}/${old_bucket}"
        new_path_prefix="${SESSIONS_DIR}/${canon_bucket}"

        # SQL-escaped copies.
        e_old_cwd=$(sql_escape "$old_cwd")
        e_canon_cwd=$(sql_escape "$canon_cwd")
        e_old_prefix=$(sql_escape "$old_path_prefix")
        e_new_prefix=$(sql_escape "$new_path_prefix")

        # ── 1. Move session files ────────────────────────────────────
        shopt -s nullglob
        sessions_to_move=("$old_dir"/*.jsonl)
        shopt -u nullglob

        if [[ ${#sessions_to_move[@]} -eq 0 ]]; then
            info "No jsonl files in $old_bucket — skipping file move"
        else
            for session_jsonl in "${sessions_to_move[@]}"; do
                session_id=$(basename "$session_jsonl" .jsonl)
                companion_dir="${old_dir}/${session_id}"

                info "Moving session ${session_id}"

                # Fix the cwd in the first line of the JSONL
                if [[ -n "$canon_cwd" && "$old_cwd" != "$canon_cwd" ]]; then
                    tmp_jsonl="${session_jsonl}.tmp"
                    head -1 "$session_jsonl" | jq -c --arg cwd "$canon_cwd" '.cwd = $cwd' > "$tmp_jsonl"
                    echo >> "$tmp_jsonl"
                    tail -n +2 "$session_jsonl" >> "$tmp_jsonl"
                    run mv "$tmp_jsonl" "$session_jsonl"
                fi

                # Move jsonl to canonical bucket
                run mv "$session_jsonl" "$canon_dir/"

                # Move companion directory if it exists
                if [[ -d "$companion_dir" ]]; then
                    run mv "$companion_dir" "$canon_dir/"
                fi
            done
        fi

        # ── 2. Update agent.db ───────────────────────────────────────
        if [[ -f "$AGENT_DB" ]]; then
            info "Updating agent.db …"
            run sqlite3 "$AGENT_DB" <<SQL
UPDATE threads
SET cwd = '${e_canon_cwd}'
WHERE cwd = '${e_old_cwd}';

UPDATE threads
SET rollout_path = replace(rollout_path, '${e_old_prefix}/', '${e_new_prefix}/')
WHERE rollout_path LIKE '${e_old_prefix}/%';
SQL
        fi

        # ── 3. Update history.db ─────────────────────────────────────
        if [[ -f "$HISTORY_DB" ]]; then
            info "Updating history.db …"
            run sqlite3 "$HISTORY_DB" <<SQL
UPDATE history
SET cwd = '${e_canon_cwd}'
WHERE cwd = '${e_old_cwd}';
SQL
        fi

        # ── 4. Update stats.db ───────────────────────────────────────
        if [[ -f "$STATS_DB" ]]; then
            info "Updating stats.db …"
            run sqlite3 "$STATS_DB" <<SQL
UPDATE messages
SET session_file = replace(session_file, '${e_old_prefix}/', '${e_new_prefix}/'),
    folder       = '${e_canon_cwd}'
WHERE folder = '${e_old_cwd}';

UPDATE user_messages
SET session_file = replace(session_file, '${e_old_prefix}/', '${e_new_prefix}/'),
    folder       = '${e_canon_cwd}'
WHERE folder = '${e_old_cwd}';

-- file_offsets: remove old ones (stats daemon will rescan on next access)
DELETE FROM file_offsets
WHERE session_file LIKE '${e_old_prefix}/%';
SQL
        fi

        # ── 5. Update terminal-sessions ──────────────────────────────
        if [[ -d "$TERMINAL_DIR" ]]; then
            info "Updating terminal-sessions …"
            for ts_file in "$TERMINAL_DIR"/pts-*; do
                [[ -f "$ts_file" ]] || continue
                # These are 2-line files: line1=cwd, line2=session_path
                line1=$(head -1 "$ts_file")
                line2=$(tail -1 "$ts_file")
                new_line1="$line1"
                new_line2="$line2"
                updated=false

                if [[ "$line1" == "$old_cwd" ]]; then
                    new_line1="$canon_cwd"
                    updated=true
                fi

                if [[ "$line2" == "${old_path_prefix}/"* ]]; then
                    new_line2="${new_path_prefix}/${line2#"${old_path_prefix}"/}"
                    updated=true
                fi

                if $updated; then
                    printf '%s\n%s\n' "$new_line1" "$new_line2" > "${ts_file}.tmp"
                    run mv "${ts_file}.tmp" "$ts_file"
                fi
            done
        fi

        # ── 6. Remove empty old bucket ───────────────────────────────
        if [[ -d "$old_dir" ]]; then
            remaining=$(find "$old_dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
            if [[ "$remaining" -eq 0 ]]; then
                info "Removing empty bucket: ${old_bucket}"
                run rmdir "$old_dir"
            else
                warn "Bucket ${old_bucket} not empty after merge ($remaining entries) — skipping rmdir"
            fi
        fi
    done

    echo ""
    echo "=== Merge complete ==========================================="
    echo "You should now be able to /resume sessions from the canonical workdir."
    echo "If you use a wrapper script (like ./omp), ensure it calls the"
    echo "OMP binary with \$(pwd -P) as the workdir to prevent future splits."
}

# ── main dispatch ───────────────────────────────────────────────────────
if [[ "$MODE" == "merge" ]]; then
    preflight_check
    do_merge
elif [[ "$MODE" == "move" ]]; then
    if [[ $# -ne 2 ]]; then
        echo "ERROR: --move requires exactly two arguments: OLD_PATH NEW_PATH" >&2
        echo ""
        usage
    fi
    preflight_check
    do_move "$1" "$2"
elif [[ "$MODE" == "move_prefix" ]]; then
    if [[ $# -ne 2 ]]; then
        echo "ERROR: --move-prefix requires exactly two arguments: OLD_PREFIX NEW_PREFIX" >&2
        echo ""
        usage
    fi
    preflight_check
    do_move_prefix "$1" "$2"
else
    echo "ERROR: Specify --merge, --move, or --move-prefix." >&2
    echo ""
    usage
fi