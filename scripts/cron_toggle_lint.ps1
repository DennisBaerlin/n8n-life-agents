#Requires -Version 5.1
# cron_toggle_lint.ps1 -- Phase 0 (WS-0b) Cron-Toggle-UX-Paritaet-Lint (hartes Gate, Vorbild scripts/command_lint.ps1).
# Erzwingt das vom Owner gelockte Cron-Modell (2026-06-28) STRUKTURELL, nicht per Disziplin. ZWEI legitime Muster,
# unterschieden durch den Default-Wert des cron_enable-Flags im Manifest (kein neues Schema):
#   * OPT-IN  (value=false): startet AUS; SETUP = aktivieren per Knopf (callback_data cron_on:<key>, am Publish-/
#     Onboarding-Angebot), LAUFZEIT = abschalten per Knopf (cron_off:<key>, an der Nudge-/Lern-Karte), RE-AKTIVIEREN
#     per /reminders (Roter Faden Paket B, Owner 2026-10-23) -> KEIN cron_on am Laufzeit-Nudge.
#   * ALWAYS-ON (value=true): startet AN. Registrierte Haushalts-Erinnerungen (cron_labels.list) sind an ihrer Karte
#     abschaltbar und per /reminders schaltbar (c); Plumbing, Pflicht (cron_labels.mandatory) und Person-Notschalter
#     (cron_labels.person, je Person rem:on|off) tragen KEINEN cron_on/cron_off-Knopf (nur Konsole bzw. rem:).
# Seit Paket B zusaetzlich (g) Person-Reminder, (h) Default-Zeitplan im Erinnerungs-Fenster, (i) jeder Telegram-
# sendende Cron ist registriert, (j) jede registrierte Erinnerung hat ihre Menue-Bezeichnung (Details an den Bloecken).
# Geprueft wird die TOGGLE-OBERFLAECHE (die gebauten Inline-Keyboard-Buttons), NICHT der Cron-Node. SoT der Keys +
# Default = die Manifest-`.config.cron_enable`-Bloecke (wie contract_lint F9); SoT der Buttons = die getrackten
# gebauten Workflow-JSONs (wie approval_lint/command_lint -- kein ephemeres dist/). Fail-closed:
#   (a) jeder OPT-IN-Key hat einen erreichbaren cron_off:<key> (der Abschaltknopf -- die Phase-0-Garantie);
#   (b) jeder OPT-IN-Key hat einen erreichbaren cron_on:<key> (die Setup-Aktivierung; alle Opt-in-Crons starten AUS);
#   (c) ALWAYS-ON: Haushalts-Erinnerung -> cron_off:<key> oder Fusszeile core.reminders.card_footer an der Karte;
#       sonst KEIN cron_on/cron_off-Knopf;
#   (d) kein Dangling: jede cron_on:/cron_off:-callback_data verweist auf einen deklarierten cron_enable-Key, und
#       keine cron-callback_data ist ein dynamischer/unparsbarer Ausdruck (entzoege sich dem statischen Gate);
#   (e) fn-Akzeptanz (LEGACY-Whitelist): solange core.fn_set_cron_enable noch eine harte NOT-IN-Whitelist trug,
#       musste sie GENAU die Opt-in-Keys akzeptieren. Seit WS-0c #2/#3 ist die Whitelist weg (Togglability =
#       Registry-Membership in core.cron_labels) -> der Whitelist-Zweig findet kein Literal mehr und (e) wird mit
#       Hinweis uebersprungen; die fn-Akzeptanz sichert jetzt (f) statisch + db_test (always-on/unbekannt -> ok:false).
#   (f) cron_labels<->cron_enable-Paritaet (WS-0c #2/#3): jeder Opt-in-Key steht in einer Manifest-cron_labels.list
#       (= die Registry-Membership, die die fn als Togglability liest) und hat seine vier Katalog-Texte,
#       KEIN Always-on-Key hat einen (sonst chat-schaltbar), keine tote cron_labels-Zeile ohne cron_enable-Key.
# Exit-Code = Anzahl Fehler (CI-/Pre-Push-tauglich). Kein LLM, kein Netz, kein Substrat.
param([switch]$Verbose)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }

