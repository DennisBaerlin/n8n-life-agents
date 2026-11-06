//! Heimnetz-Adresse dieses Rechners (Owner-Wunsch 2026-11-06): Der `master` füllt damit die Paperless-Adresse im
//! Fragebogen vor (`http://<ip>:<port>`, wie in der CLI über die IP, nicht Container zu Container). Dazu der Router
//! (Standard-Gateway), bei dem `suggest::fritz_box_name` nach dem Gerätenamen fragt. Nur lesen, kein Abtasten des
//! Netzes. Nur private IPv4-Adressen; sonst `None`, dann bleibt das Feld im Fragebogen leer.

use std::net::Ipv4Addr;

use crate::host::{args, Host, Os};

/// Private IPv4 (10/8, 172.16/12, 192.168/16), sonst nichts: keine öffentliche, keine Loopback-, keine Link-local-Adresse.
pub fn private_ipv4(text: &str) -> Option<String> {
    let ip: Ipv4Addr = text.trim().parse().ok()?;
    ip.is_private().then(|| ip.to_string())
}

/// Standard-Route: eigene Adresse und, falls ablesbar, der Router (ebenfalls privat).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Route {
    pub ip: String,
    pub gateway: Option<Ipv4Addr>,
}

/// Windows: Adapter mit Standard-Gateway, je eine Zeile `ip=…` und `gw=…`.
const WIN_ROUTE: &str = "$c = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1; 'ip=' + ($c.IPv4Address | Select-Object -First 1).IPAddress; 'gw=' + ($c.IPv4DefaultGateway | Select-Object -First 1).NextHop";

pub fn default_route(host: &dyn Host) -> Option<Route> {
    let gw = |s: &str| private_ipv4(s).and_then(|g| g.parse().ok());
    match host.os() {
        Os::Mac => {
            let route = host.run("/sbin/route", &args(&["-n", "get", "default"])).ok().filter(|o| o.success())?;
            let field = |name: &str| route.stdout.lines().find_map(|l| l.trim().strip_prefix(name)).map(str::trim).map(String::from);
            let iface = field("interface:")?;
            // Nur Namen wie en0, bridge100: schützt den nächsten Aufruf.
            if iface.is_empty() || !iface.chars().all(|c| c.is_ascii_alphanumeric()) {
                return None;
            }
            let addr = host.run("/usr/sbin/ipconfig", &args(&["getifaddr", &iface])).ok().filter(|o| o.success())?;
            Some(Route { ip: private_ipv4(&addr.stdout)?, gateway: field("gateway:").as_deref().and_then(gw) })
        }
        Os::Windows => {
            let out = host
                .run("powershell.exe", &args(&["-NoProfile", "-NonInteractive", "-Command", WIN_ROUTE]))
                .ok()
                .filter(|o| o.success())?;
            let field = |name: &str| out.stdout.lines().find_map(|l| l.trim().strip_prefix(name)).map(String::from);
            Some(Route { ip: private_ipv4(&field("ip=")?)?, gateway: field("gw=").as_deref().and_then(gw) })
        }
    }
}

/// Adresse der Schnittstelle mit der Standard-Route.
pub fn lan_ip(host: &dyn Host) -> Option<String> {
    default_route(host).map(|r| r.ip)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::{CmdOut, FakeHost};

    const ROUTE: &str = "   route to: default\ndestination: default\n       mask: default\n    gateway: 192.168.178.10\n  interface: en0\n      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>\n";

    #[test]
    fn mac_reads_the_default_interface_and_router() {
        let h = FakeHost::mac()
            .on("/sbin/route -n get default", CmdOut::ok(ROUTE))
            .on("/usr/sbin/ipconfig getifaddr en0", CmdOut::ok("192.168.178.20\n"));
        assert_eq!(lan_ip(&h).as_deref(), Some("192.168.178.20"));
        assert_eq!(default_route(&h).unwrap().gateway, Some(Ipv4Addr::new(192, 168, 178, 10)));
        let h = FakeHost::mac()
            .on("/sbin/route -n get default", CmdOut::ok("  interface: en0\n"))
            .on("/usr/sbin/ipconfig getifaddr en0", CmdOut::ok("192.168.178.20\n"));
        assert_eq!(default_route(&h).unwrap().gateway, None, "ohne Router-Zeile nur die Adresse");
    }

    #[test]
    fn mac_without_network_gives_nothing() {
        assert_eq!(
            lan_ip(&FakeHost::mac().on("/sbin/route -n get default", CmdOut::fail(1, "route: writing to routing socket: not in table"))),
            None
        );
        let h = FakeHost::mac().on("/sbin/route -n get default", CmdOut::ok("  interface: en0; rm\n"));
        assert_eq!(lan_ip(&h), None, "seltsamer Schnittstellen-Name wird nicht weitergereicht");
    }

    #[test]
    fn only_private_addresses_count() {
        assert_eq!(private_ipv4("192.168.1.50").as_deref(), Some("192.168.1.50"));
        assert_eq!(private_ipv4("203.0.113.5"), None, "öffentliche Adresse");
        assert_eq!(private_ipv4("127.0.0.1"), None);
        assert_eq!(private_ipv4("169.254.3.4"), None);
        assert_eq!(private_ipv4("kaputt"), None);
    }

    #[test]
    fn windows_takes_the_adapter_with_gateway() {
        let line = format!("powershell.exe -NoProfile -NonInteractive -Command {WIN_ROUTE}");
        let h = FakeHost::windows().on(&line, CmdOut::ok("ip=192.168.1.50\r\ngw=192.168.178.10\r\n"));
        assert_eq!(default_route(&h), Some(Route { ip: "192.168.1.50".into(), gateway: Some(Ipv4Addr::new(192, 168, 178, 10)) }));
        let h = FakeHost::windows().on(&line, CmdOut::ok("ip=\r\ngw=\r\n"));
        assert_eq!(default_route(&h), None, "kein Adapter mit Router");
    }
}
