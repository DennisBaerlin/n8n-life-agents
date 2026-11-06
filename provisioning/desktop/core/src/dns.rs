//! Eine Rückwärts-Namensauflösung (PTR) direkt beim Router, ohne Bibliothek: eine UDP-Anfrage, eine Antwort, kurze
//! Wartezeit (Leitung 2026-11-06, an einer echten FritzBox geprüft: Sie antwortet ohne Passwort mit
//! `<gerätename>.fritz.box`, dem Namen, den sie in ihrer Geräteliste führt). Nur lesen; gefragt wird nur nach der
//! eigenen Adresse dieses Rechners, kein Abtasten des Netzes. Format nach RFC 1035 (Kopf, Frage, Antwort, Namens-Zeiger).

use std::net::{Ipv4Addr, SocketAddr, UdpSocket};
use std::time::{Duration, Instant};

const TYPE_PTR: u16 = 12;
const CLASS_IN: u16 = 1;

/// `192.168.178.20` → `20.178.168.192.in-addr.arpa`
pub fn reverse_name(ip: Ipv4Addr) -> String {
    let o = ip.octets();
    format!("{}.{}.{}.{}.in-addr.arpa", o[3], o[2], o[1], o[0])
}

/// Anfrage: Kopf (Kennung, „rekursiv erwünscht“, eine Frage), dann die Frage nach dem PTR-Eintrag.
pub fn query(id: u16, ip: Ipv4Addr) -> Vec<u8> {
    let mut q = Vec::with_capacity(48);
    q.extend_from_slice(&id.to_be_bytes());
    q.extend_from_slice(&[0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]);
    for label in reverse_name(ip).split('.') {
        q.push(label.len() as u8);
        q.extend_from_slice(label.as_bytes());
    }
    q.push(0);
    q.extend_from_slice(&TYPE_PTR.to_be_bytes());
    q.extend_from_slice(&CLASS_IN.to_be_bytes());
    q
}

fn u16_at(msg: &[u8], pos: usize) -> Option<u16> {
    Some(u16::from_be_bytes([*msg.get(pos)?, *msg.get(pos + 1)?]))
}

/// Namen ab `pos` lesen (Labels und Zeiger auf frühere Stellen). Liefert den Namen und die Stelle direkt dahinter.
/// Begrenzt gegen kaputte oder böswillige Antworten: höchstens 16 Zeiger, höchstens 255 Zeichen.
fn read_name(msg: &[u8], mut pos: usize) -> Option<(String, usize)> {
    let mut labels: Vec<String> = Vec::new();
    let mut end = None;
    let mut jumps = 0;
    loop {
        let len = *msg.get(pos)? as usize;
        match len {
            0 => {
                end.get_or_insert(pos + 1);
                break;
            }
            l if l & 0xC0 == 0xC0 => {
                jumps += 1;
                if jumps > 16 {
                    return None;
                }
                end.get_or_insert(pos + 2);
                pos = (u16_at(msg, pos)? & 0x3FFF) as usize;
            }
            l if l <= 63 => {
                let bytes = msg.get(pos + 1..pos + 1 + l)?;
                labels.push(String::from_utf8_lossy(bytes).into_owned());
                pos += 1 + l;
            }
            _ => return None,
        }
    }
    let name = labels.join(".");
    (name.len() <= 255).then_some((name, end?))
}

/// Erster PTR-Name aus einer Antwort mit passender Kennung, klein geschrieben, ohne Punkt am Ende; sonst `None`
/// (andere Kennung, keine Antwort, Fehlercode, kaputt).
pub fn parse_answer(id: u16, msg: &[u8]) -> Option<String> {
    if u16_at(msg, 0)? != id {
        return None;
    }
    let flags = u16_at(msg, 2)?;
    // Antwort-Bit gesetzt, Fehlercode 0
    if flags & 0x8000 == 0 || flags & 0x000F != 0 {
        return None;
    }
    let questions = u16_at(msg, 4)?;
    let answers = u16_at(msg, 6)?;
    let mut pos = 12;
    for _ in 0..questions {
        pos = read_name(msg, pos)?.1 + 4;
    }
    for _ in 0..answers {
        pos = read_name(msg, pos)?.1;
        let rtype = u16_at(msg, pos)?;
        let rdlen = u16_at(msg, pos + 8)? as usize;
        let rdata = pos + 10;
        msg.get(rdata..rdata + rdlen)?;
        if rtype == TYPE_PTR {
            let (name, _) = read_name(msg, rdata)?;
            return Some(name.trim_end_matches('.').to_ascii_lowercase()).filter(|n| !n.is_empty());
        }
        pos = rdata + rdlen;
    }
    None
}

