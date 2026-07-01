#!/usr/bin/with-contenv bashio
set -euo pipefail

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

  if kopia notification template list 2>/dev/null | grep -F "${template_name}" | grep -Fq "<customized>"; then
    bashio::log.info "Custom Kopia notification template already present: ${template_name}"
    return
  fi

  bashio::log.info "Seeding Kopia notification template: ${template_name}"

  kopia notification template set "${template_name}" --from-stdin <<'EOF'
Subject: {{ .EventArgs.OverallStatus }}
Content-Type: application/x-www-form-urlencoded

title={{ urlquery "Kopia backup" }}&message={{ urlquery .EventArgs.OverallStatus }}&severity={{ urlquery .EventArgs.OverallStatusCode }}
EOF
}

seed_test_notification_template() {
  local template_name="test-notification.txt"

  if kopia notification template list 2>/dev/null | grep -F "${template_name}" | grep -Fq "<customized>"; then
    bashio::log.info "Custom Kopia notification template already present: ${template_name}"
    return
  fi

  bashio::log.info "Seeding Kopia notification template: ${template_name}"

  kopia notification template set "${template_name}" --from-stdin <<'EOF'
Subject: Test notification from Kopia at {{ .EventTime | formatTime }}
Content-Type: application/x-www-form-urlencoded

title={{ urlquery "Kopia test notification" }}&message={{ urlquery (printf "Kopia test notification from %s at %s" .Hostname (.EventTime | formatTime)) }}&severity={{ urlquery "success" }}
EOF
}

BACKUP_MEDIA="$(bashio::config 'backup_media')"
REPOSITORY_SUBDIR="$(bashio::config 'repository_subdir')"
PASSWORD="$(bashio::config 'password')"
SERVER_USERNAME="$(bashio::config 'server_username')"

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

if [ -z "$SERVER_USERNAME" ]; then
  bashio::log.error "The server_username option is required for the Kopia server login."
  exit 1
fi

REPOSITORY_PATH="${BACKUP_MEDIA%/}/${REPOSITORY_SUBDIR}"
ensure_repository_path "$REPOSITORY_PATH"

export KOPIA_PASSWORD="$PASSWORD"

if [ -z "$(ls -A "$REPOSITORY_PATH" 2>/dev/null)" ]; then
  bashio::log.info "Creating Kopia repository at: ${REPOSITORY_PATH}"
  kopia repository create filesystem --path "$REPOSITORY_PATH"
else
  bashio::log.info "Connecting Kopia repository at: ${REPOSITORY_PATH}"
  kopia repository connect filesystem --path "$REPOSITORY_PATH"
fi

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
  kopia snapshot create "${SNAPSHOT_PATHS[@]}" || bashio::log.warning "Failed to create initial snapshot"
else
  bashio::log.warning "No valid snapshot_paths for initial snapshot"
fi

bashio::log.info "Starting Kopia Server at 0.0.0.0:51515"
exec kopia server start \
  --address=0.0.0.0:51515 \
  --server-username="${SERVER_USERNAME}" \
  --server-password="${PASSWORD}" \
  --disable-csrf-token-checks \
  --insecure
