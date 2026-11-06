#Requires -Version 5.1
# owner_fact_lint.ps1 -- Regeln fuer die Fundorte, an denen frueher Lebensumstaende des Betreibers ins Repo kamen (hartes Gate,
# Ergaenzung zu privacy_lint.ps1, das nur feste Werte kennt):
#   (P) Prompt-Dateien (Contexts, Manifeste, Build-Defs, Seeds): keine Saetze ueber die Lage des Betreibers. Fakten ueber Personen
#       stehen zur Laufzeit in der Datenbank (Onboarding, Profil), Prompts sind Code und oeffentlich.
#   (M) Ueberall: keine Herkunftsmarken, die einen Sachverhalt als echt ausweisen. Der Anlass einer Aenderung heisst "Befund
#       <Datum>", und er beschreibt die Eigenschaft, nicht die Person, Bank oder Summe.
#   (B) Ueberall: kein "Live-Befund" zusammen mit einem Geldbetrag auf derselben Zeile oder, bei Kommentaren, auf der Folgezeile.
# Die Muster bleiben grob: Sie finden typische Formulierungen, keine Umschreibungen; die pruefen /privacy-review und der Owner.
# Ausgenommen: generierte Dateien (ihre Quellen werden geprueft), angewandte V__-Migrationen (Pruefsummen-Schutz), diese Datei.
# Ausgaben nennen nur Datei:Zeile und die Regel. Exit-Code = Anzahl Fehler. Kein LLM, kein Netz, kein Substrat.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }

$promptRegex = "the owner'?s situation|owner facts|the owner (dislikes|lives|works)"
$markerRegex = '\b(Owner-(Befund|Fund|Vorfall|Import|Lauf)|Owner-Fall\b|Prod-(Entit[a-z]*|Loan|Holding|Fixture|Stand|Immobilie)|Live-Instanz)'
$amountRegex = '(Live-?[Bb]efund|Live-?[Ff]all).*([0-9],[0-9]{2}\b|[0-9]\.[0-9]{2} ?(EUR|€)|-[0-9]+\.[0-9]{2}\b)'
$foundRegex = '(Live-?[Bb]efund|Live-?[Ff]all)'
$commentRegex = '^\s*(--|#|//)'
# Folgezeile: auch ganze Euro ("um 700"); ein Datum wie 31.12.-31.03. ist kein Betrag
$nextAmountRegex = '([0-9],[0-9]{2}\b|[0-9]\.[0-9]{2} ?(EUR|€)|-[0-9]+\.[0-9]{2}\b(?!\.)|\bum [0-9]{2,}\b|\b[0-9]{2,} ?(EUR|€|Euro)\b)'
$promptPaths = @('packages/*/contexts/*', 'packages/*/manifest.json', 'packages/*/build/*', 'packages/*/seed/*')
# glob: ohne dieses Merkmal passt * auch ueber / und nimmt die Quellen unter packages/*/build/workflows/ mit heraus
$generated = @(':(exclude,glob)packages/*/workflows/**', ':(exclude)docs/site/public/*', ':(exclude)docs/fn_catalog.md',
    ':(exclude,glob)packages/*/db/migrations/V*__*', ':(exclude)scripts/owner_fact_lint.ps1', ':(exclude)scripts/dev/privacy_lint_test.ps1')

# Selbst-Asserts: stirbt die Erkennung still, bricht der Lint. Die Proben werden zusammengesetzt, damit die Datei sauber bleibt.
if (('the owner' + ' dislikes meetings') -notmatch $promptRegex) { Fail 'Selbst-Assert: Prompt-Regel defekt' }
if (('Owner-' + 'Befund 2026') -cnotmatch $markerRegex) { Fail 'Selbst-Assert: Marken-Regel defekt' }
if (('Owner-' + 'Fallback') -cmatch $markerRegex) { Fail 'Selbst-Assert: Marken-Regel trifft einen Fachbegriff' }
if (('Live-' + 'Befund: -1.23 raus') -cnotmatch $amountRegex) { Fail 'Selbst-Assert: Betrags-Regel defekt' }
if (('Live-' + 'Befund 2026-10-24 n8n 2.44.4') -cmatch $amountRegex) { Fail 'Selbst-Assert: Betrags-Regel trifft eine Version' }
if ('-- blaehte die Summe um 123 auf' -notmatch $nextAmountRegex) { Fail 'Selbst-Assert: Folgezeilen-Regel defekt' }
if ('-- erste Periode 24.10.-31.12., dann 31.12.-31.03.' -match $nextAmountRegex) { Fail 'Selbst-Assert: Folgezeilen-Regel trifft ein Datum' }

function Invoke-Rule([string]$Label, [string[]]$GrepArgs) {
    $out = & git -C $RepoRoot (@('grep', '-n', '-I', '-E') + $GrepArgs)
    if ($LASTEXITCODE -gt 1) { Fail "git grep fehlgeschlagen (Exit $LASTEXITCODE): $Label"; return }
    foreach ($h in @($out | Where-Object { $_ })) {
        if ($h -match '^(.*?):(\d+):') { Fail "${Label}: $($Matches[1]):$($Matches[2])" }
    }
}
Invoke-Rule 'Satz ueber den Betreiber in einem Prompt' (@('-i', $promptRegex, '--') + $promptPaths + $generated)
Invoke-Rule 'Herkunftsmarke' (@($markerRegex, '--', '.') + $generated)
Invoke-Rule 'Live-Befund mit Betrag' (@($amountRegex, '--', '.') + $generated)
# Regel (B), Folgezeile: Befund-Kommentar, der Betrag steht eine Zeile darunter. git grep -A1 trennt Kontextzeilen mit "-".
$ctx = & git -C $RepoRoot (@('grep', '-n', '-I', '-E', '-A1', $foundRegex, '--', '.') + $generated)
if ($LASTEXITCODE -gt 1) { Fail "git grep fehlgeschlagen (Exit $LASTEXITCODE): Live-Befund mit Betrag (Folgezeile)" }
$hitPath = $null; $hitLine = 0
foreach ($c in @($ctx | Where-Object { $_ })) {
    # zuerst die Kontextzeile: ihr Text darf selbst wie ein Treffer aussehen
    if ($hitPath -and $c.StartsWith("$hitPath-$($hitLine + 1)-", [StringComparison]::Ordinal)) {
        $body = $c.Substring("$hitPath-$($hitLine + 1)-".Length)
        if ($body -match $commentRegex -and $body -match $nextAmountRegex) { Fail "Live-Befund mit Betrag auf der Folgezeile: ${hitPath}:$($hitLine + 1)" }
    } elseif ($c -match '^(.*?):(\d+):') {
        $hitPath = $Matches[1]; $hitLine = [int]$Matches[2]
    }
}

if ($fails -eq 0) { Write-Host 'owner_fact_lint: OK' -ForegroundColor Green }
exit $fails