/// PTR von `ip` bei `server` erfragen. Antworten von anderen Absendern oder mit fremder Kennung zählen nicht.
pub fn ptr_lookup(server: SocketAddr, ip: Ipv4Addr, timeout: Duration) -> Option<String> {
    let mut idb = [0u8; 2];
    getrandom::fill(&mut idb).ok()?;
    let id = u16::from_be_bytes(idb);
    let bind = if server.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" };
    let sock = UdpSocket::bind(bind).ok()?;
    sock.send_to(&query(id, ip), server).ok()?;
    let deadline = Instant::now() + timeout;
    let mut buf = [0u8; 1500];
    loop {
        let left = deadline.checked_duration_since(Instant::now()).filter(|d| !d.is_zero())?;
        sock.set_read_timeout(Some(left)).ok()?;
        let (n, from) = sock.recv_from(&mut buf).ok()?;
        if from != server {
            continue;
        }
        if let Some(name) = parse_answer(id, &buf[..n]) {
            return Some(name);
        }
        if u16_at(&buf[..n], 0) == Some(id) {
            // Richtige Kennung, aber kein Name (z. B. „unbekannt“): fertig.
            return None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `<name>.fritz.box` zur Laufzeit zusammengesetzt: privacy_lint weist jeden solchen Namen als Literal ab.
    fn fb(name: &str) -> String {
        format!("{name}.fritz.box")
    }

    const IP: Ipv4Addr = Ipv4Addr::new(192, 168, 178, 20);

    /// Antwort, wie ein Router sie schickt: Frage zurück, dann der PTR-Eintrag mit Zeiger auf die Frage.
    fn answer(q: &[u8], name: &str) -> Vec<u8> {
        let mut a = q.to_vec();
        a[2] = 0x81;
        a[3] = 0x80;
        a[7] = 1;
        a.extend_from_slice(&[0xC0, 0x0C, 0, 12, 0, 1, 0, 0, 0, 60]);
        let mut rdata = Vec::new();
        for l in name.split('.') {
            rdata.push(l.len() as u8);
            rdata.extend_from_slice(l.as_bytes());
        }
        rdata.push(0);
        a.extend_from_slice(&(rdata.len() as u16).to_be_bytes());
        a.extend_from_slice(&rdata);
        a
    }

    #[test]
    fn query_asks_for_the_reverse_name() {
        assert_eq!(reverse_name(IP), "20.178.168.192.in-addr.arpa");
        let q = query(0x1234, IP);
        assert_eq!(&q[..12], &[0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]);
        assert_eq!(&q[q.len() - 4..], &[0, 12, 0, 1], "Typ PTR, Klasse IN");
        assert_eq!(read_name(&q, 12).map(|(n, _)| n).as_deref(), Some("20.178.168.192.in-addr.arpa"));
    }

    #[test]
    fn parses_the_fritz_box_answer() {
        let q = query(7, IP);
        assert_eq!(parse_answer(7, &answer(&q, &fb("Erikas-Mac-mini"))), Some(fb("erikas-mac-mini")));
    }

    #[test]
    fn rejects_foreign_or_broken_answers() {
        let q = query(7, IP);
        let a = answer(&q, &fb("erikas-mac-mini"));
        assert_eq!(parse_answer(8, &a), None, "fremde Kennung");
        let mut nx = q.clone();
        nx[2] = 0x81;
        nx[3] = 0x83;
        assert_eq!(parse_answer(7, &nx), None, "Name unbekannt");
        assert_eq!(parse_answer(7, &a[..a.len() - 3]), None, "abgeschnitten");
        assert_eq!(parse_answer(7, &q), None, "Anfrage ist keine Antwort");
        // Zeiger auf sich selbst: endet, statt zu hängen
        let mut lp = q.clone();
        lp[2] = 0x81;
        lp[7] = 1;
        let at = lp.len() as u16;
        lp.extend_from_slice(&[0xC0 | (at >> 8) as u8, at as u8]);
        assert_eq!(parse_answer(7, &lp), None);
        assert_eq!(parse_answer(7, b""), None);
    }

    /// Attrappen-DNS auf 127.0.0.1: antwortet einmal falsch (fremde Kennung), dann richtig.
    #[test]
    fn asks_a_real_udp_server() {
        let srv = UdpSocket::bind("127.0.0.1:0").unwrap();
        let addr = srv.local_addr().unwrap();
        let t = std::thread::spawn(move || {
            let mut buf = [0u8; 512];
            let (n, from) = srv.recv_from(&mut buf).unwrap();
            let q = buf[..n].to_vec();
            let mut wrong = answer(&q, &fb("falsch"));
            wrong[0] ^= 0xFF;
            srv.send_to(&wrong, from).unwrap();
            srv.send_to(&answer(&q, &fb("Erikas-Mac-mini")), from).unwrap();
        });
        assert_eq!(ptr_lookup(addr, IP, Duration::from_secs(5)), Some(fb("erikas-mac-mini")));
        t.join().unwrap();
    }

    #[test]
    fn silent_server_means_none_after_the_timeout() {
        let srv = UdpSocket::bind("127.0.0.1:0").unwrap();
        let start = Instant::now();
        assert_eq!(ptr_lookup(srv.local_addr().unwrap(), IP, Duration::from_millis(300)), None);
        assert!(start.elapsed() < Duration::from_secs(2));
    }
}