# --- (1) Deklarierte cron_enable-Keys + Default-Wert aus den Manifest-Bloecken (SoT, wie contract_lint F9) -------
$declared = @{}   # key -> @{ pkg; default ('false'|'true') }; Keys global eindeutig (core.config UNIQUE(category,key))
foreach ($mf in (Get-ChildItem (Join-Path $RepoRoot 'packages\*\manifest.json'))) {
    $mjson = [System.IO.File]::ReadAllText($mf.FullName, $u8) | ConvertFrom-Json
    if (-not $mjson.config -or -not ($mjson.config.PSObject.Properties.Name -contains 'cron_enable')) { continue }
    foreach ($k in $mjson.config.cron_enable.PSObject.Properties) {
        if ($k.Name -eq '_comment') { continue }
        if ($declared.ContainsKey($k.Name)) { Fail "cron_enable-Key '$($k.Name)' doppelt deklariert ($($declared[$k.Name].pkg) + $($mjson.name))"; continue }
        $val = [string]$k.Value.value
        if ($val -ne 'true' -and $val -ne 'false') { Fail "cron_enable-Key '$($k.Name)' ($($mjson.name)) hat einen Nicht-Boolean-Default '$val' (erwartet 'true'|'false')"; continue }
        $declared[$k.Name] = @{ pkg = [string]$mjson.name; default = $val }
    }
}
if ($declared.Count -eq 0) { Fail 'kein cron_enable-Key in irgendeinem Manifest gefunden (Lese-/Schema-Drift?)' }
$chatKeys    = @($declared.Keys | Where-Object { $declared[$_].default -eq 'false' })   # Opt-in -> Chat-Toggle
$consoleKeys = @($declared.Keys | Where-Object { $declared[$_].default -eq 'true' })    # always-on -> Konsole
# Roter Faden Paket B: die Erinnerungs-Registry (cron_labels) kennt drei Ebenen — list = Haushalts-Erinnerung (der Owner
# schaltet sie in /reminders oder per Knopf an der Karte, egal ob Default an oder aus), person = je Person (rem:),
# mandatory = Pflicht-Erinnerung (nur Anzeige). Always-on OHNE Registry-Eintrag = Plumbing (nur Konsole, kein Knopf).
$regList = @{}; $regPerson = @{}; $regMand = @{}
foreach ($mf in (Get-ChildItem (Join-Path $RepoRoot 'packages\*\manifest.json'))) {
    $mj = [System.IO.File]::ReadAllText($mf.FullName, $u8) | ConvertFrom-Json
    if (-not $mj.cron_labels) { continue }
    foreach ($k in @($mj.cron_labels.list)) { if ($k) { $regList[[string]$k] = [string]$mj.name } }
    foreach ($k in @($mj.cron_labels.mandatory)) { if ($k) { $regMand[[string]$k] = [string]$mj.name } }
    if ($mj.cron_labels.person) { foreach ($p in $mj.cron_labels.person.PSObject.Properties) { if ($p.Name -ne '_comment') { $regPerson[$p.Name] = [string]$mj.name } } }
}

