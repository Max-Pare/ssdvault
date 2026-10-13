# SSDVault

SSDVault makes an automatic, encrypted, versioned backup of a portable USB stick or SSD to
the local disk of every PC you plug it into. It runs on Windows 10/11 and on Linux (Arch,
Debian, or any distro with systemd).

The engine is [restic](https://restic.net). SSDVault is only the glue around it: it
recognises the drive, runs restic, applies the retention policy and notifies you.

```
plug in the SSD ─► OS event ─► is .ssdvault/id there and registered on this PC?
                                  no  ─► ignore
                                  yes ─► restic backup ─► encrypted repository on THIS PC
                                         + again every 30 min while it stays plugged in
                                         + prune old snapshots daily, verify weekly
```

**Guarantees**

- **No network.** The repository is a local folder. There is no discovery, no relay and no
  open port.
- **One direction only: drive → PC.** Nothing is ever restored, synced or deleted on the
  drive automatically.
- **Nothing on the drive is executed.** The files in `.ssdvault/` are treated as data and
  validated: the id must be exactly 64 hex characters.
- **Interrupted snapshots are discarded.** If you pull the drive out during a backup, the
  partial snapshot is thrown away. The complete ones stay.

| | Trigger on plug-in | Periodic |
|---|---|---|
| Windows | Task Scheduler on event `Microsoft-Windows-Partition/Diagnostic` 1006 | task every 30 min |
| Linux | udev rule → `ssdvault-plug@<dev>.service` | `ssdvault-scan.timer` every 30 min |

The drive's identity is `.ssdvault/id`: 256 random bits generated the first time you
register it. It does not depend on the drive letter, the volume label or the filesystem UUID.

## Installation (once per PC)

### Windows: normal PowerShell, no admin rights

```powershell
winget install -e --id restic.restic
# open a NEW terminal, then:
powershell -ExecutionPolicy Bypass -File .\windows\ssdvault.ps1 install
```

Repositories go to `%USERPROFILE%\.ssdvault\repos`. To put them on another disk, use
`... install -RepoRoot D:\Backup\SSDVault`. After installation the `ssdvault` command is on
your PATH; open a new terminal to use it.

### Linux

```bash
sudo pacman -S restic        # Arch
sudo apt install restic      # Debian
sudo bash ./linux/ssdvault install                              # repos in /var/lib/ssdvault/repos
sudo bash ./linux/ssdvault install --repo-root /data/ssdvault   # or somewhere else
```

## Registering the drive (on every PC)

```powershell
ssdvault register E: -Name projects                 # Windows: the drive's letter
```
```bash
sudo ssdvault register /run/media/$USER/LABEL --name projects   # Arch
sudo ssdvault register /media/$USER/LABEL --name projects       # Debian
```

- **First PC:** creates `.ssdvault/` on the drive (id, name, `excludes.txt`) and the local
  repository.
- **Every PC after that:** reads the existing id and only creates the local repository.
  `-Name` is not needed there.

Registration ends by printing the path of the file holding the **repository password**. Copy
the password into your password manager: without it, the backups on that PC cannot be read.
Then start the first backup with `ssdvault run`. The first one is a full copy; the following
ones are incremental.

## Day-to-day use

Nothing to do. Plug the drive in and you get a *Backup started* notification, then
*Backup done*. Wait for *done* before unplugging. If you try earlier, the OS refuses to
eject anyway because restic is still reading. To stop a backup right away, run
`ssdvault stop`.

## What is NOT backed up

The exclusions live in `.ssdvault/excludes.txt` **on the drive**, so every PC applies the
same ones. Edit the file with any text editor. By default it excludes:

- `node_modules`, `.next`, `.turbo`, `.vite`, `.svelte-kit`, ...
- `.venv`, `__pycache__`
- Blender's numbered versions `*.blend1…*.blend99` and half-written saves `*.blend@`
- OS clutter (`$RECYCLE.BIN`, `System Volume Information`, `.Trash-*`, ...)

To skip a single folder, put an empty file named `.nobackup` inside it. Folders containing a
`CACHEDIR.TAG` file are skipped too.

## Status and restore

```powershell
ssdvault status                        # last backup, result, verification, repo size
                                       # + "latest copy of this drive on EVERY PC"
                                       #   (read from .ssdvault/history.log on the drive)
ssdvault log                           # Linux: sudo ssdvault log  (journald)

ssdvault restic projects snapshots
ssdvault restic projects ls latest
ssdvault restic projects diff 1a2b3c4d 5e6f7a8b
ssdvault restic projects restore latest --target C:\Restore
ssdvault restic projects restore 1a2b3c4d --target C:\Restore --include /E/web/src
sudo ssdvault restic projects mount /mnt/snap     # Linux only: browse snapshots as folders
```

`ssdvault restic <vault> ...` is plain restic, already pointed at the right repository and
password. On Windows, paths inside snapshots look like `/E/folder/...`.

Restore **to a separate folder** and copy back what you need, rather than writing straight
onto the drive.

## Retention

All snapshots from the last 48 h are kept. After that it keeps one snapshot:

- per day for 14 days,
- per week for 8 weeks,
- per month for 24 months,
- per year for 5 years.

You can change this at the top of each script (`$Keep` / `KEEP`). Snapshots share data
through deduplication, so a 1 GB `.blend` that changed a little only stores the changed
chunks.

## Where things live

| | Windows | Linux |
|---|---|---|
| program | `%USERPROFILE%\.ssdvault\bin` | `/usr/local/bin/ssdvault` |
| config | `%USERPROFILE%\.ssdvault\config.json`, `vaults\` | `/etc/ssdvault/` |
| repository passwords | `%USERPROFILE%\.ssdvault\keys\` | `/etc/ssdvault/keys/` (0600 root) |
| state, logs | `...\.ssdvault\state\`, `logs\` | `/var/lib/ssdvault/state`, journald |
| repositories | `...\.ssdvault\repos\` (or `-RepoRoot`) | `/var/lib/ssdvault/repos` (or `--repo-root`) |
| on the drive | hidden `.ssdvault\`: `id`, `name`, `excludes.txt`, `history.log`, `README.txt` | same |

On Windows the files deliberately do **not** live under `AppData`. Terminals hosted by some
packaged (MSIX) desktop apps have their `AppData` writes silently redirected to a private
folder, and the scheduled tasks would never see those files.

## Notes and limits

- **exFAT has no journal.** Always eject the drive before unplugging it. If the filesystem
  gets corrupted, the last backup on your PCs is your safety net.
- **History is distributed.** Each PC's repository holds what that PC saw while the drive
  was plugged into it. With the drive plugged in, `ssdvault status` shows when each PC last
  copied it.
- **If the drive letter (Windows) or mount point (Linux) changes**, the next backup re-reads
  every file. It stores no duplicate data, it is just slower. If this happens often on
  Windows, assign a fixed letter in *Disk Management*.
- **Files being written during a backup** can be captured half-written. The next snapshot
  fixes them. Blender saves through a `*.blend@` temporary file (excluded), so `.blend` files
  are never captured mid-save.
- **Whoever controls a PC can read its backups**, because the repository password is stored
  on that PC. Encrypt your PCs' disks (BitLocker / LUKS).
- **The drive itself is not encrypted.** If you lose it, the data is readable. VeraCrypt can
  be added if you need that.
- **Debian 12** ships restic 0.14, which works. From restic 0.17 on, identical snapshots are
  skipped (`--skip-if-unchanged`).
- **On Linux with nobody logged in** (so nothing auto-mounts the drive): if the filesystem
  belongs to a registered drive, it is mounted read-only under `/run/ssdvault/` for the
  duration of the backup, then unmounted.
- **If no notification shows up on Windows** within a minute of plugging in, check
  `ssdvault log`. The periodic task still copies the drive within 30 minutes.

## Taking it to a new PC

Keep a copy of this folder on the drive (e.g. `E:\_tools\SSDVault`), or clone the
repository, and install from there. After installation the PC runs its own installed copy;
the one on the drive is only used for installing.

## Uninstalling

`ssdvault uninstall` or `sudo ssdvault uninstall` removes the triggers. Repositories and
passwords stay where they are; delete them by hand if you no longer need them.

## License

Copyright (C) 2026 Massimo Parenti

SSDVault is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation, either version 3 of
the License, or (at your option) any later version. It is distributed WITHOUT ANY WARRANTY;
see [LICENSE](LICENSE) for the full text.
