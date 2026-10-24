#Requires -Version 5.1
# make_doc_fixtures.ps1 — erzeugt die ECHTEN Test-Dokumente, die der Mock-Telegram fuer bestimmte file_ids ausliefert
# (tests/mock_telegram/docs/<file_id>.<png|pdf>). Ohne Dokument liefert der Mock weiter das 1x1-PNG.
#
# Warum: der Echt-LLM-Tier (n8n_test) bekam fuer tc49/tc51 nur ein 1x1-PNG -> die echte Vision las nichts, der
# Foto-/PDF-Import (Owner-Hauptablauf) war im bezahlten Tier nie getestet. Der Mock-LLM-Tier ignoriert den Inhalt
# (seine Vision-Antwort kommt aus tests/mock_llm/scenarios.json) -> beide Tiers nutzen dieselbe Datei.
#
# Die Werte MUESSEN zu den Mock-Szenarien und den Routing-Fixtures passen:
#   mock_photo_001.png  Kontenuebersicht Testbank (tc49)   = Szenario "Kontenübersicht der Testbank"
#   mock_photo_051.pdf  Kontoauszug DKB Januar 2000 (tc51)  = Szenario "Monatsauszug Mock-DKB" + IBAN des Fixture-Kontos
#                       DKB Giro (tests/fixtures/util_seed_test_fixtures.sql); Saldo-Probe 2500 - 42,90 - 57,10 = 2400.
#   mock_photo_056.pdf  Kontoauszug TR Cash Lisa Jan. 2000  = Szenario "Trade Republic Cash Konto meiner Tochter Lisa" (tc61):
#                       IBAN gehoert KEINEM Fixture-Konto (account_unknown); Saldo-Probe 100 + 100 - 50 = 150.
#   mock_photo_063.pdf  Vermoegensuebersicht TR (tc63)      = Szenario "Vermoegensuebersicht Trade Republic Depot": je
#                       Position nur ISIN + Stueck + aktueller Kurs, KEIN Ticker, KEIN Einstand (Owner-Befund 2026-10-23).
#
# Usage:  .\tests\mock_telegram\make_doc_fixtures.ps1     (danach enable_mock_telegram.ps1 kopiert docs/ in den Container)
$ErrorActionPreference = 'Stop'
$Out = Join-Path $PSScriptRoot 'docs'
New-Item -ItemType Directory -Force $Out | Out-Null