# --- (2) Toggle-Buttons aus den GEBAUTEN Workflow-JSONs (Inline-Keyboard-callback_data) -------------------------
# Getrackte-Dir-Scan wie approval_lint/command_lint (NIE rekursiver Glob -> .local/backups/** haette alte JSONs).
# Nur ECHTE Buttons (parameters.inlineKeyboard...callback_data) -- KEIN Roh-Text-Scan (Sticky-Notes nennen die
# callback_data dokumentarisch -> waeren falsche Treffer).
$wfDirs = @()
foreach ($p in (Get-ChildItem -Path (Join-Path $RepoRoot 'packages') -Directory -ErrorAction SilentlyContinue)) {
    $w = Join-Path $p.FullName 'workflows'; if (Test-Path $w) { $wfDirs += $w }
}
$onKeys  = @{}   # key -> Workflow (cron_on-Emitter)
$offKeys = @{}   # key -> Workflow (cron_off-Emitter)
$cronRx  = [regex]'^cron_(on|off):([a-z][a-z0-9_]*)$'
foreach ($file in (Get-ChildItem $wfDirs -Filter '*.json')) {
    $wf = [System.IO.File]::ReadAllText($file.FullName, $u8) | ConvertFrom-Json
    $wfName = [string]$wf.name
    foreach ($n in $wf.nodes) {
        $ik = $n.parameters.inlineKeyboard
        if (-not $ik -or -not $ik.rows) { continue }
        foreach ($r in @($ik.rows)) {
            foreach ($b in @($r.row.buttons)) {
                $cd = [string]$b.additionalFields.callback_data
                if ([string]::IsNullOrEmpty($cd)) { continue }
                if ($cd -notlike 'cron_on:*' -and $cd -notlike 'cron_off:*') { continue }
                $m = $cronRx.Match($cd)
                if (-not $m.Success) {
                    Fail "${wfName} / Node '$($n.name)': cron-callback_data '$cd' ist kein sauberes Literal cron_on:<key>/cron_off:<key> (dynamisch/unparsbar -> entzieht sich dem Gate)"
                    continue
                }
                $verb = $m.Groups[1].Value; $key = $m.Groups[2].Value
                if ($verb -eq 'on')  { $onKeys[$key]  = $wfName }
                else                 { $offKeys[$key] = $wfName }
            }
        }
    }
}

# --- (a) jeder OPT-IN-Key hat einen cron_off-Knopf (Abschaltknopf -- die Phase-0-Garantie) ----------------------
foreach ($key in ($chatKeys | Sort-Object)) {
    if (-not $offKeys.ContainsKey($key)) {
        Fail "Opt-in-Cron '$key' ($($declared[$key].pkg), Default AUS) hat KEINEN erreichbaren cron_off:$key-Knopf im gebauten Graph (Cron ohne Abschaltknopf -- genau das verhindert diese Phase)"
    }
}
# --- (b) jeder OPT-IN-Key hat einen cron_on-Knopf (Setup-Aktivierung) ------------------------------------------
foreach ($key in ($chatKeys | Sort-Object)) {
    if (-not $onKeys.ContainsKey($key)) {
        Fail "Opt-in-Cron '$key' ($($declared[$key].pkg), Default AUS) hat KEINEN erreichbaren cron_on:$key-Knopf im gebauten Graph (keine Setup-Aktivierung; Opt-in-Crons starten AUS, brauchen also einen Aktivieren-Knopf)"
    }
}
# --- (c) ALWAYS-ON: als Haushalts-Erinnerung registriert (cron_labels.list) -> an der Karte abschaltbar (cron_off:<key>
# ODER der Fusszeilen-Hinweis core.reminders.card_footer bei Bestaetigungs-Karten); sonst (Plumbing, Pflicht, Person-
# Notschalter) KEIN cron_on/cron_off-Knopf (nur Konsole bzw. rem:).
$footerWf = @{}
foreach ($file in (Get-ChildItem $wfDirs -Filter '*.json')) {
    if ([System.IO.File]::ReadAllText($file.FullName, $u8).Contains('core.reminders.card_footer')) {
        $footerWf[([System.IO.File]::ReadAllText($file.FullName, $u8) | ConvertFrom-Json).name] = $true
    }
}
foreach ($key in ($consoleKeys | Sort-Object)) {
    if ($regList.ContainsKey($key)) {
        $wfOfKey = @(Get-ChildItem $wfDirs -Filter '*.json' | Where-Object { [System.IO.File]::ReadAllText($_.FullName, $u8).Contains("__CFG_SCHEDULE_$($key.ToUpper())__") })
        $hasFooter = @($wfOfKey | Where-Object { $footerWf.ContainsKey(([System.IO.File]::ReadAllText($_.FullName, $u8) | ConvertFrom-Json).name) }).Count -gt 0
        if (-not $offKeys.ContainsKey($key) -and -not $hasFooter) {
            Fail "Haushalts-Erinnerung '$key' ($($regList[$key])) laesst sich an ihrer Karte nicht abschalten: weder cron_off:$key-Knopf noch Fusszeile core.reminders.card_footer im Cron-Workflow (RFC-8058-Prinzip: Abmelden an der Nachricht selbst)"
        }
        continue
    }
    if ($onKeys.ContainsKey($key))  { Fail "Always-on-Cron '$key' ($($declared[$key].pkg), Default AN, keine Haushalts-Erinnerung) hat einen cron_on:$key-Knopf ($($onKeys[$key])) -- nur Konsole; soll er schaltbar sein, in cron_labels.list aufnehmen." }
    if ($offKeys.ContainsKey($key)) { Fail "Always-on-Cron '$key' ($($declared[$key].pkg), Default AN, keine Haushalts-Erinnerung) hat einen cron_off:$key-Knopf ($($offKeys[$key])) -- nur Konsole; soll er schaltbar sein, in cron_labels.list aufnehmen." }
}
# --- (d) kein Dangling: jede gefundene cron-callback_data verweist auf einen deklarierten Key ------------------
foreach ($key in (@($onKeys.Keys) + @($offKeys.Keys) | Sort-Object -Unique)) {
    if (-not $declared.ContainsKey($key)) {
        $where = if ($onKeys.ContainsKey($key)) { $onKeys[$key] } else { $offKeys[$key] }
        Fail "Dangling: cron-Toggle auf '$key' ($where), aber kein Manifest deklariert .config.cron_enable.$key (umbenannter/entfernter Key?)"
    }
}

