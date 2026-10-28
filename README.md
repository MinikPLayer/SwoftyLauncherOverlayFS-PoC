# Swofty Launcher OverlayFS PoC

A Proof of Concept of using **OverlayFS** to mount Swofty Launcher game files on Linux, instead of copying them into the game folder.

## Context

Today the launcher's "copy mode" copies every modded file into the game folder (backing up the stock files first) and rolls everything back on exit. For F1 25 that is about 5 s and 10.4 GiB written per install, plus about 3.4 s and 4.5 GiB per rollback.

This PoC avoids the copying:

1. It creates a private **mount namespace** (`unshare -Urm`), so nothing outside the game's process tree sees the mount.
2. Inside it, it mounts an OverlayFS with two read-only lower layers:
   - the **overlay directory**, which holds the files Swofty would normally install (loader `version.dll`, offline-play stub and hook, asset replacements, ...);
   - the **original game directory**.
3. The overlay is mounted on `/tmp/game`. The script `cd`s into it and runs the Steam launch command.
4. When the last process in the namespace exits, the mount disappears by itself. The real game folder and the overlay directory are never modified.

The full design for a real implementation in the launcher (upper dir for game writes, fallback to copy mode, edge cases, tests) is in [`ERD.md`](ERD.md).

## Files

| File | Purpose |
|---|---|
| `f1_25.sh` | Entry point. Runs `unshare -Urm f1_25_unshared.sh "$@"`. |
| `f1_25_unshared.sh` | Runs inside the new namespace: mounts the overlay, `cd`s into it and runs the command. |
| `ERD.md` | Requirements and design for the real implementation. |

## Requirements

- Linux with unprivileged user namespaces and unprivileged OverlayFS (kernel 5.11 or newer).
- `unshare` (util-linux).
- Steam with Proton, and F1 25 installed.
- An overlay directory with the Swofty files already built (see below).

This does not work with Flatpak Steam (its sandbox blocks `CLONE_NEWUSER`). It also fails on systems that disable unprivileged user namespaces (`kernel.unprivileged_userns_clone=0`, Ubuntu's AppArmor userns restriction).

## How to run

1. **Prepare the overlay directory.** `f1_25_unshared.sh` expects it at the path in `OVERLAY_DIR`, which is hardcoded:

   ```bash
   OVERLAY_DIR="$HOME/.local/share/swofty-overlay-example"
   ```

   Change it to your own path. It should contain the files Swofty would place in the game folder, laid out relative to the game root. For example `version.dll`, `swofty/...` and `EAAntiCheat.GameServiceLauncher.exe` (the offline-play stub).

2. **Install the scripts.** Both `f1_25.sh` and `f1_25_unshared.sh` must be placed in the F1 25 game folder, and be executable:

   ```bash
   chmod +x f1_25.sh f1_25_unshared.sh
   cp f1_25.sh f1_25_unshared.sh "$HOME/.local/share/Steam/steamapps/common/F1 25/"
   ```

   `f1_25.sh` finds `f1_25_unshared.sh` next to itself, so no `PATH` setup is needed.

3. **Set the Steam launch option.** In Steam, open F1 25 → Properties → General → Launch Options and enter:

   ```
   WINEDLLOVERRIDES="version=n,b" ~/".local/share/Steam/steamapps/common/F1 25/f1_25.sh" %command%
   ```

   - `WINEDLLOVERRIDES="version=n,b"` makes Wine load the native `version.dll` (the Swofty loader) from the overlay.
   - `%command%` is replaced by Steam with the real Proton launch command. Steam starts it with the game folder as the working directory, and the script uses that as the original game directory.

4. **Launch the game from Steam.** The script mounts the overlay on `/tmp/game` and runs the game from there.

## Verifying

While the game is running, the merged view is only visible inside the namespace. To inspect it from the host, use the game's process:

```bash
ls /proc/$(pgrep -f -o GameServiceLauncher)/root/tmp/game
```

The original game folder should be unchanged, with no `version.dll` and no `swofty/` directory.

## Known limitations

- The command is passed through `eval` as a single string, so any argument that contains spaces (other than the game path, which is replaced by `/tmp/game`) loses its quoting.
- Both layers are lower layers and there is no upperdir, so the mount is read-only. Anything the game tries to write under `/tmp/game` (logs, caches) fails. The ERD proposes a writable upperdir.
- `OVERLAY_DIR` and `TARGET_DIR` are hardcoded. There is no check that `/tmp/game` can be created.
- `-r` maps you to root inside the namespace. The ERD proposes an identity mapping so Wine, Proton and Steam see the real uid.
