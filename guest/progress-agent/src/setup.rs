//! Game-runtime setup status for the launcher (experimental game support):
//! steam-fex-eac writes one line to $XDG_STATE_HOME/steamac/fex-eac/status
//! (default ~/.local/state), a code word then English text:
//! `preparing`, `installed`, `need-tools <tool;tool>`, `need-restart`,
//! `failed <text>`, `off`. Sent as `setup <line>` once at agent start and
//! whenever the line changes; no file is `setup off`. The file is checked by
//! its mtime on every pass of the main loop (one stat a second when idle).

use std::path::PathBuf;
use std::time::SystemTime;

use crate::port::Port;

pub struct Setup {
    path: PathBuf,
    /// mtime of the last read (None inside: no file); None = never read.
    mtime: Option<Option<SystemTime>>,
    last: Option<String>,
}

impl Setup {
    pub fn new() -> Setup {
        let state = std::env::var("XDG_STATE_HOME").map(PathBuf::from).unwrap_or_else(|_| {
            PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/home/steamos".into())).join(".local/state")
        });
        Setup { path: state.join("steamac/fex-eac/status"), mtime: None, last: None }
    }

    pub fn pump(&mut self, port: &mut Port) {
        let mtime = std::fs::metadata(&self.path).and_then(|m| m.modified()).ok();
        if self.mtime == Some(mtime) {
            return;
        }
        self.mtime = Some(mtime);
        let line = line(&String::from_utf8_lossy(&std::fs::read(&self.path).unwrap_or_default()));
        if self.last.as_deref() != Some(line.as_str()) {
            port.send(&line);
            self.last = Some(line);
        }
    }

    /// Steam restarts to finish the setup: its next status is sent even if unchanged.
    pub fn resend(&mut self) {
        self.last = None;
    }
}

/// `setup <first line of the status file>`; an empty or missing file is `setup off`.
fn line(status: &str) -> String {
    match status.lines().next().map(str::trim).unwrap_or("") {
        "" => "setup off".into(),
        first => format!("setup {first}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_line_with_its_text() {
        assert_eq!(line("need-tools Proton EasyAntiCheat Runtime;Proton BattlEye Runtime\nmore\n"),
                   "setup need-tools Proton EasyAntiCheat Runtime;Proton BattlEye Runtime");
        assert_eq!(line("  installed  \n"), "setup installed");
    }

    #[test]
    fn no_status_is_off() {
        assert_eq!(line(""), "setup off");
        assert_eq!(line("\n"), "setup off");
    }
}
