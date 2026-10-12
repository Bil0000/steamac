# steamac game environment: installed as user_settings.py by /usr/lib/steamac/steam-game-env
# SPDX-License-Identifier: MIT
#
# Proton's own mechanism for environment defaults: the `proton` script imports user_settings.py from its
# directory and applies each entry only when the variable is not already in the environment, so anything
# set in a game's Steam launch options wins. A user_settings.py without the first line above is the
# user's own and is never replaced.
#
# What it sets (nothing else; in particular no WINEDEBUG, PROTON_LOG, PROTON_NO_FSYNC or FEX_* setting):
#   PROTON_EAC_RUNTIME   the installed "Proton EasyAntiCheat Runtime" (Steam tool 1826330), every game;
#                        Wine's loader reads it only when a game loads its Easy Anti-Cheat module
#   EAC_LAUNCHERDIR      the Easy Anti-Cheat directory inside the game's own prefix, with the above
#   WINE_CPU_TOPOLOGY    per game (table below): N logical CPUs mapped onto the CPUs the game may run on
#   PROTON_USE_XALIA     per game (table below)
import os

EAC_RUNTIME = "Proton EasyAntiCheat Runtime"

# Per-game defaults, keyed by Steam app id, in the manner of Proton's own default_cpu_limit table.
#   cpus    logical CPUs Windows code sees (Proton's stock WINE_CPU_TOPOLOGY). A game whose thread pool
#           is sized from the CPU count can starve on a guest with few vCPUs. Measured on VRChat only:
#           with 4 vCPUs its region lookup stalled for about a minute, with 16 reported it took 4-6 s.
#   xalia   "0" skips Proton's Xalia helper for a game that has no launcher window to navigate.
APP_DEFAULTS = {
    "438100": {"cpus": 16, "xalia": "0"},  # VRChat
}


def _cpu_ids():
    ids = os.environ.get("STEAMAC_CPU_IDS")  # test override
    if ids:
        return [int(i) for i in ids.split(",")]
    try:
        return sorted(os.sched_getaffinity(0))
    except (AttributeError, OSError):
        return list(range(os.cpu_count() or 1))


def _cpu_topology(count):
    ids = _cpu_ids()
    if not ids or len(ids) >= count:
        return None  # the guest already has that many CPUs
    return "%d:%s" % (count, ",".join(str(ids[i % len(ids)]) for i in range(count)))


def _eac_runtime():
    here = os.path.dirname(os.path.abspath(__file__))
    dirs = [os.path.dirname(here)]  # next to this Proton
    for var in ("STEAM_COMPAT_LIBRARY_PATHS", "STEAM_COMPAT_INSTALL_PATH", "STEAM_COMPAT_CLIENT_INSTALL_PATH"):
        for p in os.environ.get(var, "").split(":"):
            if not p:
                continue
            p = p.rstrip("/")
            # a library root, its steamapps directory, or a game inside steamapps/common
            dirs += [os.path.join(p, "steamapps", "common"), os.path.join(p, "common"), os.path.dirname(p)]
    dirs.append(os.path.expanduser("~/.local/share/Steam/steamapps/common"))
    for d in dirs:
        runtime = os.path.join(d, EAC_RUNTIME)
        # Wine appends v2/lib64 itself: the variable names the tool's root
        if os.path.isdir(os.path.join(runtime, "v2")):
            return runtime
    return None


def _settings():
    env = {}
    runtime = os.environ.get("PROTON_EAC_RUNTIME") or _eac_runtime()
    if runtime:
        env["PROTON_EAC_RUNTIME"] = runtime
        compatdata = os.environ.get("STEAM_COMPAT_DATA_PATH")
        if compatdata:
            env["EAC_LAUNCHERDIR"] = os.path.join(
                compatdata, "pfx", "drive_c", "users", "steamuser", "AppData", "Roaming", "EasyAntiCheat")
    app = APP_DEFAULTS.get(os.environ.get("SteamGameId") or os.environ.get("SteamAppId") or "")
    if app:
        topology = _cpu_topology(app["cpus"]) if "cpus" in app else None
        if topology:
            env["WINE_CPU_TOPOLOGY"] = topology
        if "xalia" in app:
            env["PROTON_USE_XALIA"] = app["xalia"]
    return env


try:
    user_settings = _settings()
except Exception:  # a default that cannot be computed must never stop a game from starting
    user_settings = {}
