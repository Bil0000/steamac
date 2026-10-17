//! `launch-vr <appid>` from the host (Settings > VR "Start in VR", or the headset's WiVRn app list relayed by
//! the launcher): asks the running Steam client to start the game in its VR launch mode,
//! `steam -ifrunning steam://launch/<appid>/vr` (a plain `steam://rungameid/<appid>` picks the game's default,
//! for VRChat the desktop mode). Fire and forget: Steam shows its own errors; the child is reaped on a thread.

use std::process::{Command, Stdio};

/// The Steam URL for `id` in VR mode.
pub fn url(id: u32) -> String {
    format!("steam://launch/{id}/vr")
}

/// Parses the request argument: a Steam app id (decimal, non-zero).
pub fn parse(arg: &str) -> Option<u32> {
    arg.parse::<u32>().ok().filter(|&id| id != 0)
}

pub fn launch(id: u32) {
    let url = url(id);
    match Command::new("steam")
        .args(["-ifrunning", &url])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(mut child) => {
            eprintln!("fx-progress: launch-vr {id}: steam -ifrunning {url}");
            std::thread::spawn(move || {
                let _ = child.wait();
            });
        }
        Err(e) => eprintln!("fx-progress: launch-vr {id}: cannot run steam: {e}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vr_url_and_ids() {
        assert_eq!(url(438100), "steam://launch/438100/vr");
        assert_eq!(parse("438100"), Some(438100));
        assert_eq!(parse("0"), None);
        assert_eq!(parse("-1"), None);
        assert_eq!(parse("438100 x"), None);
        assert_eq!(parse(""), None);
    }
}
