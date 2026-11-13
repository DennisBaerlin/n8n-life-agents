#Requires -Version 5.1
# Kurs-Quelle einer Depot-Position: geteilte Bausteine fuer Kauf, Korrektur, Sparplan-
# Ausfuehrung, Kurs-Symbol-Pruefung und die Kurs-Luecken-Erinnerung. Helper-Datei ohne Build-* (die Builder-Discovery
# liefert hier 0 Builder); gelesen nur in Funktionskoerpern -> Ladereihenfolge egal.

# 'Price status' (Postgres): Kurs-Status einer Position nach dem Sofort-Kursabruf -> Feld st {status ok|stale|missing,
# price, price_currency, price_as_of, feed_symbol}. Die eine Regel ist finance.fn_holding_price_status. Aggregiert -> immer ein
# Item; onError continue + alwaysOutputData: ein Lesefehler darf eine schon gebuchte Aenderung nie als Fehler melden.
# Bewusster Read nach dem HTTP-Abruf (der Kurs kommt erst nach der Write-fn; Vorbild commit_import 'Check positions').
function New-FinancePriceStatusNode {
    param([Parameter(Mandatory)][int[]]$Pos, [Parameter(Mandatory)][string]$HoldingIdExpr)
    $n = Build-Pg 'Price status' $Pos `
        "=SELECT (SELECT jsonb_build_object('status', s.status, 'price', s.price, 'price_currency', s.price_currency, 'price_as_of', s.price_as_of, 'feed_symbol', s.feed_symbol) FROM finance.fn_holding_price_status(ARRAY[((`$1::jsonb)->>'holding_id')::int]) s) AS st;" `
        ([ordered]@{ holding_id = $HoldingIdExpr })
    $n['onError'] = 'continueRegularOutput'
    $n['alwaysOutputData'] = $true
    $n
}

# 'Check FX rates' + 'FX refresh needed?': nach einem Sofort-Kursabruf entscheidet die DB (fn_fx_rate_status), ob ein
# Wechselkurs fehlt; die Kurswaehrung kennt erst der Abruf, darum keine Pruefung auf Eingabe-Felder. Ausgaenge des IF:
# [0] Abruf noetig, [1] weiter. Ein Lesefehler darf eine schon gebuchte Aenderung nie als Fehler melden (dann weiter).
function New-FinanceFxGapCheck {
    param([Parameter(Mandatory)][int[]]$CheckPos, [Parameter(Mandatory)][int[]]$IfPos)
    $check = Build-Pg 'Check FX rates' $CheckPos `
        "SELECT count(*) FILTER (WHERE status <> 'ok')::int AS gaps FROM finance.fn_fx_rate_status()"
    $check['onError'] = 'continueRegularOutput'
    $check['alwaysOutputData'] = $true
    $if = Build-If 'FX refresh needed?' $IfPos "={{ `$json.gaps }}" '0' 'larger' 'number'
    @($check, $if)
}

# Plausi-Referenzen fuer agent.finance.sub_resolve_yahoo_symbol aus einer Kurs-Status-Zeile ($RefJs = JS-Objekt mit
# price, price_currency, avg, currency — z. B. aus fn_holding_price_status) + FX-Karte ($FxJs, finance.fn_fx_rate_map):
# letzter Kurs (enges Band) UND Einstand (grobes Band), je in ihrer eigenen Waehrung (der Sub rechnet bei Bedarf in EUR).
function Get-FinancePriceRefInputs {
    param([Parameter(Mandatory)][string]$RefJs, [Parameter(Mandatory)][string]$FxJs)
    [ordered]@{
        ref_price     = "={{ ($RefJs).price != null ? String(($RefJs).price) : '' }}"
        ref_currency  = "={{ ($RefJs).price_currency || '' }}"
        cost_price    = "={{ ($RefJs).avg != null ? String(($RefJs).avg) : '' }}"
        cost_currency = "={{ ($RefJs).currency || '' }}"
        fx_rates      = "={{ JSON.stringify($FxJs || {}) }}"
    }
}
