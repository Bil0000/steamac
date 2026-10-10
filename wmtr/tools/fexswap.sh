#!/bin/bash
# fexswap.sh A|B|status : put FEX 0001-0020 (A) or 0001-0026 (B) into Steam's FEX tool in the guest; verify md5.
set -u
SSH="ssh -F $HOME/vrc-mac/ssh/config -o ConnectTimeout=8 -o BatchMode=yes vrc-guest"
case "${1:-status}" in
  A) SRC='~/.local/share/Steam/steamapps/common/FEX-Emu.pre-0029.bak'; WANT=12b93a74698b29b3ff4c9a0ae81d288e;;
  B) SRC='~/vrc/fex-0026-stage'; WANT=88912357b61d8895412ee542aedf582a;;
  status) $SSH 'D=~/.local/share/Steam/steamapps/common/FEX-Emu; md5sum $D/usr/bin/FEX; head -1 $D/VERSIONS.txt'; exit;;
esac
$SSH "set -e; S=$SRC; D=~/.local/share/Steam/steamapps/common/FEX-Emu; test -f \$S/usr/bin/FEX; s=\$(md5sum < \$S/usr/bin/FEX | cut -c1-32); [ \"\$s\" = $WANT ] || { echo src-md5-mismatch \$s; exit 3; }; for f in \$S/usr/bin/*; do cp -p \"\$f\" \$D/usr/bin/.\$(basename \"\$f\").new && mv -f \$D/usr/bin/.\$(basename \"\$f\").new \$D/usr/bin/\$(basename \"\$f\"); done; [ -f \$S/VERSIONS.txt ] && cp -p \$S/VERSIONS.txt \$D/VERSIONS.txt; d=\$(md5sum < \$D/usr/bin/FEX | cut -c1-32); [ \"\$d\" = $WANT ] || { echo dst-md5-mismatch \$d; exit 4; }; echo fex=$1 md5=\$d \$(head -1 \$D/VERSIONS.txt)"