# --- (e) fn-Akzeptanz: core.fn_set_cron_enable (Chat-Pfad) akzeptiert GENAU die Opt-in-Keys -------------------
$fnFiles = @()
$fnFiles += Get-ChildItem (Join-Path $RepoRoot 'packages\*\db\migrations\R__fn_set_cron_enable.sql') -ErrorAction SilentlyContinue
if ($fnFiles.Count -eq 0) {
    Fail 'R__fn_set_cron_enable.sql nicht gefunden (fn-Akzeptanz nicht pruefbar -- verschoben/umbenannt?)'
} else {
    $fnSql = [System.IO.File]::ReadAllText($fnFiles[0].FullName, $u8)
    $wl = [regex]::Match($fnSql, "v_key\s+NOT\s+IN\s*\(([^)]*)\)", 'IgnoreCase')
    if (-not $wl.Success) {
        # Kein Whitelist-Literal mehr -> UPDATE-only-auf-Existenz (WS-0c). Akzeptanz = geseedete Zeile + db_test.
        if ($Verbose) { Write-Host "  [info] fn_set_cron_enable ohne NOT-IN-Whitelist -> Existenz-basiert; (e) uebersprungen (Akzeptanz via Seed + db_test)" -ForegroundColor DarkGray }
    } else {
        $whitelist = @{}
        foreach ($wm in [regex]::Matches($wl.Groups[1].Value, "'([a-z][a-z0-9_]*)'")) { $whitelist[$wm.Groups[1].Value] = $true }
        $chatSet = @{}; foreach ($k in $chatKeys) { $chatSet[$k] = $true }
        foreach ($key in ($chatKeys | Sort-Object)) {
            if (-not $whitelist.ContainsKey($key)) { Fail "core.fn_set_cron_enable akzeptiert den Opt-in-Key '$key' NICHT (fehlt in der NOT-IN-Whitelist -> Chat-Toggle schlaegt fehl)" }
        }
        foreach ($wk in ($whitelist.Keys | Sort-Object)) {
            if (-not $chatSet.ContainsKey($wk)) {
                if ($consoleKeys -contains $wk) { Fail "core.fn_set_cron_enable whitelistet '$wk', aber der Key ist always-on (Default AN, nur Konsole) -- gehoert nicht in den Chat-Pfad" }
                else { Fail "core.fn_set_cron_enable whitelistet '$wk', aber kein Manifest deklariert .config.cron_enable.$wk (tote Whitelist-Eintrag)" }
            }
        }
    }
}

