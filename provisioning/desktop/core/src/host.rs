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
    /// Wie `run`, aber `input` geht über stdin (private Werte nie ins argv, das jeder Prozess lesen kann).
    fn run_stdin(&self, program: &str, args: &[String], input: &str) -> Result<CmdOut, String>;
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
    /// Zufall aus dem Betriebssystem als Hex-Text (`bytes` Bytes), z. B. für das Datenbank-Passwort.
    fn random_hex(&self, bytes: usize) -> Result<String, String>;
    /// Namen der Einträge eines Ordners (ohne Pfad); fehlt der Ordner, leer.
    fn list_dir(&self, path: &str) -> Vec<String>;
    /// In den Papierkorb legen (Mac: Papierkorb des Finders, Windows: Papierkorb), nie endgültig löschen.
    fn trash(&self, path: &str) -> Result<(), String>;
    /// Zertifikat (DER) einer TLS-Gegenstelle, ohne es zu prüfen: nur um Namen daraus zu lesen (`suggest.rs`).
    /// Ein Verbindungsaufbau, kurze Wartezeit; keine Antwort oder kein TLS heißt `None`.
    fn peer_cert_der(&self, host: &str, port: u16, timeout: std::time::Duration) -> Option<Vec<u8>>;
    /// Rückwärts-Namensauflösung (PTR) von `ip` direkt bei `server` (dem Router), eine UDP-Anfrage (`dns.rs`).
    fn dns_ptr(&self, server: std::net::SocketAddr, ip: std::net::Ipv4Addr, timeout: std::time::Duration) -> Option<String>;
}

/// TLS nur zum Lesen des Zertifikats. Bewusst ohne Prüfung: Die FritzBox zeigt im Heimnetz ein selbst signiertes
/// Zertifikat; gelesen werden nur Namen daraus, gesendet wird nichts.
mod tls_peek {
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
    use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
    use rustls::{DigitallySignedStruct, SignatureScheme};

    #[derive(Debug)]
    struct ReadOnly(Arc<rustls::crypto::CryptoProvider>);

