# GSR - Personalized Fabric Server

### INCLUDES

- Separate Packwiz modpacks per environment
  - Vanilla: `environments/vanilla/pack/`
  - Skyblock: `environments/skyblock/pack/`
- MC-Server:
  - Podman Quadlets using [itzg/minecraft-server](https://hub.docker.com/r/itzg/minecraft-server) as base image
  - Fetches the matching modpack automatically
  - Bootstrap script for both fresh installs and infrastructure updates
- `gsr` is the single installed server command interface
- `gsr whitelist` maintains one private whitelist for every environment
- `gsr backup` keeps verified full-volume backups per environment (one by
  default, configurable)
- Worlds, player data and runtime configuration remain separate per environment

## Environments

| Environment | Minecraft | Service | Container | Volume | World |
|---|---:|---|---|---|---|
| Vanilla | 26.3 | `gsr.service` | `gsr` | `gayshitdata` | `world-26.3` |
| Skyblock | 26.2 | `skyblock.service` | `skyblock` | `skyblockdata` | `skyblock` |

Both environments use port `25565`; only one may run at a time.

### Server icons

Each environment provides its versioned `server-icon.png` in its own directory.
During `gsr/bootstrap.sh` the icons are copied to the server-private runtime
directory `~/.config/gsr/icons/` and mounted read-only as `/data/server-icon.png`.
The active environment therefore identifies itself in Minecraft's multiplayer
list. Minecraft serves that icon per active server endpoint, not per hostname:
the same active icon is shown for both a domain and direct IP/port access.

## Server commands

After bootstrap, the grouped command is the normal entry point:

```bash
gsr help
gsr status
gsr start vanilla
gsr switch skyblock
gsr stop
gsr restart
gsr rcon
gsr properties edit
gsr resources status
gsr resources status --sample 180
gsr resources recommend vanilla
gsr whitelist list
gsr identity audit vanilla
gsr backup list
```

`gsr start <environment>` refuses to stop another environment implicitly;
use `gsr switch <environment>` for the explicit, backed-up change. `gsr stop`
and `gsr restart` always act on exactly the active environment. Bootstrap only
installs `gsr` into the user's PATH; the older helper names remain internal.

Long starts, stops, restarts and switches print their real lifecycle phases and
elapsed wait time. A start is only reported ready after Minecraft RCON accepts
a command; stop/restart/switch keep waiting while their clean-save and backup
hooks complete. No artificial percentage is shown.

### Resource status

`gsr resources` is read-only. `status` measures the active environment and
writes the latest private result under `~/.local/state/gsr/resources/`; it is
not part of the repository, a volume, or a backup source. A plain status is a
momentary snapshot. A sampled status records values across a chosen number of
seconds (maximum 600):

```bash
gsr resources status
gsr resources status --sample 30
gsr resources status --sample 180
gsr resources recommend vanilla
```

`recommend` evaluates only the last saved status for that environment and
never changes settings. It returns exactly one result: `server stabil`,
`besserer Test empfohlen`, or `konkrete Änderung prüfen`. The latter lists only
fixed numeric outliers and their fixed possible change (for example JVM heap
pressure → more `MEMORY`; CPU or host pressure → lower
`simulation-distance`). It does not infer game causes, change limits, or make
claims about view distance or chunk generation.

### Persistent server properties

Each environment's image creates `server.properties` from its container values
only for a new, empty `/data` volume. Afterwards the live file in that volume
is authoritative, so a Git update or restart does not reset settings such as
`difficulty`, MOTD or view distance.

Use `gsr rcon` for normal Minecraft console commands. Gamerules persist in the
world; commands such as `difficulty hard` affect the running server but must
also be written as `difficulty=hard` in `server.properties` to survive a
restart. `gsr properties edit` safely stops the selected environment, verifies
a backup, opens its live file in `nano`, validates it, shows the diff, and can
start the environment again. All `[y/N]` prompts accept only lowercase `y`;
Enter means No.

## Shared private whitelist

On its first run, `bootstrap.sh` creates the server-private identity source and
the generated master whitelist under `~/.config/gsr/`:

- `shared/identities.json` is the source of truth: it records the exact player
  name, deterministic offline UUID, optional Mojang UUID, and which identities
  are allowed.
- `shared/whitelist.json` is generated from it and used by every environment.
  Neither file is committed to Git.

The old environment-local `whitelist.json` files are intentionally gone.
`defaults/identities.example.json` documents the format with fictional names
and UUIDs only; bootstrap never copies it into a real server profile.

Bootstrap preserves existing private data:

- If both private files exist, it changes neither of them.
- If `identities.json` exists but `whitelist.json` is missing, it rebuilds the
  master whitelist from the identities.
- If `whitelist.json` exists but `identities.json` is missing, it migrates the
  master once into the identity source.
- If neither file exists, it creates an empty identity source. For an existing
  server without private files, its current local whitelist is migrated once.

For a manual setup, the real files belong here, never in the repository:

```text
~/.config/gsr/shared/identities.json  # source of truth, mode 600
~/.config/gsr/shared/whitelist.json   # generated file, mode 644
```

Only the generated whitelist is mounted read-only into Minecraft containers;
`identities.json` is never exposed to them.

### Whitelist command

After running bootstrap once, use:

```bash
gsr whitelist list
gsr whitelist add premium PlayerName
gsr whitelist add offline PlayerName
gsr whitelist remove PlayerName [premium|offline|all]
gsr whitelist apply
gsr whitelist audit
```

`add premium` looks up the global Java UUID at Mojang and also allows the
matching deterministic offline UUID. This is necessary because the current
environments use `online-mode=false`: a premium owner can initially receive
the offline UUID before EasyAuth classifies the account.

`add offline` enables only the deterministic offline UUID. The command updates
`identities.json`, rebuilds the master whitelist, and applies it immediately to
the single running environment. Without a running environment, it is applied
on the next start.

A player can deliberately have both a premium and an offline UUID in the
master whitelist. `mc-whitelist audit` verifies that the generated file matches
the private identity source. Changes made directly through the Minecraft game,
RCON, or `whitelist.json` are not authoritative and can be replaced by the next
`mc-whitelist apply`; record permanent changes in `identities.json` or use
`mc-whitelist`.

“Private” means server-local and outside the repository. The generated
whitelist contains no passwords or EasyAuth database data.

### Identity consistency audit

The environments currently use `online-mode=false`. Therefore the deterministic
offline UUID for the exact player name is the canonical UUID for live player
data, even for a player with a premium account. The premium UUID remains an
allowed whitelist identity and useful account metadata, but it is not a second
live player-data identity.

Run the read-only audit after a migration, before an identity repair, or during
routine maintenance:

```bash
gsr identity audit vanilla
```

It compares `identities.json`, the EasyAuth UUID column, and the four canonical
player-data files in the selected environment. It reports retained historical
premium files separately and never modifies EasyAuth, a whitelist, player data,
the volume, or the running server. A player who has not joined yet is reported
as such rather than treated as an error. A different EasyAuth UUID is an error
that must be investigated before any manual migration.

## Backups and safety

- **When a backup is made.** A planned stop, restart or switch through `gsr`
  or systemd first runs `save-all flush` over RCON (`ExecStop`), then, once the
  container has stopped, exports the whole `/data` volume (`ExecStopPost`).
  If the flush fails or the environment was not running, no backup is made and
  the previous one stays current. `gsr backup create` does the same for an
  environment that is already stopped. `podman stop` bypasses all of this.
- **What is checked.** A new archive becomes `current` only after its sha256,
  `zstd -t`, a full tar listing and its manifest pass, and after it has been
  flushed to disk. Only then are older snapshots removed. Commands that read a
  backup (`verify`, `restore`, `restore-server`, and the pull client's
  transfers) check it again first and refuse a damaged one.
- **How many are kept.** By default one snapshot per environment is kept on
  the server, so each stop replaces the previous backup. To keep more, create
  `~/.config/gsr/backup.conf` on the server with one line:

  ```text
  GSR_SERVER_BACKUP_KEEP=3
  ```

  The value (1 to 999) counts all snapshots of one environment, `current`
  included; each is a full compressed copy of the volume, so plan disk space
  for that many. The setting is applied at the next successful backup, which
  then removes the oldest snapshots beyond the limit. Without the file, or
  with `GSR_SERVER_BACKUP_KEEP=1`, behaviour is exactly as before. Any other
  content in that file (a typo, `0`, a non-number) makes every backup,
  including the automatic stop backups, refuse to run and leave the existing
  snapshots untouched; check `gsr backup verify <environment>` or the journal
  after changing it. The `gsr backup` commands only use `current`; older
  snapshots are kept under
  `~/.local/share/gsr/backups/<environment>/snapshots/` and are not yet
  selectable by a command.
- **Restores.** `gsr backup restore` only imports into a new, separately named
  volume. `gsr backup restore-server` (and `gsr-backup-pull restore-server`)
  replace the live volume only after a typed `RESTORE-<environment>`
  confirmation and a fresh rollback backup of the live volume. If the import
  fails, the rollback backup is imported again and the environment stays
  stopped. For `gsr backup restore-server` the protected copy of the restore
  source is then kept and its path printed; for `gsr-backup-pull
  restore-server` the source remains on the other computer.
- **Off-server copies.** `scripts/bin/gsr-backup-pull` keeps its own number of
  complete backups on another computer (see below). With the default server
  setting it is the only way to keep older backups.

## Environment backups

`gsr-backup` keeps verified, complete local backups for each environment
under `~/.local/share/gsr/backups/`: exactly one by default, or the number set
by `GSR_SERVER_BACKUP_KEEP` (see above). It is outside the repository,
so bootstrap and Git updates never replace it. It contains the whole Podman
`/data` volume, including the world, player data, EasyAuth database, mods, and
runtime configuration. The private shared whitelist source is copied alongside
it.

Before a planned stop, restart, or environment switch, the service flushes the
Minecraft save. After the container has stopped, its now-idle volume is
exported, compressed with zstd, verified, and made current. Older local
backups beyond the retention setting are only removed after the new archive
has passed its integrity checks.

The normal server start always uses its live volume; a backup is never mounted
automatically. Direct `podman stop` commands bypass this protection. Use `gsr`
or systemd for planned maintenance.

```bash
gsr backup list
gsr backup verify vanilla
gsr backup create skyblock
gsr backup restore vanilla restored-vanilla
gsr backup restore-server vanilla
```

`create` is only for a stopped environment. The automatic hooks handle running
environments. `restore` verifies the archive and imports it only into a newly
created, separately named volume; it refuses to touch the live volume or any
existing volume. Point an environment at that new volume only after inspecting
it.

`restore-server` is the explicit server-local rollback command. It asks for a
confirmation, protects its source temporarily, creates a fresh backup of the
currently live volume, then replaces the live volume and starts the environment
again. The fresh server backup becomes the rollback point. With the default
retention only that one full backup is retained at rest; the duplicate source
exists only while the restore runs (or after a failed restore, where it is
kept and its path is printed).
The saved `shared/` directory remains reference material and is not copied back
automatically.

### Manual copies to another computer

Run `scripts/bin/gsr-backup-pull` from a checked-out copy of this repository on
the computer that should keep its own copies. Its first command creates a
private local configuration and asks which environments and how many complete
backups that computer should retain:

```bash
scripts/bin/gsr-backup-pull setup
scripts/bin/gsr-backup-pull list
scripts/bin/gsr-backup-pull pull vanilla
scripts/bin/gsr-backup-pull verify vanilla current
```

`setup` stores connection data in `~/.config/gsr-backup-pull/config.json` with
mode 600. Each computer can select different environments and a different
retention count; the default is two total snapshots: `current` and `previous`.
There is no timer and no automatic transfer. A pull asks interactively for the
normal SSH password and the server's sudo password, then keeps the terminal
open while it shows transfer progress and an estimate. The local rotation only
happens after checksum, zstd, tar, and manifest validation succeed. A failed
transfer removes its temporary files and leaves earlier complete snapshots
unchanged.

To later change the connection, selected environments, local destination, or
retention without editing JSON, use `scripts/bin/gsr-backup-pull configure`.
It verifies the selected environments with the server but does not move or
delete existing local backups; a reduced retention is applied only after the
next successful pull.

A complete local backup can export just its world directory to any chosen
directory without assuming a launcher or Minecraft instance layout:

```bash
scripts/bin/gsr-backup-pull export-world vanilla current /path/to/export
```

For example, this produces `/path/to/export/world-26.3/`; the user can then
copy that world folder into the saves location of any suitable launcher. New
backups record the world directory in their manifest. Older backups fall back
to `server.properties` inside the archive.

To restore a verified local snapshot back to the selected server environment:

```bash
scripts/bin/gsr-backup-pull restore-server vanilla previous
```

This command requires an explicit `RESTORE-<environment>` confirmation. It
streams the local snapshot directly to a private server staging directory,
validates it there, and then performs the same protected live-volume restore
as `gsr backup restore-server`. Interrupted uploads are removed from the
staging directory; they never become a restore source.

Before using a live restore, test the PC-to-server transfer and Podman import
without stopping Minecraft or touching the live volume:

```bash
scripts/bin/gsr-backup-pull upload-test vanilla current
```

It requires `UPLOAD-TEST-<environment>` confirmation, transfers the verified
snapshot into a newly named `gsr-upload-test-...` volume, and checks that the
import contains both `server.properties` and the selected world's `level.dat`.
The test volume is never attached to a container. Remove it after inspection:

```bash
gsr backup remove-test-volume vanilla gsr-upload-test-vanilla-<id>
```

## Quick install
``` bash
curl -fsSL https://raw.githubusercontent.com/itsflipper/FlippersPackwizMods/refs/heads/main/gsr/bootstrap.sh -o /tmp/bootstrap.sh && bash /tmp/bootstrap.sh
```
The bootstrap acts in two modes:
- **[f] fresh install** — clone the repo, symlink the quadlet into the systemd path, build the image, reload and start the service
- **[u] update** — `git pull`, rebuild the image, reload and restart the service

## Pre-Requisite
If multiple users on the host need access to the server, run it under a dedicated service user. ([advice that prompted this](https://github.com/podman-container-tools/podman/discussions/28320#discussioncomment-16233449))

```
# Create a system user with no login shell
sudo useradd -r -m -s /usr/sbin/nologin gsr-podman

# Allocate subuid/subgid ranges — REQUIRED for rootless podman.
# `useradd -r` does NOT do this automatically; without it, image builds
# fail with "no subuid ranges found". Pick a 65536-wide block that doesn't
# overlap existing entries in /etc/subuid and /etc/subgid.
sudo usermod --add-subuids 231072-296607 --add-subgids 231072-296607 gsr-podman

# Enable lingering so systemd user services survive logout
sudo loginctl enable-linger gsr-podman

# Interactive shell for gsr user
sudo machinectl shell gsr-podman@ /usr/bin/bash

# Run a one-off command as the service user
sudo machinectl shell gsr-podman@ /usr/bin/podman ps
```

### _Then continue installation (quick or manual) as `gsr-podman`._

## Dependencies
- Podman
- zstd
- skill

## Manual install
### Create symlink for the gsr directory
```
ln -s /path/to/gsr ~/.config/containers/systemd/gsr/
```

### Build the image
```
podman build -t gsr /path/to/gsr/
```

### Reload SystemD
```
systemctl --user daemon-reload
```

### Start / Stop / Restart
```
gsr start vanilla
gsr stop
gsr restart
```

### Logs
```
journalctl --user -u gsr -f
```

### Exec
```
podman exec -it CONTAINERNAME COMMAND
-->

# Poke around inside container
podman exec -it gsr bash

# We enabled rcon, so this is how you can access the MC-Console
podman exec -it gsr rcon-cli
```
