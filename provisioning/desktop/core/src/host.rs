//! Die eine Naht zum Betriebssystem. Jede Prüfung und jede Änderung läuft über `Host`, nie direkt über
//! `std::process` oder `std::fs`. So ersetzt `FakeHost` in den Tests jeden Befehl durch eine Attrappe, und
//! die Tests laufen auf jedem Rechner, auch ohne Mac, Windows oder Docker.
//!
//! Pfade sind Zeichenketten mit dem Trenner des Ziel-Systems (`join`), damit ein Linux-Testlauf Mac- und
//! Windows-Pfade unverändert nachstellen kann.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Os {
    Mac,
    Windows,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Arch {
    Arm64,
    X64,
}

/// Ergebnis eines Befehls. `code` ist -1, wenn der Prozess ohne Exit-Code endete (Signal).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CmdOut {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

impl CmdOut {
    pub fn ok(stdout: &str) -> Self {
        CmdOut { code: 0, stdout: stdout.to_string(), stderr: String::new() }
    }
    pub fn fail(code: i32, stderr: &str) -> Self {
        CmdOut { code, stdout: String::new(), stderr: stderr.to_string() }
    }
    pub fn success(&self) -> bool {
        self.code == 0
    }
}

pub trait Host {
    fn os(&self) -> Os;
    fn arch(&self) -> Arch;
    /// Heimatordner des angemeldeten Nutzers.
    fn home(&self) -> String;
    fn env(&self, key: &str) -> Option<String>;
    /// Datei, Ordner, Socket oder Named Pipe vorhanden.
    fn exists(&self, path: &str) -> bool;
    /// Programm ausführen und auf das Ende warten. `Err` = Programm fehlt oder ließ sich nicht starten.
    fn run(&self, program: &str, args: &[String]) -> Result<CmdOut, String>;
    /// Programm starten, ohne zu warten (Docker Desktop öffnen).
    fn spawn(&self, program: &str, args: &[String]) -> Result<(), String>;
    fn read_file(&self, path: &str) -> Option<String>;
    /// Schreibt atomar (temporäre Datei + Umbenennen) und legt fehlende Ordner an.
    fn write_file(&self, path: &str, content: &str) -> Result<(), String>;
    fn remove_file(&self, path: &str) -> Result<(), String>;
    /// Größe einer Datei in Bytes (Fortschritt beim Laden).
    fn file_size(&self, path: &str) -> Option<u64>;
    /// Ein TCP-Port auf 127.0.0.1 ist frei.
    fn port_free(&self, port: u16) -> bool;
    /// Sekunden seit 1970, für Journal-Einträge.
    fn now(&self) -> u64;
}

pub fn sep(os: Os) -> char {
    match os {
        Os::Mac => '/',
        Os::Windows => '\\',
    }
}

/// Pfad-Teile mit dem Trenner des Ziel-Systems verbinden.
pub fn join(os: Os, parts: &[&str]) -> String {
    let s = sep(os);
    let mut out = String::new();
    for (i, p) in parts.iter().enumerate() {
        if i == 0 {
            out.push_str(p.trim_end_matches(['/', '\\']));
        } else {
            out.push(s);
            out.push_str(p.trim_matches(['/', '\\']));
        }
    }
    out
}

pub fn args(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| s.to_string()).collect()
}

// ---------------------------------------------------------------------------------------------------------
// Echtes System
// ---------------------------------------------------------------------------------------------------------

pub struct RealHost;

