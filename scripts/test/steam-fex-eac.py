#!/usr/bin/env python3
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "guest/layer/usr/lib/steamac"
HOOK = SCRIPTS / "steam-fex-eac"
RUN = SCRIPTS / "eac-launch"
FILES = ("FEXCompatTool", "VERSIONS.txt", "ConfigTemplate.json")
BINS = ("FEX", "FEXBash", "FEXGetConfig", "FEXOfflineCompiler", "FEXServer", "FEXServerManager", "FEXpidof")


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
                        STEAMAC_FEX_DIR=str(ROOT / "fex-eac"), XDG_STATE_HOME=str(self.home / "state"))
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
            (root / name).write_text("FEX describe\t" + value + "\n" if name == "VERSIONS.txt" else value)

    def hook(self, *args, expected=0):
        result = subprocess.run(["python3", str(HOOK), *args], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_disabled_does_not_change_steam_or_schedule_build(self):
        self.cmdline.write_text("steamac.fex_eac=0")
        before = (self.tool / "usr/bin/FEX").read_bytes()
        self.hook()
        self.assertEqual((self.tool / "usr/bin/FEX").read_bytes(), before)
        self.assertFalse((self.home / "service-calls").exists())

    def test_missing_or_unverified_stage_requests_background_build(self):
        (self.stage / ".steamac-fex-source").unlink()
        output = self.hook()
        self.assertIn("--user start --no-block steamac-fex-build.service", (self.home / "service-calls").read_text())
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-valve FEX")
        self.assertIn("Preparing", output)

    def test_prebuilt_layer_stage_installs_without_the_build_service(self):
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

    def test_staged_runtime_installs_and_repairs_steam_update(self):
        self.hook()
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-patched FEX")
        before = (self.tool / "usr/bin/FEX").stat().st_mtime_ns
        self.hook()
        self.assertEqual((self.tool / "usr/bin/FEX").stat().st_mtime_ns, before)
        for name in BINS:
            (self.tool / "usr/bin" / name).write_text("FEX-valve-update " + name)
        (self.tool / "VERSIONS.txt").write_text("FEX describe\tFEX-valve-update\n")
        self.hook()
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-patched FEX")

    def test_disabled_restores_only_our_installed_runtime(self):
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
        self.hook()
        for name in BINS:
            (self.tool / "usr/bin" / name).write_text("FEX-valve-update " + name)
        self.cmdline.write_text("steamac.fex_eac=0")
        self.hook()
        self.hook()
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-valve-update FEX")
        self.assertFalse((self.home / "state/steamac/fex-eac/installed.json").exists())

    def test_restore_keeps_the_last_steam_update(self):
        self.hook()
        for name in BINS:
            (self.tool / "usr/bin" / name).write_text("FEX-valve-update " + name)
        (self.tool / "VERSIONS.txt").write_text("FEX describe\tFEX-valve-update\n")
        self.hook()
        self.cmdline.write_text("steamac.fex_eac=0")
        self.hook()
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-valve-update FEX")

    def test_rebuilt_stage_does_not_replace_the_original_backup(self):
        self.hook()
        for name in BINS:
            (self.stage / "usr/bin" / name).write_text("FEX-rebuilt " + name)
        (self.stage / "VERSIONS.txt").write_text("FEX describe\tFEX-rebuilt\n")
        self.hook()
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-rebuilt FEX")
        self.cmdline.write_text("steamac.fex_eac=0")
        self.hook()
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-valve FEX")

    def test_status_detects_replaced_runtime(self):
        self.hook()
        (self.tool / "usr/bin/FEX").write_text("replaced")
        output = self.hook("status")
        self.assertIn("changed", output)
        self.assertNotIn("Runtime installed", output)

    def test_running_steam_prevents_runtime_and_config_changes(self):
        (self.bin / "pgrep").write_text('#!/bin/sh\n[ "$2" = steam ]\n')
        self.hook(expected=1)
        self.assertEqual((self.tool / "usr/bin/FEX").read_text(), "FEX-valve FEX")

    def test_vrchat_options_are_scoped_and_user_options_survive(self):
        (self.steam / "steamapps/appmanifest_438100.acf").write_text('"AppState" { "appid" "438100" }')
        (self.steam / "steamapps/common/Proton - Experimental").mkdir()
        (self.steam / "steamapps/common/Proton EasyAntiCheat Runtime").mkdir()
        config = self.steam / "config/config.vdf"
        config.parent.mkdir()
        config.write_text('"InstallConfigStore" { "Software" { "Valve" { "Steam" { "Other" "keep" } } } }\n')
        account = self.steam / "userdata/123/config/localconfig.vdf"
        account.parent.mkdir(parents=True)
        original = '"UserLocalConfigStore" { "Other" { "438100" { "LaunchOptions" "keep" } } "Software" { "Valve" { "Steam" { "apps" { "438100" { "name" "VRChat" } "9" { "LaunchOptions" "other" } } } } } }\n'
        account.write_text(original)
        self.hook()
        changed = account.read_text()
        self.assertIn('/usr/lib/steamac/eac-launch', changed)
        self.assertIn('"LaunchOptions" "keep"', changed)
        self.assertIn('"LaunchOptions" "other"', changed)
        self.assertIn('proton_experimental', config.read_text())
        self.assertEqual(Path(str(account) + ".steamac-fex-backup").read_text(), original)
        account.write_text(changed.replace('"/usr/lib/steamac/eac-launch %command%"', '"user-options"'))
        user = account.read_bytes()
        self.hook()
        self.assertEqual(account.read_bytes(), user)

    def library_game(self, library, appid, installdir, eac=None):
        (library / "steamapps/common" / installdir).mkdir(parents=True)
        (library / "steamapps" / f"appmanifest_{appid}.acf").write_text(
            f'"AppState" {{ "appid" "{appid}" "installdir" "{installdir}" }}')
        if eac:
            (library / "steamapps/common" / installdir / eac).mkdir(parents=True)

    def test_eac_games_in_every_library_get_proton_and_wrapper(self):
        other = self.home / "games"
        (self.home / "games-link").symlink_to(other)
        (self.steam / "steamapps/libraryfolders.vdf").write_text(
            f'"libraryfolders" {{ "0" {{ "path" "{self.steam}" }} "1" {{ "path" "{other}" }} "2" {{ "path" "{self.home}/games-link/" }} }}')
        self.library_game(self.steam, "438100", "VRChat")
        for library in (self.steam, other):
            self.library_game(library, "1826330", "Proton EasyAntiCheat Runtime", "v2/lib64")
            (library / "steamapps/common/Proton EasyAntiCheat Runtime/v2/lib64/easyanticheat_x64.so").write_text("so")
        (self.steam / "steamapps/common/Proton EasyAntiCheat Runtime/toolmanifest.vdf").write_text('"manifest" { }')
        self.library_game(other, "500", "Some Tool", "EasyAntiCheat")
        (other / "steamapps/common/Some Tool/toolmanifest.vdf").write_text('"manifest" { }')
        (other / "steamapps/appmanifest_400.acf").write_text('"AppState" { "installdir" "Broken" ')
        self.library_game(other, "2083960", "Bodycam", "EasyAntiCheat")
        self.library_game(other, "100", "Deep", "a/b/start_protected_game.exe")
        self.library_game(other, "200", "Kept", "EasyAntiCheat")
        self.library_game(other, "300", "Plain", "a/b/c/EasyAntiCheat")
        config = self.steam / "config/config.vdf"
        config.parent.mkdir()
        config.write_text('"InstallConfigStore" { "Software" { "Valve" { "Steam" { "CompatToolMapping" { "200" { "name" "proton_9" } } } } } }\n')
        account = self.steam / "userdata/123/config/localconfig.vdf"
        account.parent.mkdir(parents=True)
        bodycam = "EAC_LAUNCHERDIR=x PROTON_EAC_RUNTIME=y PROTON_USE_XALIA=0 WINE_CPU_TOPOLOGY=16:0,1 %command% -nothreadtimeout %command%"
        vrchat = "/usr/lib/steamac/eac-launch 438100 %command%"
        options = '"UserLocalConfigStore" { "Software" { "Valve" { "Steam" { "apps" { "438100" { "LaunchOptions" "%s" } "2083960" { "LaunchOptions" "%s" } "100" { "LaunchOptions" "%s" } "200" { "LaunchOptions" "-novid" } "300" { "LaunchOptions" "" } } } } } }\n'
        account.write_text(options % (vrchat, bodycam, ""))
        output = self.hook()
        self.assertEqual(account.read_text(), options % (vrchat, bodycam.replace("%command%", "/usr/lib/steamac/eac-launch %command%", 1),
                                                         "/usr/lib/steamac/eac-launch %command%"))
        values = runpy.run_path(str(SCRIPTS / "mac-clock-format"))["vdf_entries"](config.read_text())[0]
        tools = {key[5]: value[0] for key, value in values.items() if key[-1] == "name"}
        self.assertEqual(tools, {"438100": "proton_experimental", "2083960": "proton_experimental",
                                 "100": "proton_experimental", "200": "proton_9"})
        self.assertIn("Install Proton - Experimental in Steam for EAC games.", output)
        self.assertEqual(output.count("appmanifest_400.acf: unbalanced VDF opening brace"), 1, output)
        self.assertNotIn("App 1826330", output)
        self.assertNotIn("App 500", output)
        self.assertIn("App 200: compatibility tool kept user tool proton_9; launch options unchanged without %command%.", output)
        snapshot = (config.read_bytes(), account.read_bytes())
        self.hook()
        self.assertEqual((config.read_bytes(), account.read_bytes()), snapshot)

    def test_bad_account_config_does_not_stop_setup(self):
        (self.steam / "steamapps/appmanifest_438100.acf").write_text('"AppState" { "appid" "438100" }')
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
        (self.steam / "steamapps/appmanifest_438100.acf").write_text('"AppState" { "appid" "438100" }')
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
        result = subprocess.run(["bash", str(RUN), "438100", *command], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 7, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data[0], ["two words", "$(false)"])
        self.assertEqual(data[1], str(self.steam / "steamapps/compatdata/438100/pfx/drive_c/users/steamuser/AppData/Roaming/EasyAntiCheat"))
        self.assertEqual(data[2], str(runtime))
        self.assertTrue(data[3].startswith("16:"))

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
        env["STEAM_COMPAT_DATA_PATH"] = str(prefix.with_name("438100"))
        result = subprocess.run(["bash", str(RUN), *command], env=env, text=True, capture_output=True)
        self.assertTrue(json.loads(result.stdout)[3].startswith("16:"), result.stderr)

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
