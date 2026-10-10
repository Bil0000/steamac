#!/bin/bash
# lean-setup.sh DXMT_PE_DIR WINEMETAL_SO: build ~/vrc/lean/proton-lean (hard-linked copy of Proton
# Experimental's files with DXMT's PE dlls + winemetal.dll/.so; replaced files are unlinked first so the
# Steam-owned originals are never modified), and the scratch prefixes pfx-dxvk / pfx-wmtr.
set -eu
DX=$1; SO=$2
L=$HOME/vrc/lean; mkdir -p "$L"
TOOL="$HOME/.local/share/Steam/steamapps/common/Proton - Experimental"
SRC="$TOOL/files"
if [ ! -d "$L/proton-lean/files" ]; then cp -al "$TOOL" "$L/proton-lean"; fi
W="$L/proton-lean/files/lib/wine"
for f in d3d11.dll dxgi.dll d3d10core.dll winemetal.dll; do rm -f "$W/x86_64-windows/$f"; cp "$DX/$f" "$W/x86_64-windows/$f"; done
# what `proton` installs into a prefix instead of wine's builtins (its DXVK set) becomes DXMT too
for f in d3d11.dll dxgi.dll d3d10core.dll; do rm -f "$W/dxvk/x86_64-windows/$f"; cp "$DX/$f" "$W/dxvk/x86_64-windows/$f"; done
rm -f "$W/x86_64-unix/winemetal.so"; cp "$SO" "$W/x86_64-unix/winemetal.so"
# prefixes (wineboot under FEX); dxvk prefix gets Proton's DXVK dlls the way proton installs them
for m in dxvk wmtr; do
  if [ ! -d "$L/pfx-$m/drive_c/windows/system32" ]; then "$L/lean-run.sh" $m wineboot -i >/dev/null 2>&1 || true; fi
done
for f in d3d11 dxgi d3d10core; do cp "$SRC/lib/wine/dxvk/x86_64-windows/$f.dll" "$L/pfx-dxvk/drive_c/windows/system32/$f.dll"; done
for f in d3d11.dll dxgi.dll d3d10core.dll winemetal.dll; do cp "$DX/$f" "$L/pfx-wmtr/drive_c/windows/system32/$f"; done
md5sum "$W/x86_64-windows/d3d11.dll" "$SRC/lib/wine/x86_64-windows/d3d11.dll" "$L/pfx-dxvk/drive_c/windows/system32/d3d11.dll" "$L/pfx-wmtr/drive_c/windows/system32/d3d11.dll"
