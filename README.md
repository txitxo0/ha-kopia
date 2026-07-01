# ha-kopia

[![Open your Home Assistant instance and show the add add-on repository dialog with a specific repository URL pre-filled.](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https://github.com/txitxo0/ha-kopia)

Add-on repository for Home Assistant OS with a Kopia add-on.

## Structure

- `repository.yaml`: add-on repository metadata.
- `kopia/`: Kopia add-on.

## What this add-on does

- Runs Kopia inside Home Assistant OS.
- Exposes the web UI on direct port `51515`.
- Uses `/share` storage as the repository destination.
- Validates that the configured media path exists.
- If the path does not exist, it logs the media found under `/share`.

## Supported architectures

- `amd64` (x86_64, suitable for Intel N100).
- `aarch64` (64-bit ARM).

No 32-bit architectures are included.

## Add-on options

- `backup_media`: media path, must be under `/share`.
- `repository_subdir`: repository folder inside the selected media.
- `snapshot_paths`: paths to back up.
- `server_username`: username used to access the Kopia web UI.
- `password`: Kopia repository password.

## UI limitation

Home Assistant add-ons do not provide a dynamic selector for paths discovered at runtime. Because of that:

- `backup_media` is a text field.
- if the path is invalid, the script logs the available media under `/share`.

## Setup

1. Publish this repository on GitHub.
2. In Home Assistant, go to Settings -> Add-ons -> Add-on Store -> Repositories.
3. Add the repository URL.
4. Install the `Kopia` add-on.
5. Configure `backup_media` (for example `/share`, `/share/nas`, or `/share/usb`).
6. Set `repository_subdir`, `snapshot_paths`, `server_username`, and `password`.
7. Start the add-on.
8. Open the UI using `http://HAOS_IP:51515`.
9. Check the logs if something fails.

## Kopia notifications in Home Assistant

Kopia does not expose a usable JSON payload in the webhook by default, but notification templates allow custom headers and a custom body. The add-on seeds `snapshot-report.txt` and `test-notification.txt` templates into the repository the first time it starts, using `application/x-www-form-urlencoded` so Home Assistant receives structured data.

Recommended flow:

1. In Kopia, create a notification profile of type `webhook`.
2. Set `Minimum severity` to `error` to send only real failures.
3. Use the Home Assistant webhook as the endpoint, for example `http://YOUR_HA:8123/api/webhook/kopia-ha-backup`.
4. The add-on initially creates the `snapshot-report.txt` template in the repository with content like this:

```txt
Subject: {{ .EventArgs.OverallStatus }}
Content-Type: application/x-www-form-urlencoded

title={{ urlquery "Kopia backup" }}&message={{ urlquery .EventArgs.OverallStatus }}&severity={{ urlquery .EventArgs.OverallStatusCode }}
```

5. You can later adjust that template from the Kopia UI if you want to change the wording.
6. In Home Assistant, create a webhook-triggered automation and read `trigger.data.title`, `trigger.data.message`, and `trigger.data.severity`.

If you use Kopia's "Test notification" button, the seeded `test-notification.txt` template is also form-encoded, so Home Assistant receives the same fields in `trigger.data`.

Example automation:

```yaml
alias: Kopia backup error
description: Show Kopia failures as a persistent notification
triggers:
  - trigger: webhook
    webhook_id: kopia-ha-backup
    allowed_methods:
      - POST
    local_only: true

conditions: []

actions:
  - action: persistent_notification.create
    data:
      notification_id: kopia_backup
      title: "{{ trigger.data.title }}"
      message: "{{ trigger.data.message }}"

mode: queued
max: 10
```

With this, Kopia still generates the notification, but Home Assistant receives it in a format it can display and process without an external middleware.

## Example configuration

```yaml
backup_media: /share/nas
repository_subdir: kopia-repository
snapshot_paths:
  - /backup
server_username: kopia
password: change-this-password
```

## Roadmap

- Add ingress access


## Acknowledgements

Thanks to the Kopia team for building and maintaining this excellent backup project:

- [kopia/kopia: Cross-platform backup tool for Windows, macOS & Linux with fast, incremental backups, client-side end-to-end encryption, compression and data deduplication. CLI and GUI included.](https://github.com/kopia/kopia)