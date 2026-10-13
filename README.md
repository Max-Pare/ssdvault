# SSDVault

Backup automatico, cifrato e versionato di una chiavetta/SSD portatile sul disco locale di
ogni PC a cui la colleghi. Windows 10/11 e Linux (Arch, Debian, qualsiasi distro con systemd).
Il motore è [restic](https://restic.net); SSDVault è solo il collante: riconosce la chiavetta,
lancia restic, applica la retention e ti avvisa.

```
colleghi l'SSD ─► evento del SO ─► c'è .ssdvault/id ed è registrato su questo PC?
                                      no ─► ignora
                                      sì ─► restic backup ─► repository cifrato su QUESTO PC
                                            + di nuovo ogni 30 min finché resta collegato
                                            + pulizia vecchi snapshot 1×/giorno, verifica 1×/settimana
```

**Garanzie**

- **Niente rete.** Il repository è una cartella locale. Nessuna discovery, nessun relay,
  nessuna porta aperta.
- **Un solo verso: chiavetta → PC.** Niente ripristini, sync o cancellazioni automatiche
  sulla chiavetta.
- **Dal disco non si esegue nulla.** I file in `.ssdvault/` sono dati e vengono validati
  (l'id deve essere esattamente 64 caratteri esadecimali).
- **Gli snapshot interrotti vengono scartati.** Se stacchi la chiavetta a metà backup, lo
  snapshot parziale viene buttato via. Restano quelli completi.

| | Trigger all'inserimento | Periodico |
|---|---|---|
| Windows | Task Scheduler sull'evento `Microsoft-Windows-Partition/Diagnostic` 1006 | task ogni 30 min |
| Linux | regola udev → `ssdvault-plug@<dev>.service` | `ssdvault-scan.timer` ogni 30 min |

L'identità della chiavetta è `.ssdvault/id`: 256 bit casuali generati alla prima
registrazione. Non dipende da lettera di unità, etichetta o UUID del filesystem.

## Installazione (una volta per PC)

### Windows — PowerShell normale, senza diritti admin

```powershell
winget install -e --id restic.restic
# apri un NUOVO terminale, poi:
powershell -ExecutionPolicy Bypass -File .\windows\ssdvault.ps1 install
```

I repository vanno in `%USERPROFILE%\.ssdvault\repos`. Per metterli su un altro disco:
`... install -RepoRoot D:\Backup\SSDVault`. Dopo l'installazione il comando `ssdvault` è nel
PATH (apri un nuovo terminale).

### Linux

```bash
sudo pacman -S restic        # Arch
sudo apt install restic      # Debian
sudo bash ./linux/ssdvault install                          # repo in /var/lib/ssdvault/repos
sudo bash ./linux/ssdvault install --repo-root /data/ssdvault   # oppure altrove
```

## Registrare la chiavetta (su ogni PC)

```powershell
ssdvault register E: -Name progetti                 # Windows: lettera della chiavetta
```
```bash
sudo ssdvault register /run/media/$USER/ETICHETTA --name progetti   # Arch
sudo ssdvault register /media/$USER/ETICHETTA --name progetti       # Debian
```

- **Primo PC:** crea `.ssdvault/` sulla chiavetta (id, nome, `excludes.txt`) e il repository
  locale.
- **PC successivi:** legge l'id che c'è già e crea solo il repository locale. `-Name` non serve.

Al termine stampa il percorso del file con la **password del repository**. Copiala nel
password manager: senza, i backup di quel PC non si leggono. Poi lancia il primo backup con
`ssdvault run`. Il primo è completo, i successivi sono incrementali.

## Uso quotidiano

Niente. Colleghi la chiavetta, arriva la notifica *Backup started* e poi *Backup done*.
Aspetta *done* prima di staccare. Se ci provi prima, il sistema rifiuta comunque l'espulsione
perché restic sta leggendo. Per interrompere subito: `ssdvault stop`.

## Cosa NON viene copiato

Le esclusioni sono nel file `.ssdvault/excludes.txt` **sulla chiavetta**, quindi valgono
uguali su tutti i PC. Si modifica con un editor qualsiasi. Di base esclude:

- `node_modules`, `.next`, `.turbo`, `.vite`, `.svelte-kit`, ...
- `.venv`, `__pycache__`
- le versioni numerate di Blender `*.blend1…*.blend99` e i salvataggi a metà `*.blend@`
- la spazzatura di sistema (`$RECYCLE.BIN`, `System Volume Information`, `.Trash-*`, ...)

Per saltare una singola cartella basta metterci dentro un file vuoto `.nobackup`. Anche le
cartelle con un `CACHEDIR.TAG` vengono saltate.

## Stato e ripristino

```powershell
ssdvault status                        # ultimo backup, esito, verifica, dimensione repo
                                       # + "ultima copia di questa chiavetta su OGNI PC"
                                       #   (letto da .ssdvault/history.log sulla chiavetta)
ssdvault log                           # Linux: sudo ssdvault log  (journald)

ssdvault restic progetti snapshots
ssdvault restic progetti ls latest
ssdvault restic progetti diff 1a2b3c4d 5e6f7a8b
ssdvault restic progetti restore latest --target C:\Ripristino
ssdvault restic progetti restore 1a2b3c4d --target C:\Ripristino --include /E/web/src
sudo ssdvault restic progetti mount /mnt/snap     # solo Linux: sfoglia gli snapshot come cartelle
```

`ssdvault restic <vault> ...` è restic puro, già puntato al repository e alla password giusti.
Su Windows i percorsi dentro gli snapshot hanno la forma `/E/cartella/...`.

Conviene ripristinare **in una cartella separata** e poi copiare quello che serve, non
sovrascrivere direttamente la chiavetta.

## Retention

Tutti gli snapshot delle ultime 48 h. Poi ne tiene uno:

- al giorno per 14 giorni,
- a settimana per 8 settimane,
- al mese per 24 mesi,
- all'anno per 5 anni.

Si cambia in testa agli script (`$Keep` / `KEEP`). Gli snapshot condividono i dati
(deduplicazione), quindi un `.blend` da 1 GB modificato di poco occupa solo i blocchi cambiati.

## Dove stanno i file

| | Windows | Linux |
|---|---|---|
| programma | `%USERPROFILE%\.ssdvault\bin` | `/usr/local/bin/ssdvault` |
| config | `%USERPROFILE%\.ssdvault\config.json`, `vaults\` | `/etc/ssdvault/` |
| password repository | `%USERPROFILE%\.ssdvault\keys\` | `/etc/ssdvault/keys/` (0600 root) |
| stato, log | `...\.ssdvault\state\`, `logs\` | `/var/lib/ssdvault/state`, journald |
| repository | `...\.ssdvault\repos\` (o `-RepoRoot`) | `/var/lib/ssdvault/repos` (o `--repo-root`) |
| sulla chiavetta | `.ssdvault\` nascosta: `id`, `name`, `excludes.txt`, `history.log`, `README.txt` | idem |

Su Windows i file **non** stanno in `AppData` di proposito. I terminali ospitati da alcune
app desktop "pacchettizzate" (MSIX) vedono le scritture in `AppData` dirottate in una
cartella privata, che i task pianificati non vedono.

## Note e limiti

- **exFAT non ha journal.** Espelli sempre la chiavetta prima di staccarla. Se il filesystem
  si corrompe, la rete di sicurezza è l'ultimo backup sui PC.
- **La storia è distribuita.** Ogni PC ha il suo repository con quello che ha visto mentre la
  chiavetta era collegata lì. `ssdvault status`, a chiavetta collegata, mostra quando ogni PC
  l'ha copiata l'ultima volta.
- **Se cambia la lettera di unità (Windows) o il punto di mount (Linux)**, il backup
  successivo rilegge tutti i file: non duplica dati, è solo più lento. Se su Windows succede
  spesso, assegna una lettera fissa da *Gestione disco*.
- **File in scrittura durante il backup** possono finire nello snapshot a metà. Lo snapshot
  successivo li corregge. Blender salva passando da `*.blend@` (escluso), quindi i `.blend`
  non vengono mai catturati a metà.
- **Chi controlla un PC può leggere i suoi backup**, perché la password del repository è su
  quel PC. Cifra i dischi dei PC (BitLocker / LUKS).
- **La chiavetta non è cifrata**: se la perdi, i dati sono leggibili. Se serve, si aggiunge
  VeraCrypt.
- **Debian 12** ha restic 0.14, che funziona. Da restic 0.17 in su gli snapshot identici
  vengono saltati (`--skip-if-unchanged`).
- **Linux senza nessuno loggato** (niente automount): se il filesystem appartiene a una
  chiavetta registrata, viene montato in sola lettura in `/run/ssdvault/` per la durata del
  backup e poi smontato.
- **Se su Windows non arriva la notifica** entro un minuto dall'inserimento, guarda
  `ssdvault log`. Il task periodico la copia comunque entro 30 minuti.

## Portarlo su un PC nuovo

Tieni una copia di questa cartella sulla chiavetta (es. `E:\_tools\SSDVault`) e installa da
lì. Dopo l'installazione gira la copia installata sul PC: quella sulla chiavetta serve solo
per installare.

## Disinstallazione

`ssdvault uninstall` oppure `sudo ssdvault uninstall` rimuove i trigger. Repository e
password restano dove sono: cancellali a mano se non ti servono più.