    impl ServerCertVerifier for ReadOnly {
        fn verify_server_cert(
            &self,
            _: &CertificateDer<'_>,
            _: &[CertificateDer<'_>],
            _: &ServerName<'_>,
            _: &[u8],
            _: UnixTime,
        ) -> Result<ServerCertVerified, rustls::Error> {
            Ok(ServerCertVerified::assertion())
        }
        fn verify_tls12_signature(
            &self,
            _: &[u8],
            _: &CertificateDer<'_>,
            _: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, rustls::Error> {
            Ok(HandshakeSignatureValid::assertion())
        }
        fn verify_tls13_signature(
            &self,
            _: &[u8],
            _: &CertificateDer<'_>,
            _: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, rustls::Error> {
            Ok(HandshakeSignatureValid::assertion())
        }
        fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
            self.0.signature_verification_algorithms.supported_schemes()
        }
    }

    pub fn peer_cert(host: &str, port: u16, timeout: Duration) -> Option<Vec<u8>> {
        use std::net::{TcpStream, ToSocketAddrs};
        let addr = (host, port).to_socket_addrs().ok()?.next()?;
        let mut tcp = TcpStream::connect_timeout(&addr, timeout).ok()?;
        tcp.set_read_timeout(Some(timeout)).ok()?;
        tcp.set_write_timeout(Some(timeout)).ok()?;
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let cfg = rustls::ClientConfig::builder_with_provider(provider.clone())
            .with_safe_default_protocol_versions()
            .ok()?
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(ReadOnly(provider)))
            .with_no_client_auth();
        let name = ServerName::try_from(host.to_string()).ok()?;
        let mut conn = rustls::ClientConnection::new(Arc::new(cfg), name).ok()?;
        let start = Instant::now();
        while conn.is_handshaking() {
            if start.elapsed() > timeout * 2 {
                return None;
            }
            conn.complete_io(&mut tcp).ok()?;
        }
        conn.peer_certificates()?.first().map(|c| c.as_ref().to_vec())
    }
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
    fn run_stdin(&self, program: &str, args: &[String], input: &str) -> Result<CmdOut, String> {
        use std::io::Write;
        use std::process::Stdio;
        let mut cmd = std::process::Command::new(program);
        cmd.args(args).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        no_window(&mut cmd);
        let mut child = cmd.spawn().map_err(|e| format!("{program}: {e}"))?;
        if let Some(mut stdin) = child.stdin.take() {
            stdin.write_all(input.as_bytes()).map_err(|e| e.to_string())?;
        }
        let out = child.wait_with_output().map_err(|e| e.to_string())?;
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
        // Nur für diesen Nutzer lesbar: Die Env-Datei trägt das Datenbank-Passwort. Windows: das Profil-Verzeichnis
        // (LOCALAPPDATA) ist ohnehin nur für den Nutzer freigegeben.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600)).map_err(|e| e.to_string())?;
        }
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
    fn random_hex(&self, bytes: usize) -> Result<String, String> {
        let mut buf = vec![0u8; bytes];
        getrandom::fill(&mut buf).map_err(|e| e.to_string())?;
        Ok(buf.iter().map(|b| format!("{b:02x}")).collect())
    }
    fn list_dir(&self, path: &str) -> Vec<String> {
        std::fs::read_dir(path)
            .map(|it| it.filter_map(|e| e.ok()).filter_map(|e| e.file_name().into_string().ok()).collect())
            .unwrap_or_default()
    }
    fn trash(&self, path: &str) -> Result<(), String> {
        // Mac: über NSFileManager statt Finder-Steuerung, sonst fragt macOS zusätzlich „… möchte Finder steuern“.
        #[cfg(target_os = "macos")]
        let result = {
            use trash::macos::{DeleteMethod, TrashContextExtMacos};
            let mut ctx = trash::TrashContext::default();
            ctx.set_delete_method(DeleteMethod::NsFileManager);
            ctx.delete(path)
        };
        #[cfg(not(target_os = "macos"))]
        let result = trash::delete(path);
        result.map_err(|e| e.to_string())
    }
    fn peer_cert_der(&self, host: &str, port: u16, timeout: std::time::Duration) -> Option<Vec<u8>> {
        tls_peek::peer_cert(host, port, timeout)
    }
    fn dns_ptr(&self, server: std::net::SocketAddr, ip: std::net::Ipv4Addr, timeout: std::time::Duration) -> Option<String> {
        crate::dns::ptr_lookup(server, ip, timeout)
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
    pub trashed: RefCell<Vec<String>>,
    /// (Befehlszeile, stdin) je `run_stdin`.
    pub stdin_log: RefCell<Vec<(String, String)>>,
    /// Zertifikat, das `peer_cert_der` liefert (None = keine Gegenstelle).
    pub peer_cert: RefCell<Option<Vec<u8>>>,
    /// Antwort auf `dns_ptr` (None = keine Antwort); `ptr_asked` hält „Server Adresse“ je Anfrage fest.
    pub ptr: RefCell<Option<String>>,
    pub ptr_asked: RefCell<Vec<String>>,
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
            trashed: RefCell::new(Vec::new()),
            stdin_log: RefCell::new(Vec::new()),
            peer_cert: RefCell::new(None),
            ptr: RefCell::new(None),
            ptr_asked: RefCell::new(Vec::new()),
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
    fn run_stdin(&self, program: &str, args: &[String], input: &str) -> Result<CmdOut, String> {
        let r = self.run(program, args);
        let line = self.calls.borrow().last().cloned().unwrap_or_default();
        self.stdin_log.borrow_mut().push((line, input.to_string()));
        r
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
    fn random_hex(&self, bytes: usize) -> Result<String, String> {
        Ok("ab".repeat(bytes))
    }
    /// Einträge = alle bekannten Pfade/Dateien direkt unter `path`.
    fn list_dir(&self, path: &str) -> Vec<String> {
        let prefix = format!("{}{}", path.trim_end_matches(['/', '\\']), sep(self.os));
        let mut out: Vec<String> = self
            .paths
            .borrow()
            .iter()
            .cloned()
            .chain(self.files.borrow().keys().cloned())
            .filter_map(|p| p.strip_prefix(&prefix).map(|rest| rest.split(['/', '\\']).next().unwrap_or("").to_string()))
            .filter(|n| !n.is_empty())
            .collect();
        out.sort();
        out.dedup();
        out
    }
    fn trash(&self, path: &str) -> Result<(), String> {
        self.trashed.borrow_mut().push(path.to_string());
        self.remove_file(path)
    }
    fn peer_cert_der(&self, _host: &str, _port: u16, _timeout: std::time::Duration) -> Option<Vec<u8>> {
        self.peer_cert.borrow().clone()
    }
    fn dns_ptr(&self, server: std::net::SocketAddr, ip: std::net::Ipv4Addr, _timeout: std::time::Duration) -> Option<String> {
        self.ptr_asked.borrow_mut().push(format!("{server} {ip}"));
        self.ptr.borrow().clone()
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

    /// Echter TLS-Server auf 127.0.0.1 mit einer Attrappe des FritzBox-Zertifikats (erfundene Kennung).
    #[test]
    fn reads_the_certificate_of_a_real_tls_server_without_verifying() {
        use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
        use std::sync::Arc;
        let ck = rcgen::generate_simple_self_signed(vec!["fritz.box".to_string(), "deine-domain.myfritz.net".to_string()]).unwrap();
        let cert = CertificateDer::from(ck.cert.der().to_vec());
        let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(ck.key_pair.serialize_der()));
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let cfg = Arc::new(
            rustls::ServerConfig::builder_with_provider(provider)
                .with_safe_default_protocol_versions()
                .unwrap()
                .with_no_client_auth()
                .with_single_cert(vec![cert], key)
                .unwrap(),
        );
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let mut c = rustls::ServerConnection::new(cfg).unwrap();
            while c.is_handshaking() {
                if c.complete_io(&mut s).is_err() {
                    break;
                }
            }
        });
        let der = RealHost.peer_cert_der("127.0.0.1", port, std::time::Duration::from_secs(5)).expect("Zertifikat gelesen");
        server.join().unwrap();
        assert_eq!(crate::suggest::myfritz_zone_from_der(&der).as_deref(), Some("deine-domain.myfritz.net"));
        // Niemand lauscht: schnell None, kein Fehler.
        let closed = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        assert!(RealHost.peer_cert_der("127.0.0.1", closed, std::time::Duration::from_millis(500)).is_none());
    }

    #[test]
    fn fake_unknown_command_counts_as_missing_program() {
        let h = FakeHost::mac();
        assert!(h.run("docker", &args(&["info"])).is_err());
        assert!(h.called("docker info"));
    }
}