impl Host for RealHost {
    fn os(&self) -> Os {
        if cfg!(target_os = "windows") {
            Os::Windows
        } else {
            Os::Mac
        }
    }
    fn arch(&self) -> Arch {
        if cfg!(target_arch = "aarch64") {
            Arch::Arm64
        } else {
            Arch::X64
        }
    }
    fn home(&self) -> String {
        let key = if cfg!(target_os = "windows") { "USERPROFILE" } else { "HOME" };
        std::env::var(key).unwrap_or_default()
    }
    fn env(&self, key: &str) -> Option<String> {
        std::env::var(key).ok().filter(|v| !v.is_empty())
    }
    fn exists(&self, path: &str) -> bool {
        std::path::Path::new(path).exists()
    }
    fn run(&self, program: &str, args: &[String]) -> Result<CmdOut, String> {
        let mut cmd = std::process::Command::new(program);
        cmd.args(args);
        no_window(&mut cmd);
        let out = cmd.output().map_err(|e| format!("{program}: {e}"))?;
        Ok(CmdOut { code: out.status.code().unwrap_or(-1), stdout: decode(&out.stdout), stderr: decode(&out.stderr) })
    }
    fn spawn(&self, program: &str, args: &[String]) -> Result<(), String> {
        let mut cmd = std::process::Command::new(program);
        cmd.args(args).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
        no_window(&mut cmd);
        cmd.spawn().map(|_| ()).map_err(|e| format!("{program}: {e}"))
    }
    fn read_file(&self, path: &str) -> Option<String> {
        std::fs::read_to_string(path).ok()
    }
    fn write_file(&self, path: &str, content: &str) -> Result<(), String> {
        let p = std::path::Path::new(path);
        if let Some(dir) = p.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let tmp = format!("{path}.tmp");
        std::fs::write(&tmp, content).map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, p).map_err(|e| e.to_string())
    }
    fn remove_file(&self, path: &str) -> Result<(), String> {
        match std::fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.to_string()),
        }
    }
    fn file_size(&self, path: &str) -> Option<u64> {
        std::fs::metadata(path).ok().map(|m| m.len())
    }
    fn port_free(&self, port: u16) -> bool {
        std::net::TcpListener::bind(("127.0.0.1", port)).is_ok()
    }
    fn now(&self) -> u64 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
    }
}

/// Windows-Werkzeuge wie `wsl.exe -l` schreiben UTF-16; alles andere ist UTF-8.
pub fn decode(bytes: &[u8]) -> String {
    let looks_utf16 = bytes.len() >= 2
        && bytes.len().is_multiple_of(2)
        && bytes.iter().skip(1).step_by(2).filter(|b| **b == 0).count() * 2 > bytes.len() / 2;
    if looks_utf16 {
        let units: Vec<u16> = bytes.chunks(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
        return String::from_utf16_lossy(&units).trim_start_matches('\u{feff}').to_string();
    }
    String::from_utf8_lossy(bytes).to_string()
}

#[cfg(target_os = "windows")]
fn no_window(cmd: &mut std::process::Command) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    cmd.creation_flags(CREATE_NO_WINDOW);
}
#[cfg(not(target_os = "windows"))]
fn no_window(_cmd: &mut std::process::Command) {}

// ---------------------------------------------------------------------------------------------------------
// Attrappe für Tests
// ---------------------------------------------------------------------------------------------------------

/// Antwortet auf genau die Befehle, die ein Test vorgibt. Ein nicht vorgegebener Befehl gilt als
/// „Programm fehlt“, so fällt jeder unerwartete Aufruf im Test auf (`calls`).
pub struct FakeHost {
    pub os: Os,
    pub arch: Arch,
    pub home: String,
    pub envs: BTreeMap<String, String>,
    pub paths: RefCell<BTreeSet<String>>,
    pub files: RefCell<BTreeMap<String, String>>,
    /// Schlüssel: Programm und Argumente, mit Leerzeichen verbunden.
    pub cmds: RefCell<BTreeMap<String, Vec<CmdOut>>>,
    pub calls: RefCell<Vec<String>>,
    pub spawned: RefCell<Vec<String>>,
    pub busy_ports: BTreeSet<u16>,
    pub clock: u64,
}