# --- (f) cron_labels<->cron_enable-Paritaet (Phase 0 WS-0c #2/#3): die core.cron_labels-Registry IST die
# Togglability-SoT von core.fn_set_cron_enable (Mitgliedschaft=schaltbar). Jeder Opt-in-Key MUSS einen
# Manifest-cron_labels-Block haben (sonst lehnt die fn den Chat-Toggle ab), KEIN always-on-Key darf einen
# haben (sonst waere er entgegen dem gelockten Modell chat-schaltbar). Die vier Texte je Key stehen im Textkatalog
# des Pakets (<pkg>.cron.<key>.on_toast|off_toast|on_message|off_message, Textkatalog Phase B) und muessen in de.json
# existieren (locale_lint haelt die anderen Sprachen paritaetisch). SoT = die Manifest-cron_labels.list.
$labelKeys = @{}   # key -> @{ pkg; complete }
foreach ($mf in (Get-ChildItem (Join-Path $RepoRoot 'packages\*\manifest.json'))) {
    $mjson = [System.IO.File]::ReadAllText($mf.FullName, $u8) | ConvertFrom-Json
    if (-not $mjson.cron_labels) { continue }
    $pkg = [string]$mjson.name
    $deF = Join-Path $mf.DirectoryName 'locales\de.json'
    $de  = if (Test-Path $deF) { [System.IO.File]::ReadAllText($deF, $u8) | ConvertFrom-Json } else { [pscustomobject]@{} }
    foreach ($key in @($mjson.cron_labels.list)) {
        $key = [string]$key
        if ([string]::IsNullOrEmpty($key)) { continue }
        $complete = $true
        foreach ($s in 'on_toast', 'off_toast', 'on_message', 'off_message') { if (-not $de."$pkg.cron.$key.$s") { $complete = $false } }
        if ($labelKeys.ContainsKey($key)) { Fail "cron_labels-Key '$key' doppelt deklariert ($($labelKeys[$key].pkg) + $pkg)"; continue }
        $labelKeys[$key] = @{ pkg = $pkg; complete = $complete }
    }
}
foreach ($key in ($chatKeys | Sort-Object)) {
    if (-not $labelKeys.ContainsKey($key)) {
        Fail "Opt-in-Cron '$key' ($($declared[$key].pkg)) steht in KEINER Manifest-cron_labels.list -- core.fn_set_cron_enable (Registry-Membership = Togglability) lehnt den Chat-Toggle ab (WS-0c #2/#3)"
    } elseif (-not $labelKeys[$key].complete) {
        Fail "Opt-in-Cron '$key' ($($labelKeys[$key].pkg)): Katalog-Texte unvollstaendig (<pkg>.cron.$key.on_toast/off_toast/on_message/off_message muessen in locales/de.json stehen)"
    }
}
foreach ($key in ($labelKeys.Keys | Sort-Object)) {
    if (-not $declared.ContainsKey($key)) {
        Fail "cron_labels-Eintrag '$key' ($($labelKeys[$key].pkg)) hat keinen .config.cron_enable.$key -- tote Label-Zeile (umbenannter/entfernter Cron?)"
    } elseif (-not $labelKeys[$key].complete) {
        Fail "Haushalts-Erinnerung '$key' ($($labelKeys[$key].pkg)): Katalog-Texte unvollstaendig (<pkg>.cron.$key.on_toast/off_toast/on_message/off_message muessen in locales/de.json stehen)"
    }
}
# Pflicht-Erinnerungen (mandatory): cron_enable existiert, gehoeren in keine andere Ebene, tragen keinen Knopf.
foreach ($key in ($regMand.Keys | Sort-Object)) {
    if (-not $declared.ContainsKey($key)) { Fail "Pflicht-Erinnerung '$key' ($($regMand[$key])) hat keinen .config.cron_enable.$key" }
    if ($regList.ContainsKey($key) -or $regPerson.ContainsKey($key)) { Fail "Pflicht-Erinnerung '$key' ($($regMand[$key])) steht zusaetzlich in cron_labels.list/.person -- genau eine Ebene" }
    if ($onKeys.ContainsKey($key) -or $offKeys.ContainsKey($key)) { Fail "Pflicht-Erinnerung '$key' ($($regMand[$key])) traegt einen cron_on/cron_off-Knopf -- Pflicht heisst nicht schaltbar" }
}

