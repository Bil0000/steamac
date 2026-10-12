#!/bin/sh
# Guest-side tuning for EAC games. Idempotent; needs sudo.
set -eu

# MangoApp is a gamescope performance overlay layer: with it loaded, gamescope composites the game into
# a layer instead of scanning it out directly, which costs frames. Write the session conf gamescope reads.
CONF=/etc/steamac/gamescope-session.conf
sudo mkdir -p "$(dirname "$CONF")"
if sudo test -f "$CONF"; then
  # Keep every other setting; drop the old MangoApp line if one is already there.
  sudo sed -i '/^STEAMAC_GAMESCOPE_MANGOAPP=/d' "$CONF"
fi
echo 'STEAMAC_GAMESCOPE_MANGOAPP=0' | sudo tee -a "$CONF" >/dev/null
echo "wrote $CONF:"
sudo cat "$CONF"

cat <<'EOF'

VRChat needs no Steam launch options: the guest layer sets the EAC runtime variables and WINE_CPU_TOPOLOGY
(16 CPUs mapped onto the guest's own) itself. Remove launch options pasted from an earlier version of this guide.
EOF