impl FakeHost {
    pub fn mac() -> Self {
        Self::new(Os::Mac, Arch::Arm64, "/Users/erika")
    }
    pub fn windows() -> Self {
        // Erfunden und bewusst ohne „Users“-Ordner: privacy_lint weist jeden Windows-Benutzerpfad ab.
        Self::new(Os::Windows, Arch::X64, "D:\\Profiles\\erika")
    }
    pub fn new(os: Os, arch: Arch, home: &str) -> Self {
        FakeHost {
            os,
            arch,
            home: home.to_string(),
            envs: BTreeMap::new(),
            paths: RefCell::new(BTreeSet::new()),
            files: RefCell::new(BTreeMap::new()),
            cmds: RefCell::new(BTreeMap::new()),
            calls: RefCell::new(Vec::new()),
            spawned: RefCell::new(Vec::new()),
            busy_ports: BTreeSet::new(),
            clock: 1_800_000_000,
        }
    }
    pub fn with_path(self, p: &str) -> Self {
        self.paths.borrow_mut().insert(p.to_string());
        self
    }
    pub fn with_env(mut self, k: &str, v: &str) -> Self {
        self.envs.insert(k.to_string(), v.to_string());
        self
    }
    /// Gleiche Antwort bei jedem Aufruf.
    pub fn on(self, cmdline: &str, out: CmdOut) -> Self {
        self.cmds.borrow_mut().insert(cmdline.to_string(), vec![out]);
        self
    }
    /// Antworten der Reihe nach; die letzte gilt für alle weiteren Aufrufe.
    pub fn on_seq(self, cmdline: &str, outs: Vec<CmdOut>) -> Self {
        self.cmds.borrow_mut().insert(cmdline.to_string(), outs);
        self
    }
    pub fn set(&self, cmdline: &str, out: CmdOut) {
        self.cmds.borrow_mut().insert(cmdline.to_string(), vec![out]);
    }
    pub fn called(&self, cmdline: &str) -> bool {
        self.calls.borrow().iter().any(|c| c == cmdline)
    }
    pub fn calls_starting(&self, prefix: &str) -> Vec<String> {
        self.calls.borrow().iter().filter(|c| c.starts_with(prefix)).cloned().collect()
    }
}

impl Host for FakeHost {
    fn os(&self) -> Os {
        self.os
    }
    fn arch(&self) -> Arch {
        self.arch
    }
    fn home(&self) -> String {
        self.home.clone()
    }
    fn env(&self, key: &str) -> Option<String> {
        self.envs.get(key).cloned()
    }
    fn exists(&self, path: &str) -> bool {
        self.paths.borrow().contains(path) || self.files.borrow().contains_key(path)
    }
    fn run(&self, program: &str, args: &[String]) -> Result<CmdOut, String> {
        let line = if args.is_empty() { program.to_string() } else { format!("{program} {}", args.join(" ")) };
        self.calls.borrow_mut().push(line.clone());
        let mut cmds = self.cmds.borrow_mut();
        match cmds.get_mut(&line) {
            Some(list) if list.len() > 1 => Ok(list.remove(0)),
            Some(list) if list.len() == 1 => Ok(list[0].clone()),
            _ => Err(format!("{program}: nicht vorhanden")),
        }
    }
    fn spawn(&self, program: &str, args: &[String]) -> Result<(), String> {
        let line = if args.is_empty() { program.to_string() } else { format!("{program} {}", args.join(" ")) };
        self.spawned.borrow_mut().push(line);
        Ok(())
    }
    fn read_file(&self, path: &str) -> Option<String> {
        self.files.borrow().get(path).cloned()
    }
    fn write_file(&self, path: &str, content: &str) -> Result<(), String> {
        self.files.borrow_mut().insert(path.to_string(), content.to_string());
        Ok(())
    }
    fn remove_file(&self, path: &str) -> Result<(), String> {
        self.files.borrow_mut().remove(path);
        self.paths.borrow_mut().remove(path);
        Ok(())
    }
    fn file_size(&self, path: &str) -> Option<u64> {
        self.files.borrow().get(path).map(|c| c.len() as u64)
    }
    fn port_free(&self, port: u16) -> bool {
        !self.busy_ports.contains(&port)
    }
    fn now(&self) -> u64 {
        self.clock
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn join_uses_target_separator() {
        assert_eq!(join(Os::Mac, &["/Users/erika/", "Library", "x.json"]), "/Users/erika/Library/x.json");
        assert_eq!(join(Os::Windows, &["D:\\Profiles\\erika", "AppData"]), "D:\\Profiles\\erika\\AppData");
    }

    #[test]
    fn decode_reads_utf16_from_wsl() {
        let bytes: Vec<u8> = "Ubuntu\r\n".encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
        assert_eq!(decode(&bytes), "Ubuntu\r\n");
        assert_eq!(decode("Grüße".as_bytes()), "Grüße");
    }

    #[test]
    fn fake_unknown_command_counts_as_missing_program() {
        let h = FakeHost::mac();
        assert!(h.run("docker", &args(&["info"])).is_err());
        assert!(h.called("docker info"));
    }
}
