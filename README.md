# steamac with genuine-EAC games and a DXMT graphics path

**English** · [Русский](README.ru.md) · [简体中文](README.zh.md)

**A fork of [steamac](https://github.com/fxgl/steamac) for Apple silicon Macs. It runs x86-64 Windows games with genuine
Easy Anti-Cheat (verified: VRChat), with a choice of two graphics paths.**

- **Vulkan (classic)**: Direct3D through DXVK on Vulkan inside SteamOS (Venus), then KosmicKrisp or MoltenVK on the Mac.
  This is upstream steamac's path.
- **DXMT (lean)**: Direct3D 11 through [DXMT](https://github.com/3Shain/dxmt). Its Metal calls run natively on the Mac
  over a dedicated virtio-gpu channel, so there are fewer translation layers.

The EAC client is the stock one from the Proton EasyAntiCheat Runtime. Nothing fakes, replays or short-circuits its
result. Not affiliated with FX GAMES, Valve, Epic Games, VRChat or the DXMT authors.

Status: verified on one Mac and one anti-cheat title. The default is the Vulkan path; DXMT is a setting you turn on.
Published VRChat frame rates exist only for the Vulkan path (about 26-30 fps in a light world at 1280x800); there are
no published figures for DXMT yet.

## Requirements

| you need | notes |
|---|---|
| an Apple silicon Mac | verified on an M2 MacBook Air, 16 GB, macOS 27.0; other Macs are untested |
| macOS 15 or newer | KosmicKrisp (the faster Vulkan driver) needs macOS 26. The DXMT path's host library is built for macOS 15.5 or newer |
| free disk space | about 14 GB on the disk's volume while the SteamOS disk is created (about 9 GB afterwards), plus room for games (the home size is chosen at creation and can be enlarged later with Grow Disk) |
| memory | 16 GB minimum; less is not supported. Automatic VM RAM is half of the Mac's RAM (4-16 GiB) |
| a Steam account | games are installed and run inside SteamOS |

## Install and first launch

1. Download `FX-Steam-Launcher-<version>.dmg` from this fork's release page, drag **FX Steam Launcher.app** to Applications
   and open it.
2. On first start, choose **Create New Disk…**. The app downloads Valve's SteamOS image, verifies it and sets it up.
   This takes a while, once.
3. Sign in to Steam in the window. Keep a **16:10** window size (Settings > Display > Default window
   size; the default, 1280×800, is 16:10). A 16:9 game in a 16:10 window is letterboxed.
4. Grant the **microphone** permission when macOS asks. Without it, the guest's audio capture fails repeatedly and games
   can stutter.
5. In Steam, install VRChat, set its compatibility tool to **Proton Experimental**, and install **Proton EasyAntiCheat
   Runtime**. See [SETUP.md](SETUP.md) for the full steps.

## Choosing the graphics path

Settings > Advanced > **Graphics path**: *DXMT (lean)* or *Vulkan (classic)*; it applies from the next start. Nothing
to set per game: when Steam starts, every installed Proton gets the selected path, and Proton puts it into each game's
prefix. Switching back to *Vulkan* restores Proton's own files exactly. DXMT covers Direct3D 11 (and 10); play Direct3D
12 games on *Vulkan* (untested or limited under DXMT). EAC with DXMT on a real prefix is unverified until first launch;
switch to *Vulkan* if EAC fails.

The **Metal Performance HUD** shows the frame rate on either path: Settings > Display, the View menu, or Ctrl+Cmd+P. It can
be turned on and off while a game runs.

## Easy Anti-Cheat

EAC runs inside SteamOS under Valve's FEX emulator. This fork's patched FEX passes EAC's checks for VRChat. Today two
manual steps are required for VRChat; both are planned to become automatic:

1. Install the patched FEX: enable SSH (Settings > Advanced), then run `build-fex.sh` and `install-fex-tool.sh` in the
   guest ([fex-eac/README.md](fex-eac/README.md)).
2. Set VRChat's Steam launch options (`EAC_LAUNCHERDIR`, `PROTON_EAC_RUNTIME`, `WINE_CPU_TOPOLOGY`, ...), exactly as given
   in [fex-eac/README.md](fex-eac/README.md) and [SETUP.md](SETUP.md).

- **Expected:** EAC's launcher reports `Launcher finished with: 301, 'Easy Anti-Cheat successfully loaded in-game'` and
  the game logs `AntiCheat Session Begin: Success`.
- **Not expected to work:** anti-cheat that refuses virtual machines, and titles whose anti-cheat uses its own
  anti-debug checks beyond EAC's Linux module.
- **After a Steam update:** if Steam updates its FEX tool, it replaces the patched build. Run
  `sh install-fex-tool.sh` again.

## Troubleshooting

| symptom | what to do |
|---|---|
| the game window stays black on DXMT | check that Settings shows *DXMT* and restart the launcher after changing the path; fall back to *Vulkan* |
| EAC fails on DXMT | switch to *Vulkan* and restart the launcher |
| EAC does not finish, or fails after a Steam update | the patched FEX is missing or was replaced by Valve's; run `sh install-fex-tool.sh status` |
| about a minute's stall before joining | check that `WINE_CPU_TOPOLOGY` is in the launch options |
| stutter with audio crackle | grant the microphone permission (System Settings > Privacy & Security > Microphone) |
| long first launch | shaders compile once per game and path; later launches are faster |

More: [docs/eac-troubleshooting.md](docs/eac-troubleshooting.md).

## Limits

- One machine verified (M2, 16 GB, macOS 27.0); one EAC title verified (VRChat).
- DXMT: Direct3D 11/10 only. Feature level is capped at 11_1 (no DXIL, no conservative rasterization).
- Direct3D 12 through D3DMetal is **planned**, not included.
- The DXMT setting applies to every game; on it the game's Metal layer covers the whole VM view (a windowed game or alt-tab
  shows the game layer).
- Games that need more memory than the VM gets (Settings > Advanced) will swap.
- Asynchronous pipeline compilation exists in the build but is off and not recommended (measured worse).
- The microphone has had little testing; a freeze after a microphone start is not fully ruled out. A rebuilt or re-signed
  app asks again for microphone permission.

## Documentation

| page | contents |
|---|---|
| [SETUP.md](SETUP.md) | the full setup guide: install, graphics path, Easy Anti-Cheat, troubleshooting |
| [docs/fork.md](docs/fork.md) | what changed in this fork and its status |
| [docs/eac-how-it-works.md](docs/eac-how-it-works.md) | the EAC chain and why the FEX swap is needed |
| [docs/eac-performance.md](docs/eac-performance.md) | measurements and limits |
| [fex-eac/README.md](fex-eac/README.md) | patched FEX setup and launch options |
| [docs/upstream/README.md](docs/upstream/README.md) | upstream steamac's documentation (Apache-2.0, © FX GAMES FZ LLC) |

## Licences and attributions

| component | licence |
|---|---|
| steamac (this fork) | Apache-2.0, © FX GAMES FZ LLC and contributors (`LICENSE`, `NOTICE`) |
| FEX-Emu patches (`fex-eac/patches/`) | MIT, as FEX-Emu |
| DXMT, with this fork's patches (`host/dxmt/patches/`) | LGPL-2.1 |
| wmtr (the DXMT remoting layer, `wmtr/`) | BSD-3-Clause |
| libkrun and its patches | Apache-2.0 |
| virglrenderer, Mesa / KosmicKrisp | MIT |
| MoltenVK | Apache-2.0 |
| DXVK (zlib), Proton / Wine (LGPL-2.1 and others) | per upstream; installed by Steam, not shipped |
| Linux kernel derivatives | GPL-2.0-only; complete source for each release is attached to it |

**D3DMetal is not bundled.** The app ships no game files and no EAC binaries. EAC comes from Valve's Proton EasyAntiCheat Runtime,
installed by Steam.