# --- mock_photo_001.png: Foto-artige Kontenuebersicht (System.Drawing, nur Windows-PowerShell) ---------------------
Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap 1000, 520
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$g.Clear([System.Drawing.Color]::White)
$fTitle = New-Object System.Drawing.Font 'Arial', 26, ([System.Drawing.FontStyle]::Bold)
$fHead  = New-Object System.Drawing.Font 'Arial', 15, ([System.Drawing.FontStyle]::Bold)
$fBody  = New-Object System.Drawing.Font 'Arial', 15
$ink = [System.Drawing.Brushes]::Black
$g.DrawString('Testbank AG', $fTitle, $ink, 40, 30)
$g.DrawString('Kontenübersicht  -  Stand 23.10.2026', $fHead, $ink, 40, 90)
$g.DrawString('Kontoinhaber: Erika Mustermann', $fBody, $ink, 40, 130)
$g.DrawLine([System.Drawing.Pens]::Gray, 40, 180, 960, 180)
$g.DrawString('Konto', $fHead, $ink, 40, 195); $g.DrawString('IBAN', $fHead, $ink, 430, 195); $g.DrawString('Kontostand', $fHead, $ink, 780, 195)
$g.DrawLine([System.Drawing.Pens]::Gray, 40, 230, 960, 230)
$g.DrawString('Testbank Giro Mock (Girokonto)', $fBody, $ink, 40, 245)
$g.DrawString('DE02 1001 0010 0006 8201 01', $fBody, $ink, 430, 245)
$g.DrawString('1.234,56 EUR', $fBody, $ink, 780, 245)
$g.DrawLine([System.Drawing.Pens]::Gray, 40, 285, 960, 285)
$g.DrawString('Summe aller Konten: 1.234,56 EUR', $fHead, $ink, 40, 300)
$g.DrawString('Alle Angaben ohne Gewähr. Testdokument für automatisierte Tests.', $fBody, [System.Drawing.Brushes]::DimGray, 40, 460)
$g.Dispose()
$bmp.Save((Join-Path $Out 'mock_photo_001.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

# --- Text-PDFs (Helvetica, WinAnsi), Objekte + xref von Hand ------------------------------------------------------
$enc = [System.Text.Encoding]::GetEncoding(1252)
function ConvertTo-PdfString([string]$s) { $s.Replace('\', '\\').Replace('(', '\(').Replace(')', '\)') }
function Write-TextPdf([string]$Name, [object[]]$Lines) {
    $stream = ($Lines | ForEach-Object { "BT /F1 $($_[2]) Tf $($_[0]) $($_[1]) Td ($(ConvertTo-PdfString $_[3])) Tj ET" }) -join "`n"
    $objs = @(
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
        '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
        "<< /Length $($enc.GetByteCount($stream)) >>`nstream`n$stream`nendstream"
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("%PDF-1.4`n")
    $offsets = @()
    for ($i = 0; $i -lt $objs.Count; $i++) {
        $offsets += $enc.GetByteCount($sb.ToString())
        [void]$sb.Append("$($i + 1) 0 obj`n$($objs[$i])`nendobj`n")
    }
    $xref = $enc.GetByteCount($sb.ToString())
    [void]$sb.Append("xref`n0 $($objs.Count + 1)`n0000000000 65535 f `n")
    foreach ($o in $offsets) { [void]$sb.Append(("{0:D10} 00000 n `n" -f $o)) }   # 20 Bytes je Eintrag (doppelte Anfuehrung: `n = LF)
    [void]$sb.Append("trailer`n<< /Size $($objs.Count + 1) /Root 1 0 R >>`nstartxref`n$xref`n%%EOF`n")
    [System.IO.File]::WriteAllBytes((Join-Path $Out $Name), $enc.GetBytes($sb.ToString()))
}

Write-TextPdf 'mock_photo_051.pdf' @(
    @(50, 790, 18, 'DKB - Deutsche Kreditbank AG'),
    @(50, 765, 13, 'Kontoauszug Nr. 1/2000  -  Girokonto'),
    @(50, 740, 11, 'Kontoinhaber: Erika Mustermann'),
    @(50, 724, 11, 'IBAN: DE45 1203 0000 1234 5678 90    BIC: BYLADEM1001'),
    @(50, 708, 11, 'Zeitraum: 01.01.2000 bis 31.01.2000'),
    @(50, 680, 11, 'Alter Kontostand am 01.01.2000                                   2.500,00 EUR'),
    @(50, 650, 11, 'Buchung    Wert       Vorgang                                         Betrag EUR'),
    @(50, 632, 11, '05.01.2000 05.01.2000 Kartenzahlung ARAL Tankstelle, Tanken            -42,90'),
    @(50, 614, 11, '12.01.2000 12.01.2000 Kartenzahlung REWE, Einkauf                       -57,10'),
    @(50, 584, 11, 'Neuer Kontostand am 31.01.2000                                   2.400,00 EUR'),
    @(50, 540,  9, 'Testdokument fuer automatisierte Tests. Bitte pruefen Sie diesen Kontoauszug.')
)

Write-TextPdf 'mock_photo_056.pdf' @(
    @(50, 790, 18, 'Trade Republic Bank GmbH'),
    @(50, 765, 13, 'Kontoauszug  -  Cash-Konto'),
    @(50, 740, 11, 'Kontoinhaberin: Lisa Mustermann'),
    @(50, 724, 11, 'IBAN: DE72 1001 2345 0000 0005 62    BIC: TRBKDEBBXXX'),
    @(50, 708, 11, 'Zeitraum: 01.01.2000 bis 31.01.2000'),
    @(50, 680, 11, 'Anfangssaldo am 01.01.2000                                         100,00 EUR'),
    @(50, 650, 11, 'Datum      Vorgang                                                  Betrag EUR'),
    @(50, 632, 11, '03.01.2000 Eingehende Ueberweisung Erika Mustermann                   100,00'),
    @(50, 614, 11, '04.01.2000 Sparplan Vanguard FTSE All-World UCITS ETF                 -50,00'),
    @(50, 584, 11, 'Endsaldo am 31.01.2000                                             150,00 EUR'),
    @(50, 540,  9, 'Testdokument fuer automatisierte Tests. Bitte pruefen Sie diesen Kontoauszug.')
)

Write-TextPdf 'mock_photo_063.pdf' @(
    @(50, 790, 18, 'Trade Republic Bank GmbH'),
    @(50, 765, 13, 'Vermoegensuebersicht zum 31.01.2000'),
    @(50, 740, 11, 'Erika Mustermann                                  Depot 9000000001'),
    @(50, 710, 11, 'Stk.          Wertpapier                                  Kurs pro Stueck   Kurswert EUR'),
    @(50, 692, 11, '1,500000 Stk. Testaktie Raumfahrt AG                           129,54         194,31'),
    @(50, 678, 10, '              ISIN: US84615Q1031'),
    @(50, 660, 11, '42,731759 Stk. S&P 500 (Dist)                                  63,12       2.697,40'),
    @(50, 646, 10, '              ISIN: IE00BYML9W36'),
    @(50, 616, 11, 'Anzahl Positionen: 2                                                       2.891,71 EUR'),
    @(50, 590, 11, 'Cash (Verrechnungskonto) zum 31.01.2000                                   1.234,56 EUR'),
    @(50, 540,  9, 'Testdokument fuer automatisierte Tests. Keine Einstandskurse aufgefuehrt.')
)

Get-ChildItem $Out | ForEach-Object { "{0,-22} {1,8} Bytes" -f $_.Name, $_.Length }
