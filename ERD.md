# TASK_OFS: launch the modded game through an OverlayFS mount (Linux)

Proposal only. Nothing here is implemented yet. Commits are allowed (on this branch, `feat/overlayfs-linux`); pushing is categorically disallowed: never `git push`, never open a PR, never send anything to a remote.

## 1. Context

### 1.1 What happens today (copy mode)

Steam's launch option is `WINEDLLOVERRIDES="version=n,b" <...>/swofty run -- %command%`. With a Steam command present, `swofty run` runs as the **wrapper** (`apps/cli/src/run.rs::wrapper`):

1. `recover::stale` puts back whatever an earlier session left in the game folder (journals in `state/journal`).
2. `compat::write_blocker` refuses a game folder it can't write to.
3. If the launch request says `apply`, `crate::build::install` (`apps/cli/src/build.rs:165`) builds the profile (`build_profile` → `Plan { data, added, loader }`) and `Installer::apply` (`packages/core/src/install.rs`) **copies** every plan file into the game folder, backing each replaced stock file up into `baseline/objects/<sha>`, journalled step by step.
4. `offline::stage` runs the offline-play extension's `f1op-prelaunch` with `--game-dir <game>`. It parks `EAAntiCheat.GameServiceLauncher.exe` as `.exe.bak`, drops the stub (`extensions/offline-play/f1op_stub.exe`) in its place, and copies `f1op_hook.dll` to `swofty/mods/core/`.
5. `play()` points the `state/game-link` symlink at the game folder (Proton can't handle the space in `F1 25`), then spawns `proton run <game-link>/EAAntiCheat.GameServiceLauncher.exe` (the session launcher, picked because `.exe.bak` exists) with `current_dir(game)`.
6. When the game exits, dropping `Session` runs `offline::restore_pending` and `Installer::roll_back` (restoring every replaced original from the object store), then `Installer::tidy` moves logs out of `<game>/swofty/`.

Profiled cost (see `SUMMARY2.md`): about 5 s and 10.4 GiB written per warm install, plus about 3.4 s and 4.5 GiB per exit rollback. Earlier attempts (symlinks, rename-aside) were rejected or still copy the data.

### 1.2 The PoC (`bash-poc/`)

`f1_25.sh` runs `unshare -Urm f1_25_unshared.sh "$@"`, which:

- mounts `overlay` with `lowerdir=<swofty-overlay-example>:<game>` on `/tmp/game` (both read-only, no upperdir),
- `cd`s into the mount, rewrites the game path in the Steam command to `/tmp/game`, and runs it.

Because the mount lives in a private mount namespace, nothing outside that process tree sees it. It disappears by itself when the last process in the namespace exits, and the real game folder is never touched.

### 1.3 The example overlay (`~/.local/share/swofty-overlay-example`, read-only, do not modify)

It's a merged view of what copy mode would place:

- `EAAntiCheat.GameServiceLauncher.exe`: byte-identical to `extensions/offline-play/f1op_stub.exe` (sha `b8f74f83…`).
- `swofty/mods/core/f1op_hook.dll`: identical to `extensions/offline-play/f1op_hook.dll`.
- `version.dll` plus `swofty/addons/core/*`: the bundled loader (`builtin::loader_dir()`).
- `swofty/addons/<id>/native/*.dll`, `swofty/assets*`, `swofty/ui/*`, `swofty/settings.json`: profile-specific loader entries.
- `2025_asset_groups/…` and `cs_20xx_vehicle_package/…`: plan `replace` and `add` entries.
- Files the game wrote at runtime: `swofty/loader.log`, `loader.prev.log`, `swofty/cache/{scan-cache,exe-sha256}.tsv`, `swofty/addons/swofty.career-editor/{snapshot.json,inbox,outbox}`. Under OverlayFS these land in the upperdir.

There's no `.exe.bak` in the overlay. The stub works without it.

## 2. Goal

On Linux, with a new opt-in flag, run the modded game from an OverlayFS mount whose layers are built by Swofty. The flag goes in the Steam launch option:

```
WINEDLLOVERRIDES="version=n,b" <...>/swofty run --use-overlayfs -- %command%
```

In overlay mode, nothing is copied into, backed up from, or restored to the real game folder. The current launch mechanism keeps working the same way: Steam's Play button, the launcher's Play button (the launcher asks Steam, Steam runs the wrapper), `--vr`, and `swofty run` from a terminal.

## 3. Requirements

| # | Requirement | Source |
|---|---|---|
| R1 | Linux only (`cfg(target_os = "linux")`). Windows and the default Linux path are unchanged. | brief |
| R2 | Off by default. Turned on by `--use-overlayfs` on `swofty run` (the Steam launch option). | brief |
| R3 | The wrapper (`swofty run`) does the mounting, so a direct Steam launch works. | brief |
| R4 | Three kinds of layer, highest first: **common** (stub, `version.dll`, bundled `swofty/` loader, offline hook; shared by all profiles) : **profile** (that profile's mod files) : **game folder** (original, read-only). | brief |
| R5 | `upperdir=~/.local/share/swofty/profiles/{profile}/writes`, `workdir=~/.local/share/swofty/profiles/{profile}/workdir`. Constant paths. The upperdir is **left as is** between sessions: it isn't wiped or pruned, because the only writes expected are caches and logs. | brief + answer |
| R6 | The mount target is never the original game folder (the game doesn't start that way). | brief |
| R7 | Overlay mode skips baseline backups, `place`, rollback and offline staging in the real folder. | brief |
| R8 | Logs the game writes under `swofty/` are redirected away from the game folder: they land in the upperdir and are collected into `~/.local/share/swofty/logs` (and the session folder). The native loader isn't changed. | brief + answer |
| R9 | If OverlayFS can't be used, fall back to copy mode for that launch. Show a **blocking desktop popup** with **Exit** (cancel the launch) and **Continue** (launch in copy mode) buttons and a "Don't show again" checkbox, which persists when Continue is clicked, **and** a launcher note. | brief + answer |
| R10 | Profile layer: copy the plan's files once per build into a per-profile tree, reused while the build is unchanged. No hardlinks. The existing `cache/overlay/<profile>/<hash>` build is unchanged. | brief + answer |
| R11 | Don't touch the native loader or the offline stub (`native/`, nix-only builds) unless unavoidable. This plan needs no native changes. | brief |
| R12 | Update the docs afterwards. | brief |

## 4. Design

### 4.1 Paths (all under the data root `~/.local/share/swofty`, via new `Store` helpers)

| Path | What | Helper (new) |
|---|---|---|
| `overlay/common/` | common layer (R4) | `Store::overlay_common_dir()` |
| `overlay/common.stamp` | digest of what built it | — |
| `profiles/{profile}/overlay/` | profile layer (R10) | `Store::profile_layer_dir(p)` |
| `profiles/{profile}/overlay.stamp` | digest of the plan it was built from | — |
| `profiles/{profile}/writes/` | upperdir (R5) | `Store::overlay_upper_dir(p)` |
| `profiles/{profile}/workdir/` | workdir, same filesystem as `writes` | `Store::overlay_work_dir(p)` |
| `state/overlay/game/` | mount target, an empty dir on the host (R6) | `Store::overlay_target()` |
| `state/overlay/session.json` | live session: game dir, profile, target, upper, anchor (pid, start time, mount namespace), §4.9.3 | `overlayfs::LiveSession` |
| `state/overlay/last.json` | last overlay session (game, profile, upper), kept after exit, §4.9.3 | — |
| `state/overlayfs-fallback.json` | launcher note record (R9) | `overlayfs::Fallback` |
| `logs/` | collected game-side logs (R8) | `Store::logs_dir()` |

`profiles/` already holds `{profile}.json`, so a `profiles/{profile}/` directory beside it doesn't clash. Deleting or renaming a profile (`Store` profile deletion) must also remove or rename `profiles/{profile}/`. The target sits under the data root, which also keeps it free of spaces for the same reason `state/game-link` exists.

### 4.2 Building the layers (new module `packages/core/src/overlayfs.rs`, Linux-gated)

**Splitting the plan.** `build_profile` stays as it is. From the resulting `Plan`:
- common: `plan.loader` entries whose source is under `builtin::loader_dir()` (`version.dll`, `swofty/addons/core/*`), plus `f1op_stub.exe` → `EAAntiCheat.GameServiceLauncher.exe` and `f1op_hook.dll` → `swofty/mods/core/f1op_hook.dll` from `offline::artifacts()` (pinned digests are verified there already).
- profile: `plan.data` + `plan.added` + the remaining `plan.loader` entries (addon native DLLs, `swofty/assets*`, `swofty/ui/*`, `swofty/settings.json`).

**Materialising** (the same routine for both layers): `fn materialise(dir, entries: &BTreeMap<rel, src>, stamp) -> Result<bool>`.
- Stamp = sha256 over the sorted `(rel, src, len, mtime)` list (for the profile, also `buildhash`; for common, also the extension version and loader stamp, reusing `build.rs::stamp_tree`). If the stamp file matches and the dir exists, do nothing. That's the warm launch: zero bytes written.
- Otherwise build `dir.new/` with plain `std::fs::copy` (it clones on btrfs/XFS reflink, consistent with the TASK4 note), fsync the stamp, then `rename(dir, dir.old)`, `rename(dir.new, dir)`, and remove `dir.old`. A crash leaves at most a stale `.new`/`.old`, which is removed on the next run.
- Check free space first with `crate::disk` (the same approach as `Installer::space`). If there isn't enough room, it's a fallback reason.
- Plain files only. No symlinks, hardlinks or permission changes (the SUMMARY2 constraints).
- `cache::prune` doesn't touch these dirs. A rebuild replaces the profile layer, so only one copy per profile exists.

Layers are only rebuilt while the session lock is held and no mount is live. `state/overlay/session.json` lists a live pid, checked through `/proc/<pid>`. Changing a lower layer under a live mount is undefined behaviour in OverlayFS.

### 4.3 Mounting (the hidden subcommand `swofty overlay-exec`)

`unshare(CLONE_NEWUSER)` fails with `EINVAL` in a multithreaded process, and the wrapper has threads (signal handling, follower). So the namespace is made in a **fresh child process**: the wrapper re-executes itself (`std::env::current_exe()`) as

```
swofty overlay-exec --lower <common> --lower <profile> --lower <game> \
    --upper <writes> --work <workdir> --target <state/overlay/game> [--check] -- <proton> run <exe> <args…>
```

In `apps/cli/src/overlay_exec.rs`, using `libc` (already a Linux dependency of both crates):
1. `unshare(CLONE_NEWUSER | CLONE_NEWNS)`.
2. Write `/proc/self/setgroups` = `deny`, `/proc/self/uid_map` = `<uid> <uid> 1`, `/proc/self/gid_map` = `<gid> <gid> 1`. This is an **identity** mapping, unlike the PoC's `-r`, so Wine, Proton and Steam see the real uid. Root inside the namespace isn't needed, because the capabilities from `unshare` are enough for `mount` before `exec`. If testing shows Proton needs it, switch to the `-r` mapping the PoC used.
3. `mount(NULL, "/", NULL, MS_REC|MS_PRIVATE, NULL)` so nothing propagates back to the host.
4. `mount("overlay", target, "overlay", 0, "lowerdir=A:B:C,upperdir=U,workdir=W")`. Escape `\`, `:` and `,` in paths. Try `userxattr` first and retry without it on `EINVAL` (kernels before 5.11 have no unprivileged OverlayFS at all, which is a fallback reason). Create `writes/` and `workdir/` beforehand.
5. `chdir(target)`. This must happen **after** the mount, or the cwd is the empty host directory underneath (the PoC `cd`s after mounting for the same reason). This is why the wrapper must not set `current_dir(target)` on the helper.
6. With `--check`, exit 0 here; the mount goes away with the process. Otherwise print one line, `mounted`, to stdout (the handshake) and **spawn** the command as a child, wait, and exit with its code (a signal becomes 128+n). The helper stays alive as the namespace's anchor and as the wrapper's `Child` handle.

Each failing step exits with a distinct code (for example 90 for unshare, 91 for maps, 92 for mount) and a one-line `swofty: overlayfs: <step>: <errno text>` on stderr. The wrapper turns that into the fallback reason.

Because the mount lives only in that namespace, there's **nothing to recover after a crash**. A `kill -9` of anything just drops the mount. The real game folder is untouched in every case.

### 4.4 Wrapper integration (`apps/cli/src/run.rs`)

- `RunArgs`: add `#[arg(long, help = "Linux: run the modded game from an OverlayFS mount instead of copying files into the game folder")] use_overlayfs: bool`. On other platforms, accept and ignore it with a log line, or hide it with `cfg`.
- In `wrapper()`, after `recover::stale` (which still cleans up leftovers of an earlier copy-mode or fallback session) and `offline::gate`, choose a mode:
  ```
  enum Mode { Copy, Overlay(overlayfs::Mount) }
  ```
  Overlay is chosen when `--use-overlayfs` is set **and** this is Linux **and** Proton was found in the Steam command **and** `Source::detect == Steam` **and** `apply` is set **and** the game folder carries no persistent `swofty apply` install (open journals or `placed.json` entries). Each failed condition is a fallback reason ("EA app copies aren't supported", and so on), except a missing flag, which is just copy mode. If any of these conditions fails (other than the missing flag), the session falls back to copy mode and a message box pops up. It names the failed condition and says the game files are copied this session. It has its own "Don't show again" checkbox. Ticking it hides the box for **every** reason in this list (Linux, Proton, Steam copy, `apply`, persistent install). It is a separate setting from the "Don't show again" for a failed mount (§4.6), so turning one off never hides the other.
- Overlay path:
  1. `crate::build::build_profile` (no `install`, no `check_stock`, no baseline). The stock check is part of the backup stage, so it's skipped too (R7). `heal_launcher` isn't needed because the real EAC exe is never parked.
  2. `overlayfs::prepare(store, profile, &plan, &artifacts)` materialises both layers.
  3. `overlay-exec --check`. On failure, fall back.
  4. Skip `offline::stage` (the stub and hook are in the common layer). Keep `offline::probe_cached` (it reads the real exe, which is fine).
  5. `play()` gets the mode. With Overlay it:
     - uses a separate symlink `state/game-link-overlay` → the target (keep `state/game-link` for copy mode);
     - launches `EAAntiCheat.GameServiceLauncher.exe` explicitly, not through the `.exe.bak` check;
     - wraps the spawn: `Command::new(current_exe).arg("overlay-exec")…--.arg(proton).arg("run").arg(link.join(exe))`, waits for `mounted` on the child's stdout (with a timeout; if it isn't seen, kill it and fall back before the game starts), then forwards the rest of stdout/stderr to `game_stdout.log` as today;
     - right after the handshake and before Proton starts, writes `state/overlay/session.json` with the anchor (`overlay-exec`'s pid, start time and mount namespace) and updates `state/overlay/last.json` (§4.9.3).
- **Fallback** (`fn fall_back(store, reason)`): writes `state/overlayfs-fallback.json { at, reason }`, logs `[warning] overlayfs: <reason>; copying files into the game folder this session`, shows the popup (§4.6) unless suppressed and **waits for it**. On **Exit** the wrapper stops here: nothing is copied or staged, and it exits with a distinct code. On **Continue** (or when the popup is suppressed or can't be shown) it runs **today's path unchanged**: `compat::write_blocker` check, `build::install`, `offline::stage`, and so on. The `write_blocker` check moves into the copy path, because overlay mode doesn't need a writable game folder.
- `Session::drop`: in overlay mode, `offline::restore_pending` and `Installer::roll_back` have nothing to do and are skipped (or run harmlessly as no-ops). `Installer::tidy` is replaced by `overlayfs::collect_logs` (§4.5). Remove `state/overlay/session.json`.
- The "Apply & restart" loop (`run_loop`): re-prepare the profile layer instead of `build::install`. The relaunch uses a new `overlay-exec`. The previous namespace dies with the previous game.

### 4.5 Logs and other game-side files (R8)

The loader opens `<game_dir>\swofty\loader.log` (`native/src/loader/version.c::open_log`). In the mount that's a write into the upperdir: `profiles/{p}/writes/swofty/loader.log`. The same goes for `perf.log`, crash dumps, `cache/*.tsv` and addon storage. No native change is needed.

Host-side readers that currently use `game.join(...)` get a `log_root` (the game dir in copy mode, the upperdir in overlay mode):
- `run.rs::play` / `wrapper` / the non-wrapped follower: `LOADER_LOG` for `LogMark::read`, `AttachWatch`, `keep_game_logs`, `PERF_LOG`. The non-wrapped `run()` (launcher or terminal) also reads `game.join(LOADER_LOG)`, so it needs the same root. It can read `state/overlay/session.json`, or the wrapper can write the root into the session folder.
- `send_logs::newest_crash`, `loader_check::collect`, `quarantine::missing` and `loader_missed`: look in the layers and the upper, not the game folder. `check_loader`'s placed-DLL check becomes "present in the common layer" (`quarantine::placed_dlls` is written by the installer, so overlay mode records its own list or skips that check).
- `overlayfs::collect_logs` at session end **copies** `writes/swofty/*.log`, `*.dump` and `crash-*` into `~/.local/share/swofty/logs/` and the session's `game-logs/`. The upperdir isn't changed (R5), and the loader's own `loader.log` → `loader.prev.log` rotation keeps it bounded.

Other things the host reads or writes in the game folder at runtime (must be handled, see §7):
- **Career Editor bridge** and any other launcher helper that uses `addon_game_dir`: these go through the game's namespace (`/proc/<pid>/root`). See §4.9.

### 4.6 Fallback popup and launcher note (R9)

- **Two kinds of fallback, each with its own suppression.** `Fallback` carries a `kind`:
  - `Unsupported`: a mode-selection check in §4.4 failed (not Linux, no Proton, not a Steam copy, no `apply`, persistent install). Key `overlayfs-unsupported`.
  - `MountFailed`: overlayfs couldn't be used (layer preparation failed, `overlay-exec --check` failed, no `mounted` handshake). Key `overlayfs-fallback`.

  Both keys go in `Config::news_seen` (same pattern as `EA_APP_SEEN` in `install.rs:78` and `apps/launcher/src/ea_app.rs`). The wrapper checks only the key for the record's kind, and the dialog writes only that key, so the two "Don't show again" choices are independent.
- **Popup (blocking):** the wrapper runs `swofty-launcher --overlayfs-fallback-dialog <kind> <reason>` (the binary next to `swofty`, or in `Store::bin_dir()`) and **waits for it to exit** before doing anything else. Nothing has been copied or staged yet at that point. It's a small gpui window in a new `apps/launcher/src/overlayfs_dialog.rs` with:
  - a title per kind ("OverlayFS can't be used for this launch" / "OverlayFS mount failed"), the reason text, and a docs link;
  - a **"Don't show again"** checkbox;
  - two buttons: **Exit** (cancel) and **Continue** (OK, the default button).

  The dialog's result is its exit code:
  - **Continue** (exit 0) launches in copy mode. If the box is ticked, the dialog first inserts that kind's key into `news_seen` and saves the config, so later launches of this kind go straight to copy mode without asking.
  - **Exit** (exit 1), or closing the window, cancels the launch. The checkbox is **not** saved on Exit, so a suppressed popup never means "always exit". The wrapper writes a `launch::Failure` with a new `Cause::OverlayCancelled { kind, reason }` so the launcher shows why nothing started, logs `overlayfs: launch cancelled in the fallback dialog`, and exits non-zero without touching the game folder. Steam then shows the game as stopped.
  - If the dialog can't be shown (no launcher binary, no `DISPLAY`/`WAYLAND_DISPLAY`, the dialog crashes), the wrapper logs why and **continues** in copy mode, as it did before this flag existed. The launcher note still appears.

  This mode must skip the launcher's normal start-up (single-instance handling, discovery, recovery), so it works while the launcher is already open.

  Waiting on the dialog must not trip the "wrapper wrote nothing" timeouts in the non-wrapped `swofty run` and in the launcher (`Silence` in `run.rs`, and the 10 min check in `apps/launcher/src/game.rs`). While the dialog is open, the wrapper writes `state/overlayfs-dialog.pending`, plus a log line every 30 s. Both followers treat a pending dialog as activity and say "waiting for your answer in the OverlayFS dialog".
- **Launcher note:** `game::Probe` gains `overlay_fallback: Option<overlayfs::Fallback>` (read from `state/overlayfs-fallback.json`). `Shell::apply` shows a `Notification::warning` once per record (`at > overlay_fallback_seen`), like the `recovered` notice, and sets `self.notice`. The note is shown even when the popup is suppressed. Only the popup has the checkbox.

### 4.7 Process detection

`GameProcess::is_in(dir)` (`packages/core/src/process.rs`) compares the game's origin folders (from its exe and the Wine path) with the game folder. In overlay mode the game runs from `state/overlay/game` (seen as `Z:\…\state\overlay\game` or through `game-link-overlay`), so `game_running_in`, `games_in`, `stop_game_in`, `wait_relaunched`, the launcher's running state and `already_running` would all miss it. Fix: `same_folder` (or `Origin::folders`) also counts the overlay target as an alias of the game dir when `state/overlay/session.json` names that game. Add a unit test with a faked origin.

### 4.8 Edge cases

- **Persistent `swofty apply` install in the folder:** that's a fallback reason. The real folder isn't vanilla, and mixing the two modes would double-apply.
- **Steam updates or verify while the mount is live:** Steam doesn't update a running game, and the mount dies with the game.
- **Flatpak Steam:** the sandbox's seccomp filter blocks `CLONE_NEWUSER`, so it falls back. Same for distros with `kernel.unprivileged_userns_clone=0` or Ubuntu's AppArmor userns restriction (unshare succeeds but mount gives `EPERM`). Each falls back with the errno in the reason.
- **Supplementary groups** show up as `nogroup` inside the user namespace. Controllers normally work through uaccess ACLs, but a setup that relies on the `input` group could lose them. Note this in the docs and test a wheel or pad.
- **Library on another filesystem** (NTFS, exFAT, FUSE): a lowerdir mostly works. The upper/work dirs are on the data root (ext4 or btrfs), which is fine.
- **Copy-ups:** if anything rewrites a lower file, the full file is copied into `writes/` and, because the upperdir is kept (R5), it shadows future builds of that path. That isn't expected. Log a one-line warning at mount time when `writes/` holds a regular file whose rel path exists in a lower layer, but don't delete anything, per the answer to R5.

### 4.9 Addon folders seen from the launcher: the Career Editor bridge (option A, `/proc/<pid>/root`)

#### 4.9.1 The problem

The Career Editor has two halves that talk only through files in `<game>/swofty/addons/swofty.career-editor/` (`addons/career-editor/protocol/bridge.md`):

| File | Written by | Read by |
|---|---|---|
| `inbox/<seq>.json` (command batches) | launcher helper (atomic: `<seq>.json.tmp`, then rename) | game, which deletes it once acknowledged |
| `outbox/<seq>.json` (acks) | game (storage API: temp file, then rename) | helper, which deletes it after reading |
| `snapshot.json` | game (temp file, then rename) | helper |
| `journal.jsonl` | game (append) | helper |

The helper gets the folder from the `addon_game_dir` host call. `packages/core/src/helper.rs:507` builds it as `GameFiles::dir()` + `swofty/addons/<id>`, and `GameFiles::dir()` for the launcher is `registry::GameDir::dir()` (`packages/core/src/registry.rs`), which returns the real game folder. The helper asks again on **every tick** (`career-editor/launcher/src/main.rs`: `tick()` → `locate()` → `store.set_mailbox(..)`), so a path that changes between sessions is picked up on its own.

In overlay mode the game sees the merged view inside its namespace, while the helper runs on the host and sees the real game folder (only the bottom layer, with no `swofty/` at all). So:
1. **Game to helper:** `snapshot.json`, `outbox/` and `journal.jsonl` land in the upperdir. The helper looks in the real folder and finds nothing.
2. **Helper to game:** the helper's `create_dir_all(inbox)` and batch writes would recreate `swofty/` in the real game folder, which overlay mode must never change (R7). It's also a change to a live lower layer, which is undefined in OverlayFS. In practice the game may never see the batch, because of cached merged-directory listings and cached "file doesn't exist" lookups.
3. **Deletes:** the game deleting an acknowledged inbox file only records a whiteout in the upperdir. The real file stays, so the helper sees the batch as still pending. And a batch the helper withdraws by deleting it may still be visible, and run, inside the game.
4. **Pointing the helper at the upperdir instead** fixes reads but not writes or deletes, which are again changes to a live layer outside the overlay. A stale "ack exists" or "file is gone" view breaks the protocol's rule against running a batch twice ("an inbox file whose ack already exists is dropped"): batches could run twice or be lost.

#### 4.9.2 The approach

While an overlay session is live, `addon_game_dir` returns the addon folder **as the game sees it**, through the mount namespace of a process inside it:

```
/proc/<anchor pid>/root/<target>/swofty/addons/<id>
```

`/proc/<pid>/root` is a link to that process's root in its own mount namespace, and path lookup continues inside that namespace's mount tree. So every open, write, rename, readdir and unlink the helper makes goes through the overlay, exactly as if the game made it: writes and copy-ups land in the upperdir, deletes become proper whiteouts, and the overlay's caches stay right. No bind mounts, no manifest flags, and no native changes.

The **anchor** is the `overlay-exec` process (§4.3), not the game's pid. It's in the namespace from before Wine starts until the game exits, its pid is known to the wrapper (`Child::id()`), and it doesn't change when the session launcher hands over to `F1_25.exe`.

#### 4.9.3 Recording the anchor (`state/overlay/session.json`)

The wrapper writes this file right after the `mounted` handshake, **before** Proton starts, so it's never missing while the game could be using the bridge:

```json
{
  "schema": 1,
  "game": "/home/…/steamapps/common/F1 25",
  "profile": "default",
  "target": "/home/…/.local/share/swofty/state/overlay/game",
  "upper": "/home/…/.local/share/swofty/profiles/default/writes",
  "anchor": { "pid": 12345, "start_time": 987654321, "mnt_ns": "mnt:[4026532871]" }
}
```

- `start_time`: field 22 of `/proc/<pid>/stat`, read by the wrapper. Together with the pid it identifies the process even if the pid is reused.
- `mnt_ns`: `readlink /proc/<pid>/ns/mnt` once the handshake arrives. It proves the anchor is in the overlay namespace and not the host's.
- Written atomically (temp file, then rename), like the other state files.
- Removed in `Session::drop` and rewritten for every relaunch ("Apply & restart" starts a new `overlay-exec` with a new anchor).
- `state/overlay/last.json` keeps `{ game, profile, upper }` of the last overlay session after `session.json` is removed. It's used when no session is live (§4.9.4).

#### 4.9.4 Resolving the path (`overlayfs::addon_dir(store, game, id)`, Linux only)

`HostCall::AddonGameDir` calls a new `GameFiles` method (for example `addon_dir(id) -> Option<PathBuf>`, with a default that keeps today's `dir()/swofty/addons/<id>`). `registry::GameDir` implements it as:

1. **Live overlay session:** `session.json` exists, its `game` is this game (`copies::same_dir`), and the anchor checks out:
   - `/proc/<pid>/stat` exists, and its start time equals `start_time`;
   - `readlink /proc/<pid>/ns/mnt` equals `mnt_ns`;
   - `/proc/<pid>/root/<target>/swofty` is a directory (the mount is visible).

   Then return `/proc/<pid>/root/<target>/swofty/addons/<id>`.
2. **No live session, but the last session was an overlay session** for this game (`last.json`), and the profile is the one Play uses: return `<upper>/swofty/addons/<id>`. Nothing is mounted now, so reading and writing the upperdir directly is safe: the helper can show the last `snapshot.json` and queue batches that the next session picks up.
3. **Otherwise** (copy mode, a copy-mode fallback session, Windows): today's `<game>/swofty/addons/<id>`, unchanged.

If `session.json` exists but the anchor fails a check (the wrapper was killed and the file wasn't removed), it's treated as stale: log once, delete it, and continue with step 2. A stale file never makes the host fall back to writing into the real game folder in overlay mode.

The helper's `tick()` asks again every tick, so the change from step 2 to step 1 at launch, and back at exit, needs no helper change. The helper must cope with the path not existing yet (`create_dir_all`, which it already does for the inbox).

#### 4.9.5 Why the access is allowed

- `/proc/<pid>/root` needs `ptrace_may_access(PTRACE_MODE_READ_FSCREDS)` on the anchor. The anchor runs under the same uid and gid as the launcher (identity mapping, §4.3 step 2), and the launcher's user owns the anchor's user namespace, so the check passes without `CAP_SYS_PTRACE`.
- Yama (`kernel.yama.ptrace_scope=1`, the usual default) only restricts `PTRACE_MODE_ATTACH`, so it doesn't apply to a READ-mode check. Even `ptrace_scope=2` restricts only attach. With `ptrace_scope=3` the check still applies only to attach, but this is worth one manual test.
- The anchor stays dumpable: it doesn't change credentials or exec a setuid binary before `/proc` is read. If the dumpable flag is ever cleared, the access fails with `EACCES`.
- A `/proc` mounted with `hidepid=2` hides other users' processes, not our own, so it doesn't matter.

If access still fails (`EACCES`/`EPERM`), the resolver logs it once (`overlayfs: the launcher can't reach the game's view through /proc/<pid>/root: <errno>`) and returns **no** live path. The host call then fails with a clear error ("the game runs in an OverlayFS session the launcher can't reach"). It never falls back to the real game folder or a live upperdir, either of which would corrupt the bridge.

#### 4.9.6 `GameDir` stays the real game folder

`HostCall::GameDir` (`registry::GameDir::dir()`) keeps returning the real game folder in every mode:
- The driver manager reads `game_dir` once and keeps it (`addons/driver-manager/launcher/src/app.rs`, `refresh_files`), so a path that changes per session would go stale.
- Helpers use it to read the game's own files, which the real folder still has.

One existing use needs the merged view: the Career Editor reads the loader's binding sets from `game_dir/swofty/addons/core` (`career-editor/launcher/src/main.rs`, `live::binding_builds`) to tell an unsupported game build. In overlay mode the real folder has no `swofty/`. Fix it in the helper (Rust, launcher side, not native): read them from `addon_game_dir/../core`, falling back to `game_dir/swofty/addons/core`. It's only used while the game runs and the bridge is missing, so that resolves through the anchor to the common layer's `swofty/addons/core`.

#### 4.9.7 Lifetime and races

- **Launch:** before `session.json` exists, the helper may still get the step 2 path (the upperdir) and write a batch there. The mount appears only after the handshake, and the wrapper writes `session.json` before starting Proton. The game's DLL reads the inbox much later (after the loader attaches and a career is loaded), so the window is between handshake and file write: milliseconds, with no game code running. A batch written to the upperdir in that window is still seen by the game: `inbox/` is only ever created at runtime, so it exists only in the upperdir, which OverlayFS reads directly with no merged listing to go stale. Document it as an accepted, harmless race.
- **Exit:** `overlay-exec` exits when Proton exits, so the anchor check fails and the helper moves to step 2 (the upperdir). Wine leftovers such as `wineserver` can keep the mount alive a few seconds longer, but the game's DLL is gone, so nothing in the namespace touches the bridge anymore. Touching the upperdir then is safe in practice.
- **Crash or `kill -9` of the wrapper:** `session.json` stays behind. The anchor checks catch that (no process, different start time, or different namespace) and remove it (§4.9.4).
- **Profile switch while not running:** step 2 uses `last.json`'s profile only when it's the one Play uses. Otherwise the helper gets that profile's own upperdir path (`profiles/{p}/writes/swofty/addons/<id>`), which may not exist yet; it creates it when it queues a batch. This keeps each profile's storage separate, like the upperdirs.

#### 4.9.8 Other helpers and the public API

`addon_game_dir` is part of the launcher addon API (`packages/addon-api/src/helper.rs`, `docs/reference/addons/launcher-api.md`). Third-party helpers get the same behaviour: in overlay mode the returned path may be under `/proc/<pid>/root/…` while the game runs, and is a data-folder path (the upperdir) when it doesn't. It's never in the real game folder. Document that helpers must re-query it rather than cache it, and mustn't store it or show it to the user as the game folder.

## 5. Implementation steps (one small, reviewable commit per step on this branch; commit locally, never push)

1. `packages/core`: `Store` path helpers; profile delete/rename also handles `profiles/{p}/`; `overlayfs.rs` with plan split, `materialise`, stamps, `Fallback` record, `collect_logs`, `session.json`. Unit tests (§6).
2. `apps/cli`: `overlay-exec` hidden subcommand (`main.rs` + `overlay_exec.rs`): option escaping, error codes, handshake. Unit test for the option string; an ignored-by-default integration test that does a real unprivileged mount on a tempdir (`#[ignore]` when `unshare` gives `EPERM`).
3. `apps/cli/src/run.rs`: `--use-overlayfs`, mode selection, fallback, the `play()` spawn wrapper, log roots, `Session::drop` and the restart loop.
4. `process.rs` alias for the target.
5. Addon folder resolution (§4.9):
   - `LiveSession` / `last.json` with the anchor checks;
   - `overlayfs::addon_dir`, a new `GameFiles::addon_dir` with a default, implemented by `registry::GameDir`;
   - `HostCall::AddonGameDir` uses it; `GameDir` is unchanged;
   - the Career Editor helper reads binding sets via `addon_game_dir/../core`.
6. Launcher: probe and notification for the fallback record; `--overlayfs-fallback-dialog` window with "Don't show again".
7. `swofty doctor`: report whether the launch option has `--use-overlayfs`, and a quick `overlay-exec --check` result (kernel, userns, mount).
8. Docs (§8).

## 6. Tests

Automated (`cargo test --release -p swofty-core -p swofty-cli --no-fail-fast`, plus `cargo fmt` and `cargo clippy`):
- Plan split: core loader, stub and hook go to common; addon DLLs, assets, ui, settings, data and added go to profile; the two layers have no rel path in common.
- `materialise`: builds once; the second call writes nothing (same stamp); a changed source (mtime/len) or buildhash rebuilds; an interrupted build (`.new` left) is cleaned up; never creates links; a full disk gives an error and leaves the old layer intact.
- Escaping of `:`, `,` and `\` in lowerdir paths.
- Fallback record round trip, with its kind; each kind checks and writes only its own `news_seen` key (suppressing `Unsupported` still shows `MountFailed`, and the other way round).
- `is_in` treats the overlay target as the game folder only while `session.json` names it.
- `addon_dir` resolution (§4.9.4), using a temp data root and a fake `/proc` reader behind a small trait:
  - live anchor → the `/proc/<pid>/root/<target>/swofty/addons/<id>` path;
  - a dead pid, a different start time or a different `mnt_ns` → `session.json` is treated as stale and removed, and the result is the upperdir from `last.json`;
  - no overlay session ever → today's `<game>/swofty/addons/<id>`;
  - a different profile than `last.json` → that profile's upperdir;
  - a different game folder in `session.json` → today's path;
  - inaccessible `/proc/<pid>/root` → an error, never the real game folder.
- `GameDir` returns the real game folder in every mode.
- Real-kernel test (ignored when `unshare` gives `EPERM`, like the mount test): start `overlay-exec` with a tiny command that sleeps. Through `/proc/<pid>/root/<target>`, create a file, rename onto it, list the folder and delete a file that's in a lower layer. Check that the file and rename show up in the upperdir, the delete becomes a whiteout there, the lower layer and the "game" tempdir are unchanged, and the namespace sees each change at once.
- Copy-mode tests (`restore`, `session_recovery`, `damaged_state`) still pass unchanged: Windows and default Linux behaviour are the same.
- Overlay mode never writes into the game dir: run the overlay prepare path against a tempdir game, and check the game tree (hashes and mtimes) is byte-identical before and after.

Manual (release build; the launch option in PRETASK5 plus `--use-overlayfs`; recreate `target/loader` → `/home/minik/SwoftyLauncher/loader` first, because it's missing right now):
- Launch from Steam Play and from the launcher. Mods and loader attach in-game, and `loader.log` ends up in `~/.local/share/swofty/logs` and the session folder.
- The second launch writes about 0 bytes and starts without the 5 s install. Exit takes no rollback time. Record numbers against the SUMMARY2 baseline (5 s / 10.4 GiB, 3.4 s / 4.5 GiB).
- After exit or `pkill -9 -f "[s]wofty run"`: `find "<game>" -newer <marker>` is empty, there's no `version.dll` or `.bak`, `findmnt` on the host shows no overlay, and Steam "verify integrity" is clean.
- Switch profiles: each has its own layer and upper; the common layer is shared.
- Force a fallback (for example `sysctl kernel.unprivileged_userns_clone=0`, or a test-only env var that makes `overlay-exec` fail): the popup appears and the launch waits for it. **Exit** cancels: no game, nothing copied into the game folder, and the launcher shows the cancel reason. **Exit** with the box ticked doesn't suppress the next popup. **Continue** launches in copy mode and the launcher shows the note. After "Don't show again" plus Continue, the popup no longer appears (the launch goes straight to copy mode), but the note still does. A popup left open for over 2 min doesn't make the launcher or `swofty run` report a stuck wrapper. Repeat with an unsupported condition (for example `--use-overlayfs` with `swofty apply` installed in the folder): its popup still appears after the mount-failure one was suppressed, and has its own "Don't show again".
- Career Editor in overlay mode:
  - with a career loaded, `bridge.ping` round-trips, and a cash set applies once (no second run after a restart);
  - withdrawing a waiting batch stops it;
  - `snapshot.json` updates live;
  - after exit, the editor still shows the last snapshot (read from the upperdir);
  - a batch queued while the game is closed runs in the next session;
  - `find "<game>/swofty"` doesn't exist the whole time;
  - the helper log shows the `/proc/<pid>/root/…` path while running and the upperdir path after.

  Repeat with `kernel.yama.ptrace_scope=2`.
- A wheel or pad works.
- `--vr` and "Apply & restart" still work.

## 7. Open points to confirm during implementation

1. Decided: the Career Editor bridge and `addon_game_dir` go through `/proc/<pid>/root` (option A, §4.9). Confirm on the target machine that it works with the configured `ptrace_scope`. Bind-mounting host folders into the namespace and moving the bridge out of the game tree were rejected: the first needs manifest flags and copies of the addon DLLs, the second needs native changes.
2. Identity uid mapping vs the PoC's root mapping (`-r`): confirm Proton is happy with the identity mapping.
3. Whether `check_stock` should still run in overlay mode as a warning only. It's skipped in this plan as part of the backup stage.
4. `userxattr`: keep it if the mount accepts it on the target kernel (7.3), otherwise drop it.

## 8. Docs to update after implementation

- `docs/guide/linux.md`: the optional `--use-overlayfs` launch option, requirements (unprivileged user namespaces; not Flatpak Steam), and what the fallback popup means.
- `docs/reference/cli.md`: `swofty run --use-overlayfs`; `overlay-exec` stays hidden or is named as internal.
- `docs/reference/launch.md`: the overlay session flow, layers and paths, fallback.
- `docs/reference/restore.md` and `docs/using/profiles-and-restoring.md`: overlay sessions never change the game folder, so there's nothing to restore. The fallback is copy mode with today's rules.
- `docs/reference/safety.md`: the offline stub is served from the common layer; the real EAC exe is never moved.
- `docs/reference/std/storage.md` and the Career Editor docs: in overlay mode, addon storage persists in `profiles/{profile}/writes/swofty/addons/<id>/`, per profile.
- `docs/reference/addons/launcher-api.md`: `addon_game_dir` in overlay mode (a `/proc/<pid>/root/…` path while the game runs, the profile's upperdir when it doesn't, never the real game folder); helpers must re-query it instead of caching it; `game_dir` is always the real game folder.
- `addons/career-editor/protocol/bridge.md`: the mailbox folder in overlay mode, and the binding-set lookup via `addon_game_dir/../core`.
- A release note under `docs/releases/` for the next version.