# --- (g) Person-Reminder (Roter Faden 2026-10-23, Manifest cron_labels.person): jede Person schaltet ihre Zustellung
# per rem:on|off:<key> (agent.reminder_prefs); der cron_enable.<key> ist nur der Konsolen-Notschalter fuer alle ->
# er MUSS existieren und always-on sein (Default 'true'), sonst kaeme der Reminder nie an; die Toast-Texte
# <pkg>.cron.<key>.on_toast|off_toast muessen in locales/de.json stehen (core.fn_handle_reminder_cb liest sie);
# kein Key darf zugleich in list (Haushalt) und person stehen; jeder Person-Key hat einen rem:off:<key>-Knopf.
# --- (h) Erinnerungs-Fenster (Owner-Entscheid 2026-10-23): der Default-Zeitplan jedes Reminder-Crons (cron_labels.list
# + .person, sofern das Manifest einen config.schedule.<key> traegt) liegt in [general.reminders_from, reminders_until)
# des Core-Manifests (volle Stunden). Der Owner darf die Zeit spaeter per Konsole frei setzen.
$remOffKeys = @{}
foreach ($dir in $wfDirs) {
    foreach ($wf in (Get-ChildItem -Path $dir -Filter '*.json' -File)) {
        $raw = [System.IO.File]::ReadAllText($wf.FullName, $u8)
        foreach ($m in [regex]::Matches($raw, '"callback_data"\s*:\s*"rem:off:([a-z][a-z0-9_]*)"')) { $remOffKeys[$m.Groups[1].Value] = $wf.Name }
    }
}
$coreMf = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'packages\core\manifest.json'), $u8) | ConvertFrom-Json
$winFrom  = [int]$coreMf.config.general.reminders_from.value
$winUntil = [int]$coreMf.config.general.reminders_until.value
foreach ($mf in (Get-ChildItem (Join-Path $RepoRoot 'packages\*\manifest.json'))) {
    $mjson = [System.IO.File]::ReadAllText($mf.FullName, $u8) | ConvertFrom-Json
    if (-not $mjson.cron_labels) { continue }
    $pkg = [string]$mjson.name
    $deF = Join-Path $mf.DirectoryName 'locales\de.json'
    $de  = if (Test-Path $deF) { [System.IO.File]::ReadAllText($deF, $u8) | ConvertFrom-Json } else { [pscustomobject]@{} }
    $personKeys = @()
    if ($mjson.cron_labels.person) { $personKeys = @($mjson.cron_labels.person.PSObject.Properties.Name | Where-Object { $_ -ne '_comment' }) }
    foreach ($key in $personKeys) {
        if (@($mjson.cron_labels.list) -contains $key) { Fail "Reminder '$key' ($pkg) steht in cron_labels.list UND .person -- genau eine Schalt-Ebene" }
        if (-not $declared.ContainsKey($key)) { Fail "Person-Reminder '$key' ($pkg) hat keinen .config.cron_enable.$key (Konsolen-Notschalter fehlt)" }
        elseif ($declared[$key].default -ne 'true') { Fail "Person-Reminder '$key' ($pkg): cron_enable-Default muss 'true' sein (Notschalter; jede Person schaltet selbst) -- sonst kommt er nie an" }
        foreach ($s in 'on_toast', 'off_toast') { if (-not $de."$pkg.cron.$key.$s") { Fail "Person-Reminder '$key' ($pkg): Katalog-Text $pkg.cron.$key.$s fehlt in locales/de.json" } }
        if (-not $remOffKeys.ContainsKey($key)) { Fail "Person-Reminder '$key' ($pkg): kein Abmelde-Knopf rem:off:$key in einem gebauten Workflow (jede Karte muss sich abschalten lassen)" }
    }
    foreach ($key in (@($mjson.cron_labels.list) + $personKeys + @($mjson.cron_labels.mandatory))) {
        $key = [string]$key
        if (-not $key -or -not $mjson.config.schedule -or -not ($mjson.config.schedule.PSObject.Properties.Name -contains $key)) { continue }
        $expr = [string]$mjson.config.schedule.$key.value
        $hourField = ($expr -split '\s+')[1]
        foreach ($h in ($hourField -split '[,-]')) {
            if ($h -notmatch '^\d+$' -or [int]$h -lt $winFrom -or [int]$h -ge $winUntil) {
                Fail "Reminder '$key' ($pkg): Default-Zeitplan '$expr' liegt ausserhalb des Erinnerungs-Fensters $winFrom-$winUntil Uhr (general.reminders_from/until)"
            }
        }
    }
}

