#!/usr/bin/env python3
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import struct
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "guest/layer/usr/lib/steamac"
HOOK = SCRIPTS / "steam-fex-eac"
RUN = SCRIPTS / "eac-launch"
FILES = ("FEXCompatTool", "VERSIONS.txt", "ConfigTemplate.json")
BINS = ("FEX", "FEXBash", "FEXGetConfig", "FEXOfflineCompiler", "FEXServer", "FEXServerManager", "FEXpidof")


def appinfo_v29(apps):
    table = []

    def key(name):
        if name not in table:
            table.append(name)
        return struct.pack("<I", table.index(name))

    def kv(node):
        out = b""
        for name, value in node.items():
            out += (b"\x00" + key(name) + kv(value)) if isinstance(value, dict) else (b"\x01" + key(name) + value.encode() + b"\0")
        return out + b"\x08"

    body = b""
    for appid, (kind, installdir) in apps.items():
        entry = b"\0" * 60 + kv({"appinfo": {"common": {"type": kind}, "config": {"installdir": installdir}}})
        body += struct.pack("<II", appid, len(entry)) + entry
    body += struct.pack("<I", 0)
    return struct.pack("<IIq", 0x07564429, 1, 16 + len(body)) + body + struct.pack("<I", len(table)) + b"".join(
        name.encode() + b"\0" for name in table)


class GameSetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.steam = self.home / ".local/share/Steam"
        self.tool = self.steam / "steamapps/common/FEX-Emu"
        self.stage = self.home / "fex-eac-work/stage"
        self.cmdline = self.home / "cmdline"
        self.cmdline.write_text("steamac.fex_eac=1")
        self.env = dict(os.environ, HOME=str(self.home), STEAMAC_CMDLINE=str(self.cmdline),
                        STEAMAC_FEX_DIR=str(ROOT / "fex-eac"), XDG_STATE_HOME=str(self.home / "state"),
                        XDG_RUNTIME_DIR=str(self.home / "run"))
        self.bin = self.home / "bin"
        self.bin.mkdir()
        (self.bin / "pgrep").write_text("#!/bin/sh\nexit 1\n")
        (self.bin / "systemctl").write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$HOME/service-calls"\n')
        for file in self.bin.iterdir():
            file.chmod(0o755)
        self.env["PATH"] = str(self.bin) + os.pathsep + os.environ["PATH"]
        self.source = next(line.split("=", 1)[1] for line in (ROOT / "fex-eac/build-fex.sh").read_text().splitlines()
                           if line.startswith("FEX_EAC_SHA="))
        self.seed(self.tool, "FEX-valve")
        self.seed(self.stage, "FEX-patched")
        (self.stage / ".steamac-fex-source").write_text(self.source + "\n")

    def seed(self, root, value):
        (root / "usr/bin").mkdir(parents=True)
        for name in BINS:
            (root / "usr/bin" / name).write_text(value + " " + name)
        for name in FILES:
            (root / name).write_text("FEX describe\tFEX-2607-" + value + "\n" if name == "VERSIONS.txt" else value)

    def eac_game(self):
        self.library_game(self.steam, "990", "Protected990", "EasyAntiCheat")
        for name in ("Proton - Experimental", "Proton EasyAntiCheat Runtime"):
            (self.steam / "steamapps/common" / name).mkdir(parents=True, exist_ok=True)

    def hook(self, *args, expected=0):
        result = subprocess.run(["python3", str(HOOK), *args], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_no_eac_game_leaves_steam_runtime_alone(self):
        self.library_game(self.steam, "701", "Plain")
        before = (self.tool / "usr/bin/FEX").read_bytes()
        self.hook()
        self.hook("repair")
        self.assertEqual((self.tool / "usr/bin/FEX").read_bytes(), before)
        self.assertFalse((self.home / "service-calls").exists())
        self.assertFalse((self.home / "run/steamac/steam-install-tools").exists())
        self.assertEqual((self.home / "state/steamac/fex-eac/status").read_text().split("\n")[0], "off")
        self.library_game(self.steam, "702", "Protected", "EasyAntiCheat")
        self.hook("repair")
        self.assertEqual((self.home / "state/steamac/fex-eac/status").read_text().split("\n")[0], "need-restart")
        self.hook()
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-patched FEX")

    def test_disabled_does_not_change_steam_or_schedule_build(self):
        self.cmdline.write_text("steamac.fex_eac=0")
        before = (self.tool / "usr/bin/FEX").read_bytes()
        self.hook()
        self.assertEqual((self.tool / "usr/bin/FEX").read_bytes(), before)
        self.assertFalse((self.home / "service-calls").exists())

    def test_missing_or_unverified_stage_requests_background_build(self):
        self.eac_game()
        (self.stage / ".steamac-fex-source").unlink()
        output = self.hook()
        self.assertIn("--user start --no-block steamac-fex-build.service", (self.home / "service-calls").read_text())
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-valve FEX")
        self.assertIn("Preparing", output)

    def test_prebuilt_layer_stage_installs_without_the_build_service(self):
        self.eac_game()
        payload = self.home / "payload"
        payload.mkdir()
        for name in ("build-fex.sh", "install-fex-tool.sh"):
            shutil.copy(ROOT / "fex-eac" / name, payload / name)
        self.seed(payload / "stage", "FEX-prebuilt")
        (payload / "stage/.steamac-fex-source").write_text(self.source + "\n")
        shutil.rmtree(self.stage)
        self.env["STEAMAC_FEX_DIR"] = str(payload)
        self.hook()
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-prebuilt FEX")
        self.assertFalse((self.home / "service-calls").exists())

    def test_newer_steam_fex_tool_is_kept(self):
        self.eac_game()
        self.hook()
        for name in BINS:
            (self.tool / "usr/bin" / name).write_text("FEX-valve-new " + name)
        (self.tool / "VERSIONS.txt").write_text("FEX describe\tFEX-2611-3-gabcdef\n")
        self.hook()
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-valve-new FEX")
        self.assertEqual((self.home / "state/steamac/fex-eac/status").read_text().split("\n")[0], "need-update")
        self.assertIn("newer than FEX-2610", self.hook("status"))

    def test_staged_runtime_installs_and_repairs_steam_update(self):
        self.eac_game()
        self.hook()
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-patched FEX")
        before = (self.tool / "usr/bin/FEX").stat().st_mtime_ns
        self.hook()
        self.assertEqual((self.tool / "usr/bin/FEX").stat().st_mtime_ns, before)
        for name in BINS:
            (self.tool / "usr/bin" / name).write_text("FEX-valve-update " + name)
        (self.tool / "VERSIONS.txt").write_text("FEX describe\tFEX-2607-valve-update\n")
        self.hook()
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-patched FEX")

    def test_repair_reinstalls_while_steam_runs_without_editing_settings(self):
        self.eac_game()
        self.hook()
        (self.bin / "pgrep").write_text('#!/bin/sh\n[ "$2" = steam ]\n')
        for name in BINS:
            (self.tool / "usr/bin" / name).write_text("FEX-valve-update " + name)
        (self.tool / "VERSIONS.txt").write_text("FEX describe\tFEX-2607-valve-update\n")
        self.library_game(self.steam, "708", "Protected", "EasyAntiCheat")
        config, account = self.game_settings("708")
        before = (config.read_bytes(), account.read_bytes())
        self.hook("repair")
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-patched FEX")
        self.assertEqual((config.read_bytes(), account.read_bytes()), before)
        status = self.home / "state/steamac/fex-eac/status"
        self.assertEqual(status.read_text().split("\n")[0], "need-restart")
        for name in BINS:
            (self.tool / "usr/bin" / name).write_text("FEX-valve-update2 " + name)
        self.hook("repair")
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-patched FEX")
        self.assertEqual(status.read_text().split("\n")[0], "need-restart")
        (self.bin / "pgrep").write_text('#!/bin/sh\n[ "$2" = steam ] || [ "$2" = FEXServer ]\n')
        for name in BINS:
            (self.tool / "usr/bin" / name).write_text("FEX-valve-update " + name)
        self.hook("repair")
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-valve-update FEX")

    def test_repair_units_are_enabled(self):
        user = ROOT / "guest/layer/usr/lib/systemd/user"
        for target in ("gamescope-session.target", "plasma-session.target"):
            self.assertEqual(os.readlink(user / f"{target}.wants/steamac-fex-repair.path"), "../steamac-fex-repair.path")
        self.assertIn("PathChanged=%h/.local/share/Steam/steamapps/common/FEX-Emu/VERSIONS.txt",
                      (user / "steamac-fex-repair.path").read_text())
        self.assertIn("ExecStart=/usr/lib/steamac/steam-fex-eac repair", (user / "steamac-fex-repair.service").read_text())

    def test_disabled_restores_only_our_installed_runtime(self):
        self.eac_game()
        self.hook()
        self.cmdline.write_text("steamac.fex_eac=0")
        self.hook()
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-valve FEX")
        self.cmdline.write_text("steamac.fex_eac=1")
        self.hook()
        (self.tool / "usr/bin/FEX").write_text("foreign-runtime")
        self.cmdline.write_text("steamac.fex_eac=0")
        self.hook()
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "foreign-runtime")
        self.assertFalse((self.home / "state/steamac/fex-eac/installed.json").exists())

    def test_disabled_keeps_a_new_steam_runtime_without_repeated_errors(self):
        self.eac_game()
        self.hook()
        for name in BINS:
            (self.tool / "usr/bin" / name).write_text("FEX-valve-update " + name)
        self.cmdline.write_text("steamac.fex_eac=0")
        self.hook()
        self.hook()
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-valve-update FEX")
        self.assertFalse((self.home / "state/steamac/fex-eac/installed.json").exists())

    def test_restore_keeps_the_last_steam_update(self):
        self.eac_game()
        self.hook()
        for name in BINS:
            (self.tool / "usr/bin" / name).write_text("FEX-valve-update " + name)
        (self.tool / "VERSIONS.txt").write_text("FEX describe\tFEX-2607-valve-update\n")
        self.hook()
        self.cmdline.write_text("steamac.fex_eac=0")
        self.hook()
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-valve-update FEX")

    def test_rebuilt_stage_does_not_replace_the_original_backup(self):
        self.eac_game()
        self.hook()
        for name in BINS:
            (self.stage / "usr/bin" / name).write_text("FEX-rebuilt " + name)
        (self.stage / "VERSIONS.txt").write_text("FEX describe\teac-rebuilt\n")
        self.hook()
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-rebuilt FEX")
        self.cmdline.write_text("steamac.fex_eac=0")
        self.hook()
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-valve FEX")

    def test_status_detects_replaced_runtime(self):
        self.eac_game()
        self.hook()
        (self.tool / "usr/bin/FEX").write_text("replaced")
        output = self.hook("status")
        self.assertIn("changed", output)
        self.assertNotIn("Runtime installed", output)

    def test_status_file_starts_with_a_code_word(self):
        self.eac_game()
        status = self.home / "state/steamac/fex-eac/status"
        self.hook()
        self.assertEqual(status.read_text().split("\n")[0], "installed")
        self.assertIn("Runtime installed", self.hook("status"))
        self.assertNotIn("installed\n", self.hook("status"))
        shutil.rmtree(self.steam / "steamapps/common/Proton EasyAntiCheat Runtime")
        shutil.rmtree(self.steam / "steamapps/common/Proton - Experimental")
        self.hook()
        self.assertEqual(status.read_text().split("\n")[0], "need-tools Proton - Experimental;Proton EasyAntiCheat Runtime")
        (self.bin / "pgrep").write_text('#!/bin/sh\n[ "$2" = steam ]\n')
        self.hook(expected=1)
        self.assertEqual(status.read_text().split("\n")[0], "failed")
        (self.bin / "pgrep").write_text("#!/bin/sh\nexit 1\n")
        self.cmdline.write_text("steamac.fex_eac=0")
        self.hook()
        self.assertEqual(status.read_text().split("\n")[0], "off")
        self.cmdline.write_text("steamac.fex_eac=1")
        (self.stage / ".steamac-fex-source").unlink()
        self.hook()
        self.assertEqual(status.read_text().split("\n")[0], "preparing")

    def test_running_steam_prevents_runtime_and_config_changes(self):
        (self.bin / "pgrep").write_text('#!/bin/sh\n[ "$2" = steam ]\n')
        self.hook(expected=1)
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-valve FEX")

    def test_eac_game_options_are_scoped_and_user_options_survive(self):
        self.library_game(self.steam, "438100", "Game", "EasyAntiCheat")
        (self.steam / "steamapps/common/Proton - Experimental").mkdir()
        (self.steam / "steamapps/common/Proton EasyAntiCheat Runtime").mkdir()
        config = self.steam / "config/config.vdf"
        config.parent.mkdir()
        config.write_text('"InstallConfigStore" { "Software" { "Valve" { "Steam" { "Other" "keep" } } } }\n')
        account = self.steam / "userdata/123/config/localconfig.vdf"
        account.parent.mkdir(parents=True)
        original = '"UserLocalConfigStore" { "Other" { "438100" { "LaunchOptions" "keep" } } "Software" { "Valve" { "Steam" { "apps" { "438100" { "name" "Game" } "9" { "LaunchOptions" "other" } } } } } }\n'
        account.write_text(original)
        self.hook()
        changed = account.read_text()
        self.assertIn('/usr/lib/steamac/eac-launch', changed)
        self.assertIn('"LaunchOptions" "keep"', changed)
        self.assertIn('"LaunchOptions" "other"', changed)
        self.assertIn('proton_experimental', config.read_text())
        self.assertEqual(Path(str(account) + ".steamac-fex-backup").read_text(), original)
        account.write_text(changed.replace('"/usr/lib/steamac/eac-launch %command%"', '"user-options"'))
        self.hook()
        self.assertIn('"/usr/lib/steamac/eac-launch %command% user-options"', account.read_text())
        self.assertIn('"LaunchOptions" "other"', account.read_text())

    def library_game(self, library, appid, installdir, eac=None, exe="Game.exe"):
        root = library / "steamapps/common" / installdir
        root.mkdir(parents=True)
        (library / "steamapps" / f"appmanifest_{appid}.acf").write_text(
            f'"AppState" {{ "appid" "{appid}" "installdir" "{installdir}" }}')
        if eac:
            (root / eac).mkdir(parents=True)
        if exe:
            (root / exe).parent.mkdir(parents=True, exist_ok=True)
            (root / exe).write_bytes(b"MZ\x90\x00")
        return root

    def test_eac_games_in_every_library_get_proton_and_wrapper(self):
        other = self.home / "games"
        (self.home / "games-link").symlink_to(other)
        (self.steam / "steamapps/libraryfolders.vdf").write_text(
            f'"libraryfolders" {{ "0" {{ "path" "{self.steam}" }} "1" {{ "path" "{other}" }} "2" {{ "path" "{self.home}/games-link/" }} }}')
        self.library_game(self.steam, "438100", "Plain")
        for library in (self.steam, other):
            self.library_game(library, "1826330", "Proton EasyAntiCheat Runtime", "v2/lib64", exe=None)
            (library / "steamapps/common/Proton EasyAntiCheat Runtime/v2/lib64/easyanticheat_x64.so").write_text("so")
        (self.steam / "steamapps/common/Proton EasyAntiCheat Runtime/toolmanifest.vdf").write_text('"manifest" { }')
        self.library_game(other, "500", "Some Tool", "EasyAntiCheat")
        (other / "steamapps/common/Some Tool/toolmanifest.vdf").write_text('"manifest" { }')
        (other / "steamapps/appmanifest_400.acf").write_text('"AppState" { "installdir" "Broken" ')
        self.library_game(other, "2083960", "Bodycam", "EasyAntiCheat")
        self.library_game(other, "100", "Deep", "a/b/start_protected_game.exe", exe="a/Deep.exe")
        self.library_game(other, "200", "Kept", "EasyAntiCheat")
        self.library_game(other, "300", "Plain", "a/b/c/EasyAntiCheat")
        config = self.steam / "config/config.vdf"
        config.parent.mkdir()
        config.write_text('"InstallConfigStore" { "Software" { "Valve" { "Steam" { "CompatToolMapping" { "200" { "name" "proton_9" } } } } } }\n')
        account = self.steam / "userdata/123/config/localconfig.vdf"
        account.parent.mkdir(parents=True)
        bodycam = "EAC_LAUNCHERDIR=x PROTON_EAC_RUNTIME=y PROTON_USE_XALIA=0 WINE_CPU_TOPOLOGY=16:0,1 %command% -nothreadtimeout %command%"
        stale = "/usr/lib/steamac/eac-launch 438100 %command% -fps"
        options = '"UserLocalConfigStore" { "Software" { "Valve" { "Steam" { "apps" { "438100" { "LaunchOptions" "%s" } "2083960" { "LaunchOptions" "%s" } "100" { "LaunchOptions" "%s" } "200" { "LaunchOptions" "-novid" } "300" { "LaunchOptions" "" } } } } } }\n'
        account.write_text(options % (stale, bodycam, ""))
        output = self.hook()
        self.assertEqual(account.read_text(), (options % ("%command% -fps", bodycam.replace("%command%", "/usr/lib/steamac/eac-launch %command%", 1),
                                                          "/usr/lib/steamac/eac-launch %command%")).replace(
            '"-novid"', '"/usr/lib/steamac/eac-launch %command% -novid"'))
        values = runpy.run_path(str(SCRIPTS / "mac-clock-format"))["vdf_entries"](config.read_text())[0]
        tools = {key[5]: value[0] for key, value in values.items() if key[-1] == "name"}
        self.assertEqual(tools, {"2083960": "proton_experimental", "100": "proton_experimental", "200": "proton_9"})
        self.assertIn("Install Proton - Experimental in Steam for EAC games.", output)
        self.assertEqual(output.count("appmanifest_400.acf: unbalanced VDF opening brace"), 1, output)
        self.assertNotIn("App 1826330", output)
        self.assertNotIn("App 500", output)
        self.assertIn("App 200: compatibility tool kept user tool proton_9; launch options wrapped.", output)
        snapshot = (config.read_bytes(), account.read_bytes())
        self.hook()
        self.assertEqual((config.read_bytes(), account.read_bytes()), snapshot)

    def game_settings(self, appid, options=""):
        config = self.steam / "config/config.vdf"
        config.parent.mkdir(exist_ok=True)
        config.write_text('"InstallConfigStore" { "Software" { "Valve" { "Steam" { } } } }\n')
        account = self.steam / "userdata/123/config/localconfig.vdf"
        account.parent.mkdir(parents=True, exist_ok=True)
        account.write_text('"UserLocalConfigStore" { "Software" { "Valve" { "Steam" { "apps" { "%s" { "LaunchOptions" "%s" } } } } } }\n'
                           % (appid, options))
        return config, account

    def test_native_linux_install_with_eac_library_is_left_alone(self):
        root = self.library_game(self.steam, "700", "Native", exe=None)
        (root / "EasyAntiCheat").mkdir()
        (root / "EasyAntiCheat/easyanticheat_x64.so").write_bytes(b"\x7fELF")
        (root / "game.x86_64").write_bytes(b"\x7fELF")
        config, account = self.game_settings("700")
        before = (config.read_bytes(), account.read_bytes())
        self.hook()
        self.assertEqual((config.read_bytes(), account.read_bytes()), before)

    def test_windows_game_without_eac_gets_no_wrapper_or_tool(self):
        self.library_game(self.steam, "701", "Plain")
        config, account = self.game_settings("701")
        before = (config.read_bytes(), account.read_bytes())
        self.hook()
        self.assertEqual((config.read_bytes(), account.read_bytes()), before)
        self.assertNotIn('"0"', config.read_text())

    def test_windows_eac_game_gets_proton_and_wrapper(self):
        self.library_game(self.steam, "702", "Protected", exe="start_protected_game.exe")
        config, account = self.game_settings("702")
        self.hook()
        self.assertIn('"/usr/lib/steamac/eac-launch %command%"', account.read_text())
        self.assertIn('"proton_experimental"', config.read_text())

    def test_options_without_command_are_wrapped(self):
        self.library_game(self.steam, "703", "Protected", "EasyAntiCheat")
        _, account = self.game_settings("703", "-novid -high")
        self.hook()
        self.assertIn('"/usr/lib/steamac/eac-launch %command% -novid -high"', account.read_text())

    def test_stale_wrapper_is_removed_and_other_options_kept(self):
        self.library_game(self.steam, "704", "Plain")
        _, account = self.game_settings("704", "FOO=1 /usr/lib/steamac/eac-launch %command% -novid")
        self.hook()
        self.assertIn('"FOO=1 %command% -novid"', account.read_text())

    def test_no_appid_is_special_cased(self):
        self.library_game(self.steam, "438100", "A", exe=None)
        self.library_game(self.steam, "1826330", "B", "EasyAntiCheat")
        config, account = self.game_settings("438100")
        self.hook()
        self.assertNotIn("438100", config.read_text())
        self.assertIn('"1826330"', config.read_text())
        self.assertIn('"438100" { "LaunchOptions" "" }', account.read_text())
        for script in (HOOK, RUN):
            self.assertIsNone(re.search(r"\b(438100|1826330)\b", script.read_text()), script)

    def test_disable_removes_only_our_tool_and_helper(self):
        self.library_game(self.steam, "706", "Protected", "EasyAntiCheat")
        self.library_game(self.steam, "707", "Chosen", "EasyAntiCheat")
        config, account = self.game_settings("706", "%command% -novid")
        config.write_text('"InstallConfigStore" { "Software" { "Valve" { "Steam" { "CompatToolMapping" { "707" { "name" "proton_9" } } } } } }\n')
        self.hook()
        self.assertIn('"/usr/lib/steamac/eac-launch %command% -novid"', account.read_text())
        self.assertIn('"706"', config.read_text())
        self.cmdline.write_text("steamac.fex_eac=0")
        self.hook()
        values = runpy.run_path(str(SCRIPTS / "mac-clock-format"))["vdf_entries"](config.read_text())[0]
        tools = {key[5]: value[0] for key, value in values.items() if key[-1] == "name"}
        self.assertEqual(tools, {"707": "proton_9"})
        self.assertIn('"706" { "LaunchOptions" "%command% -novid" }', account.read_text())
        self.assertNotIn("eac-launch", account.read_text())
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-valve FEX")

    def test_missing_tools_are_requested_from_steam(self):
        self.library_game(self.steam, "709", "Protected", "EasyAntiCheat")
        self.game_settings("709")
        (self.steam / "appcache").mkdir()
        (self.steam / "appcache/appinfo.vdf").write_bytes(appinfo_v29(
            {11: ("Tool", "Proton - Experimental"), 12: ("Tool", "Proton EasyAntiCheat Runtime"), 13: ("Game", "Protected"),
             14: ("Tool", "FEX-Emu")}))
        self.hook()
        self.assertEqual((self.home / "run/steamac/steam-install-tools").read_text(),
                         "steam://install/11\nsteam://install/12\n")
        self.assertEqual((self.home / "state/steamac/fex-eac/status").read_text().split("\n")[0],
                         "need-tools Proton - Experimental;Proton EasyAntiCheat Runtime")
        steam = self.bin / "steam"
        steam.write_text('#!/bin/sh\necho "$@" >> "$HOME/steam-calls"\n')
        steam.chmod(0o755)
        (self.home / "ready").write_text("boot\n")
        env = dict(self.env, STEAMAC_READY_MARKER=str(self.home / "ready"), STEAMAC_BOOT_ID="boot", STEAMAC_STEAM=str(steam))
        subprocess.run(["bash", str(SCRIPTS / "steam-install-tools")], env=env, check=True)
        for _ in range(50):
            if not (self.home / "run/steamac/steam-install-tools").exists():
                break
            time.sleep(0.1)
        self.assertEqual((self.home / "steam-calls").read_text(), "steam://install/11\nsteam://install/12\n")
        self.assertIn("ExecStartPost=-/usr/lib/steamac/steam-install-tools",
                      (ROOT / "guest/layer/usr/lib/systemd/user/steam.service.d/50-steamac.conf").read_text())
        shutil.rmtree(self.tool)
        self.hook()
        self.assertEqual((self.home / "run/steamac/steam-install-tools").read_text(),
                         "steam://install/11\nsteam://install/12\nsteam://install/14\n")

    def test_appinfo_is_not_read_when_no_tool_is_missing(self):
        (self.steam / "appcache").mkdir()
        (self.steam / "appcache/appinfo.vdf").write_bytes(struct.pack("<II", 0x07564428, 1) + b"\x01")
        self.assertNotIn("appinfo.vdf", self.hook())

    def test_scan_is_cached_per_manifest(self):
        root = self.library_game(self.steam, "705", "Protected", "EasyAntiCheat")
        config, _ = self.game_settings("705")
        self.hook()
        self.assertIn('"705"', config.read_text())
        (root / "Game.exe").unlink()
        self.hook()
        manifest = (self.steam / "steamapps/appmanifest_705.acf").resolve()
        cache = json.loads((self.home / "state/steamac/fex-eac/scan.json").read_text())
        self.assertTrue(cache[str(manifest)][2])
        os.utime(manifest, ns=(manifest.stat().st_atime_ns, manifest.stat().st_mtime_ns + 10**9))
        self.hook()
        cache = json.loads((self.home / "state/steamac/fex-eac/scan.json").read_text())
        self.assertFalse(cache[str(manifest)][2])
        self.assertNotIn('"705"', config.read_text())
        self.assertFalse((self.home / "state/steamac/fex-eac/mapped.json").exists())

    def test_bad_account_config_does_not_stop_setup(self):
        self.library_game(self.steam, "438100", "Game", "EasyAntiCheat")
        (self.steam / "steamapps/libraryfolders.vdf").write_text('"libraryfolders" { "0" { ')
        config = self.steam / "config/config.vdf"
        config.parent.mkdir()
        config.write_text('"InstallConfigStore" { "Software" { ')
        bad = self.steam / "userdata/1/config/localconfig.vdf"
        good = self.steam / "userdata/2/config/localconfig.vdf"
        for account in (bad, good):
            account.parent.mkdir(parents=True)
        bad.write_text('"UserLocalConfigStore" { "a" "1" "a" "2" }')
        good.write_text('"UserLocalConfigStore" { }')
        output = self.hook()
        self.assertIn("duplicate VDF value", output)
        self.assertIn("libraryfolders.vdf: unbalanced VDF opening brace", output)
        self.assertIn("compatibility tool not changed", output)
        self.assertEqual(config.read_text(), '"InstallConfigStore" { "Software" { ')
        self.assertEqual(bad.read_text(), '"UserLocalConfigStore" { "a" "1" "a" "2" }')
        self.assertIn("/usr/lib/steamac/eac-launch %command%", good.read_text())
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-patched FEX")

    def test_first_setup_selects_proton_before_fex_is_downloaded(self):
        (self.tool / "VERSIONS.txt").unlink()
        (self.stage / ".steamac-fex-source").unlink()
        self.library_game(self.steam, "438100", "Game", "EasyAntiCheat")
        for name in ("Proton - Experimental", "Proton EasyAntiCheat Runtime"):
            (self.steam / "steamapps/common" / name).mkdir()
        config = self.steam / "config/config.vdf"
        config.parent.mkdir()
        config.write_text('"InstallConfigStore" { "Software" { "Valve" { "Steam" { } } } }')
        self.hook()
        self.assertIn("proton_experimental", config.read_text())

    def test_wrapper_preserves_command_arguments_and_exit_status(self):
        runtime = self.steam / "steamapps/common/Proton EasyAntiCheat Runtime"
        runtime.mkdir()
        command = ["python3", "-c", "import json,os,sys; print(json.dumps([sys.argv[1:],os.environ.get('EAC_LAUNCHERDIR'),os.environ.get('PROTON_EAC_RUNTIME'),os.environ.get('WINE_CPU_TOPOLOGY')])); sys.exit(7)", "two words", "$(false)"]
        env = dict(self.env, STEAM_COMPAT_DATA_PATH=str(self.steam / "steamapps/compatdata/438100"))
        env.pop("WINE_CPU_TOPOLOGY", None)
        result = subprocess.run(["bash", str(RUN), "438100", *command], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 7, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data[0], ["two words", "$(false)"])
        self.assertEqual(data[1], str(self.steam / "steamapps/compatdata/438100/pfx/drive_c/users/steamuser/AppData/Roaming/EasyAntiCheat"))
        self.assertEqual(data[2], str(runtime))
        self.assertIsNone(data[3])

    def test_wrapper_uses_steam_prefix_and_runs_without_runtime(self):
        prefix = self.home / "library/steamapps/compatdata/2083960"
        env = dict(self.env, STEAM_COMPAT_DATA_PATH=str(prefix), PROTON_USE_XALIA="1")
        env.pop("WINE_CPU_TOPOLOGY", None)
        command = ["python3", "-c", "import json,os,sys; print(json.dumps([os.environ.get(k) for k in ('EAC_LAUNCHERDIR','PROTON_USE_XALIA','PROTON_EAC_RUNTIME','WINE_CPU_TOPOLOGY')])); sys.exit(5)"]
        result = subprocess.run(["bash", str(RUN), *command], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 5, result.stderr)
        launcher = str(prefix / "pfx/drive_c/users/steamuser/AppData/Roaming/EasyAntiCheat")
        self.assertEqual(json.loads(result.stdout), [launcher, "1", None, None])
        self.assertIn("Proton EasyAntiCheat Runtime", result.stderr)
        default = self.steam / "steamapps/common/Proton EasyAntiCheat Runtime"
        default.mkdir(parents=True)
        result = subprocess.run(["bash", str(RUN), *command], env=env, text=True, capture_output=True)
        self.assertEqual(json.loads(result.stdout), [launcher, "1", str(default), None], result.stderr)
        runtime = self.home / "library/steamapps/common/Proton EasyAntiCheat Runtime"
        runtime.mkdir(parents=True)
        result = subprocess.run(["bash", str(RUN), *command], env=env, text=True, capture_output=True)
        self.assertEqual(json.loads(result.stdout), [launcher, "1", str(runtime), None], result.stderr)
        result = subprocess.run(["bash", str(RUN), *command], env=dict(env, PROTON_EAC_RUNTIME="user"), text=True, capture_output=True)
        self.assertEqual(json.loads(result.stdout), [launcher, "1", "user", None], result.stderr)

    def test_wrapper_without_prefix_or_legacy_appid_leaves_launcherdir_unset(self):
        env = dict(self.env)
        env.pop("STEAM_COMPAT_DATA_PATH", None)
        env.pop("EAC_LAUNCHERDIR", None)
        result = subprocess.run(["bash", str(RUN), "python3", "-c", "import os; print(os.environ.get('EAC_LAUNCHERDIR', 'unset'))"],
                                env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "unset")

    def test_wrapper_disabled_leaves_environment_and_command_intact(self):
        self.cmdline.write_text("steamac.fex_eac=0")
        result = subprocess.run(["bash", str(RUN), "438100", "python3", "-c", "import os; print(os.environ.get('EAC_LAUNCHERDIR', 'unset'))"],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "unset")


if __name__ == "__main__":
    unittest.main()
