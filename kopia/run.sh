#!/usr/bin/with-contenv bashio
set -euo pipefail

KOPIA_CONFIG_FILE="/data/kopia.config"
SYNC_LOCK_DIR="/tmp/ha-kopia-sync.lock"
CRON_DIR="/etc/crontabs"
CRON_FILE="${CRON_DIR}/root"

kopia_cmd() {
  kopia --config-file="${KOPIA_CONFIG_FILE}" "$@"
}

list_available_media() {
  local base="/share"

  if [ ! -d "$base" ]; then
    echo "(/share does not exist)"
    return
  fi

  echo "/share"

  shopt -s nullglob
  local item
  for item in "$base"/*; do
    if [ -d "$item" ]; then
      echo "$item"
    fi
  done
  shopt -u nullglob
}

fail_with_media_list() {
  local message="$1"
  bashio::log.error "$message"
  bashio::log.error "Detected media under /share:"

  while IFS= read -r path; do
    bashio::log.error " - ${path}"
  done < <(list_available_media)

  exit 1
}

ensure_repository_path() {
  local path="$1"
  local output

  if ! output=$(mkdir -p "$path" 2>&1); then
    if echo "$output" | grep -qi "stale file handle"; then
      fail_with_media_list "Cannot access '${path}' due to a stale NFS handle. Refresh the /share mount (or reboot HAOS) and try again."
    fi

    fail_with_media_list "Cannot create repository path '${path}': ${output}"
  fi
}

seed_snapshot_report_template() {
  local template_name="snapshot-report.txt"

  if kopia_cmd notification template list 2>/dev/null | grep -F "${template_name}" | grep -Fq "<customized>"; then
    bashio::log.info "Custom Kopia notification template already present: ${template_name}"
    return
  fi

  bashio::log.info "Seeding Kopia notification template: ${template_name}"

  kopia_cmd notification template set "${template_name}" --from-stdin <<'EOF'
Subject: {{ .EventArgs.OverallStatus }}
Content-Type: application/x-www-form-urlencoded

title={{ urlquery "Kopia backup" }}&message={{ urlquery .EventArgs.OverallStatus }}&severity={{ urlquery .EventArgs.OverallStatusCode }}
EOF
}

seed_test_notification_template() {
  local template_name="test-notification.txt"

  if kopia_cmd notification template list 2>/dev/null | grep -F "${template_name}" | grep -Fq "<customized>"; then
    bashio::log.info "Custom Kopia notification template already present: ${template_name}"
    return
  fi

  bashio::log.info "Seeding Kopia notification template: ${template_name}"

  kopia_cmd notification template set "${template_name}" --from-stdin <<'EOF'
Subject: Test notification from Kopia at {{ .EventTime | formatTime }}
Content-Type: application/x-www-form-urlencoded

title={{ urlquery "Kopia test notification" }}&message={{ urlquery (printf "Kopia test notification from %s at %s" .Hostname (.EventTime | formatTime)) }}&severity={{ urlquery "success" }}
EOF
}

load_config() {
  BACKUP_MEDIA="$(bashio::config 'backup_media')"
  REPOSITORY_SUBDIR="$(bashio::config 'repository_subdir')"
  PASSWORD="$(bashio::config 'password')"
  SERVER_USERNAME="$(bashio::config 'server_username')"
  SYNC_ENABLED="$(bashio::config 'sync_enabled')"
  SYNC_SCHEDULE="$(bashio::config 'sync_schedule')"
  REPOSITORY_PATH="${BACKUP_MEDIA%/}/${REPOSITORY_SUBDIR}"
}

validate_cron_schedule() {
  local schedule="$1"

  set -- $schedule
  if [ "$#" -ne 5 ]; then
    bashio::log.error "The sync_schedule option must contain 5 cron fields. Example: 0 3 * * *"
    exit 1
  fi
}

validate_primary_config() {
  local require_server_credentials="$1"

  if [ -z "$BACKUP_MEDIA" ]; then
    fail_with_media_list "The backup_media option is empty."
  fi

  if [[ "$BACKUP_MEDIA" != /share* ]]; then
    fail_with_media_list "Path '${BACKUP_MEDIA}' is not under /share."
  fi

  if [ ! -d "$BACKUP_MEDIA" ]; then
    fail_with_media_list "Media path '${BACKUP_MEDIA}' does not exist."
  fi

  if [ -z "$REPOSITORY_SUBDIR" ]; then
    bashio::log.error "The repository_subdir option is empty."
    exit 1
  fi

  if [ -z "$PASSWORD" ]; then
    bashio::log.error "The password option is required to initialize/connect Kopia."
    exit 1
  fi

  if [ "$require_server_credentials" = "true" ] && [ -z "$SERVER_USERNAME" ]; then
    bashio::log.error "The server_username option is required for the Kopia server login."
    exit 1
  fi

  if [ "${SYNC_ENABLED:-false}" = "true" ]; then
    validate_cron_schedule "$SYNC_SCHEDULE"
  fi
}

ensure_sync_path() {
  local path="$1"
  local output

  if ! output=$(mkdir -p "$path" 2>&1); then
    if [[ "$path" == /share* ]] && echo "$output" | grep -qi "stale file handle"; then
      fail_with_media_list "Cannot access '${path}' due to a stale NFS handle. Refresh the /share mount (or reboot HAOS) and try again."
    fi

    bashio::log.warning "Cannot create sync path '${path}': ${output}"
    return 1
  fi

  return 0
}

has_enabled_sync_destinations() {
  jq -e 'any(.sync_to_repositories[]?; (.enabled // true) == true)' /data/options.json >/dev/null 2>&1
}

ensure_primary_repository_connection() {
  ensure_repository_path "$REPOSITORY_PATH"
  export KOPIA_PASSWORD="$PASSWORD"

  if kopia_cmd repository status >/dev/null 2>&1; then
    return 0
  fi

  if [ -z "$(ls -A "$REPOSITORY_PATH" 2>/dev/null)" ]; then
    bashio::log.info "Creating Kopia repository at: ${REPOSITORY_PATH}"
    kopia_cmd repository create filesystem --path "$REPOSITORY_PATH"
  else
    bashio::log.info "Connecting Kopia repository at: ${REPOSITORY_PATH}"
    kopia_cmd repository connect filesystem --path "$REPOSITORY_PATH"
  fi
}

validate_sync_repository_common() {
  local repository_json="$1"
  local target_label="$2"
  local parallel

  parallel="$(jq -r '.parallel // 1' <<<"$repository_json")"
  if ! [[ "$parallel" =~ ^[1-9][0-9]*$ ]]; then
    bashio::log.warning "Skipping sync destination '${target_label}': parallel must be a positive integer"
    return 1
  fi

  return 0
}

sync_repository() {
  local repository_json="$1"
  local credentials_file=""
  local name type enabled target_label delete must_exist parallel update
  local -a cmd

  name="$(jq -r '.name // empty' <<<"$repository_json")"
  type="$(jq -r '.type // empty' <<<"$repository_json")"
  enabled="$(jq -r '.enabled // true' <<<"$repository_json")"
  target_label="${name:-${type:-unnamed}}"
  delete="$(jq -r '.delete // false' <<<"$repository_json")"
  must_exist="$(jq -r '.must_exist // false' <<<"$repository_json")"
  parallel="$(jq -r '.parallel // 1' <<<"$repository_json")"
  update="$(jq -r '.update // true' <<<"$repository_json")"

  if [ "$enabled" != "true" ]; then
    bashio::log.info "Skipping disabled sync destination: ${target_label}"
    return 0
  fi

  if [ -z "$type" ]; then
    bashio::log.warning "Skipping sync destination '${target_label}': missing type"
    return 0
  fi

  validate_sync_repository_common "$repository_json" "$target_label" || return 0

  cmd=(repository sync-to "$type")

  case "$type" in
    filesystem)
      local path
      path="$(jq -r '.path // empty' <<<"$repository_json")"

      if [ -z "$path" ]; then
        bashio::log.warning "Skipping filesystem sync destination '${target_label}': missing path"
        return 0
      fi

      if [[ "$path" != /* ]]; then
        bashio::log.warning "Skipping filesystem sync destination '${target_label}': path must be absolute"
        return 0
      fi

      ensure_sync_path "$path" || return 0
      cmd+=(--path "$path")
      ;;
    webdav)
      local url username webdav_password
      url="$(jq -r '.url // empty' <<<"$repository_json")"
      username="$(jq -r '.username // empty' <<<"$repository_json")"
      webdav_password="$(jq -r '.password // empty' <<<"$repository_json")"

      if [ -z "$url" ]; then
        bashio::log.warning "Skipping WebDAV sync destination '${target_label}': missing url"
        return 0
      fi

      if [[ ! "$url" =~ ^https?:// ]]; then
        bashio::log.warning "Skipping WebDAV sync destination '${target_label}': url must start with http:// or https://"
        return 0
      fi

      cmd+=(--url "$url")
      [ -n "$username" ] && cmd+=(--webdav-username "$username")
      [ -n "$webdav_password" ] && cmd+=(--webdav-password "$webdav_password")
      ;;
    s3)
      local bucket endpoint prefix region access_key secret_key
      bucket="$(jq -r '.bucket // empty' <<<"$repository_json")"
      endpoint="$(jq -r '.endpoint // empty' <<<"$repository_json")"
      prefix="$(jq -r '.prefix // empty' <<<"$repository_json")"
      region="$(jq -r '.region // empty' <<<"$repository_json")"
      access_key="$(jq -r '.access_key // empty' <<<"$repository_json")"
      secret_key="$(jq -r '.secret_key // empty' <<<"$repository_json")"

      if [ -z "$bucket" ]; then
        bashio::log.warning "Skipping S3 sync destination '${target_label}': missing bucket"
        return 0
      fi

      if { [ -n "$access_key" ] && [ -z "$secret_key" ]; } || { [ -z "$access_key" ] && [ -n "$secret_key" ]; }; then
        bashio::log.warning "Skipping S3 sync destination '${target_label}': access_key and secret_key must be set together"
        return 0
      fi

      cmd+=(--bucket "$bucket")
      [ -n "$endpoint" ] && cmd+=(--endpoint "$endpoint")
      [ -n "$prefix" ] && cmd+=(--prefix "$prefix")
      [ -n "$region" ] && cmd+=(--region "$region")
      [ -n "$access_key" ] && cmd+=(--access-key "$access_key")
      [ -n "$secret_key" ] && cmd+=(--secret-access-key "$secret_key")
      ;;
    sftp)
      local host path username sftp_password port
      host="$(jq -r '.host // empty' <<<"$repository_json")"
      path="$(jq -r '.path // empty' <<<"$repository_json")"
      username="$(jq -r '.username // empty' <<<"$repository_json")"
      sftp_password="$(jq -r '.password // empty' <<<"$repository_json")"
      port="$(jq -r '.port // empty' <<<"$repository_json")"

      if [ -z "$host" ] || [ -z "$path" ] || [ -z "$username" ]; then
        bashio::log.warning "Skipping SFTP sync destination '${target_label}': host, path and username are required"
        return 0
      fi

      if [[ "$path" != /* ]]; then
        bashio::log.warning "Skipping SFTP sync destination '${target_label}': path must be absolute"
        return 0
      fi

      cmd+=(--host "$host" --path "$path" --username "$username")
      [ -n "$port" ] && cmd+=(--port "$port")
      [ -n "$sftp_password" ] && cmd+=(--sftp-password "$sftp_password")
      ;;
    azure)
      local container prefix account_name account_key storage_domain sas_token
      container="$(jq -r '.container // empty' <<<"$repository_json")"
      prefix="$(jq -r '.prefix // empty' <<<"$repository_json")"
      account_name="$(jq -r '.account_name // empty' <<<"$repository_json")"
      account_key="$(jq -r '.account_key // empty' <<<"$repository_json")"
      storage_domain="$(jq -r '.storage_domain // empty' <<<"$repository_json")"
      sas_token="$(jq -r '.sas_token // empty' <<<"$repository_json")"

      if [ -z "$container" ] || [ -z "$account_name" ]; then
        bashio::log.warning "Skipping Azure sync destination '${target_label}': container and account_name are required"
        return 0
      fi

      if [ -z "$account_key" ] && [ -z "$sas_token" ]; then
        bashio::log.warning "Skipping Azure sync destination '${target_label}': account_key or sas_token is required"
        return 0
      fi

      cmd+=(--container "$container" --storage-account "$account_name")
      [ -n "$prefix" ] && cmd+=(--prefix "$prefix")
      [ -n "$account_key" ] && cmd+=(--storage-key "$account_key")
      [ -n "$storage_domain" ] && cmd+=(--storage-domain "$storage_domain")
      [ -n "$sas_token" ] && cmd+=(--sas-token "$sas_token")
      ;;
    gcs)
      local bucket prefix credentials_json
      bucket="$(jq -r '.bucket // empty' <<<"$repository_json")"
      prefix="$(jq -r '.prefix // empty' <<<"$repository_json")"
      credentials_json="$(jq -r '.credentials_json // empty' <<<"$repository_json")"

      if [ -z "$bucket" ]; then
        bashio::log.warning "Skipping GCS sync destination '${target_label}': missing bucket"
        return 0
      fi

      if [ -z "$credentials_json" ]; then
        bashio::log.warning "Skipping GCS sync destination '${target_label}': credentials_json is required in this add-on environment"
        return 0
      fi

      cmd+=(--bucket "$bucket")
      [ -n "$prefix" ] && cmd+=(--prefix "$prefix")

      credentials_file="$(mktemp)"
      chmod 600 "$credentials_file"
      printf '%s' "$credentials_json" > "$credentials_file"
      cmd+=(--credentials-file "$credentials_file")
      ;;
    b2)
      local bucket prefix key_id key
      bucket="$(jq -r '.bucket // empty' <<<"$repository_json")"
      prefix="$(jq -r '.prefix // empty' <<<"$repository_json")"
      key_id="$(jq -r '.key_id // empty' <<<"$repository_json")"
      key="$(jq -r '.key // empty' <<<"$repository_json")"

      if [ -z "$bucket" ] || [ -z "$key_id" ] || [ -z "$key" ]; then
        bashio::log.warning "Skipping B2 sync destination '${target_label}': bucket, key_id and key are required"
        return 0
      fi

      cmd+=(--bucket "$bucket" --key-id "$key_id" --key "$key")
      [ -n "$prefix" ] && cmd+=(--prefix "$prefix")
      ;;
    *)
      bashio::log.warning "Skipping sync destination '${target_label}': unsupported type '${type}'"
      return 0
      ;;
  esac

  if [ "$delete" = "true" ]; then
    cmd+=(--delete)
  fi

  if [ "$must_exist" = "true" ]; then
    cmd+=(--must-exist)
  fi

  if [ "$update" = "false" ]; then
    cmd+=(--no-update)
  fi

  cmd+=(--parallel "$parallel")

  bashio::log.info "Synchronizing primary repository to '${target_label}' (${type})"

  if kopia_cmd "${cmd[@]}"; then
    bashio::log.info "Finished sync to '${target_label}'"
  else
    bashio::log.warning "Sync failed for '${target_label}'"
  fi

  if [ -n "$credentials_file" ] && [ -f "$credentials_file" ]; then
    rm -f "$credentials_file"
  fi
}

perform_repository_syncs() {
  local repository_count

  repository_count="$(jq '(.sync_to_repositories // []) | length' /data/options.json)"

  if [ "$repository_count" -eq 0 ]; then
    return 0
  fi

  bashio::log.info "Processing ${repository_count} configured sync destination(s)"

  while IFS= read -r repository_json; do
    sync_repository "$repository_json"
  done < <(jq -c '.sync_to_repositories // [] | .[]' /data/options.json)
}

acquire_sync_lock() {
  if mkdir "$SYNC_LOCK_DIR" 2>/dev/null; then
    return 0
  fi

  bashio::log.warning "Skipping sync cycle because another sync is already running"
  return 1
}

release_sync_lock() {
  rmdir "$SYNC_LOCK_DIR" 2>/dev/null || true
}

run_sync_cycle() {
  local origin="$1"

  if ! has_enabled_sync_destinations; then
    bashio::log.info "No enabled sync destinations configured for ${origin} sync cycle"
    return 0
  fi

  if ! acquire_sync_lock; then
    return 0
  fi

  bashio::log.info "Starting ${origin} repository sync cycle"
  perform_repository_syncs
  release_sync_lock
}

configure_sync_schedule() {
  if [ "${SYNC_ENABLED:-false}" != "true" ]; then
    bashio::log.info "Scheduled repository sync is disabled"
    return 0
  fi

  if ! has_enabled_sync_destinations; then
    bashio::log.warning "Scheduled repository sync is enabled, but no sync destinations are enabled"
    return 0
  fi

  mkdir -p "$CRON_DIR"
  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${SYNC_SCHEDULE} /run.sh scheduled-sync >> /proc/1/fd/1 2>&1
EOF
  chmod 600 "$CRON_FILE"

  bashio::log.info "Starting cron scheduler for repository sync: ${SYNC_SCHEDULE}"
  crond -b -l 2 -L /dev/stdout -c "$CRON_DIR"
}

run_scheduled_sync() {
  load_config
  validate_primary_config false
  ensure_primary_repository_connection
  run_sync_cycle "scheduled"
}

start_server() {
  bashio::log.info "Starting Kopia Server at 0.0.0.0:51515"
  exec kopia --config-file="${KOPIA_CONFIG_FILE}" server start \
    --address=0.0.0.0:51515 \
    --server-username="${SERVER_USERNAME}" \
    --server-password="${PASSWORD}" \
    --disable-csrf-token-checks \
    --insecure
}

main() {
  if [ "${1:-}" = "scheduled-sync" ]; then
    run_scheduled_sync
    return 0
  fi

  load_config
  validate_primary_config true
  ensure_primary_repository_connection

  seed_snapshot_report_template
  seed_test_notification_template

  SNAPSHOT_PATHS=()
  while IFS= read -r path; do
    if [ -n "$path" ] && [ -e "$path" ]; then
      SNAPSHOT_PATHS+=("$path")
    else
      bashio::log.warning "Ignoring non-existing snapshot path: ${path}"
    fi
  done < <(bashio::config 'snapshot_paths[]')

  if [ ${#SNAPSHOT_PATHS[@]} -gt 0 ]; then
    bashio::log.info "Creating initial snapshot"
    kopia_cmd snapshot create "${SNAPSHOT_PATHS[@]}" || bashio::log.warning "Failed to create initial snapshot"
  else
    bashio::log.warning "No valid snapshot_paths for initial snapshot"
  fi

  run_sync_cycle "startup"
  configure_sync_schedule
  start_server
}

main "$@"