# --- (i) Roter Faden: JEDER Cron, der Telegram-Nachrichten schickt, ist eine registrierte Erinnerung (cron_labels
# list/person/mandatory) -> er erscheint in /reminders und folgt dem Fenster. Einzige Ausnahme: monitor_triggers, der
# Herzschlag der vom Nutzer SELBST bestellten Waechter (geschaltet je Trigger ueber den Monitor-Agenten, Wert-Waechter
# melden bewusst sofort). Plumbing-Crons ohne Telegram-Send brauchen keinen Eintrag.
$exemptSchedule = @('monitor_triggers')
# (j) jede registrierte Erinnerung hat ihre Menue-Bezeichnung <pkg>.cron.<key>.label in locales/de.json (das
# /reminders-Menue zeigte sonst den rohen Key; locale_lint haelt die anderen Sprachen paritaetisch).
foreach ($pair in @($regList.GetEnumerator()) + @($regPerson.GetEnumerator()) + @($regMand.GetEnumerator())) {
    $deF = Join-Path $RepoRoot "packages\$($pair.Value)\locales\de.json"
    $de  = if (Test-Path $deF) { [System.IO.File]::ReadAllText($deF, $u8) | ConvertFrom-Json } else { [pscustomobject]@{} }
    if (-not $de."$($pair.Value).cron.$($pair.Key).label") { Fail "Erinnerung '$($pair.Key)' ($($pair.Value)): Menue-Bezeichnung $($pair.Value).cron.$($pair.Key).label fehlt in locales/de.json (/reminders)" }
}
foreach ($file in (Get-ChildItem $wfDirs -Filter '*.json')) {
    $raw = [System.IO.File]::ReadAllText($file.FullName, $u8)
    $sm = [regex]::Match($raw, '__CFG_SCHEDULE_([A-Z0-9_]+)__')
    if (-not $sm.Success) { continue }
    $wf = $raw | ConvertFrom-Json
    $sends = @($wf.nodes | Where-Object { $_.type -eq 'n8n-nodes-base.telegram' -and [string]$_.parameters.resource -ne 'callback' -and [string]$_.parameters.operation -ne 'sendMessageDraft' })
    if ($sends.Count -eq 0) { continue }
    $key = $sm.Groups[1].Value.ToLower()
    if ($exemptSchedule -contains $key) { continue }
    if (-not ($regList.ContainsKey($key) -or $regPerson.ContainsKey($key) -or $regMand.ContainsKey($key))) {
        Fail "Cron '$($wf.name)' schickt Telegram-Nachrichten, aber '$key' ist keine registrierte Erinnerung (cron_labels.list/.person/.mandatory) -- er fehlte in /reminders und im Erinnerungs-Fenster"
    }
}

if ($Verbose) {
    Write-Host "  opt-in (Chat)   = $(@($chatKeys    | Sort-Object) -join ', ')" -ForegroundColor DarkGray
    Write-Host "  always-on (Konsole) = $(@($consoleKeys | Sort-Object) -join ', ')" -ForegroundColor DarkGray
    Write-Host "  cron_on  = $(@($onKeys.Keys  | Sort-Object) -join ', ')" -ForegroundColor DarkGray
    Write-Host "  cron_off = $(@($offKeys.Keys | Sort-Object) -join ', ')" -ForegroundColor DarkGray
}
if ($fails -eq 0) { Write-Host "cron_toggle_lint: OK ($($chatKeys.Count) Opt-in-Cron(s) mit cron_on+cron_off, $($consoleKeys.Count) always-on-Cron(s) ohne Chat-Knopf)" -ForegroundColor Green }
else { Write-Host "cron_toggle_lint: $fails Fehler" -ForegroundColor Red }
exit $fails
