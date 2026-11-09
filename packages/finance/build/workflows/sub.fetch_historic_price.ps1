#Requires -Version 5.1
# Definition agent.finance.sub_fetch_historic_price -> Build-FetchHistoricPrice. Dot-gesourct von build.ps1.
# Deterministisch, kein LLM. Schlusskurs eines Papiers am Buchungstag fuer den Einstand-Vorschlag der Ersteinrichtung (Abspaltung,
# Einbuchung). Quelle Yahoo: search?q=ISIN -> Notierungen -> chart mit period1/period2. An handelsfreien Tagen fehlt die Zeile, darum ein
# Fenster von 7 Tagen und der letzte Kurs bis einschliesslich zum Tag. Nur eine Notierung in der gewuenschten Waehrung: ein Kurs in anderer
# Waehrung waere ohne alten Wechselkurs keine belastbare Schaetzung, dann fragt der Agent nach. Best-Effort: jeder Fehler -> {ok:false}.
function Build-FetchHistoricPrice {
    $trig = Build-Trigger @('isin', 'date', 'currency')
    $js = @'
const isin = String($('Start').item.json.isin || '').trim().toUpperCase();
const day  = String($('Start').item.json.date || '').slice(0, 10);
const want = String($('Start').item.json.currency || 'EUR').trim().toUpperCase();
const fail = () => [{ json: { ok: false, price: null, symbol: null, currency: want } }];
if (!/^[A-Z0-9]{8,14}$/.test(isin) || !/^\d{4}-\d{2}-\d{2}$/.test(day)) return fail();
const end = Math.floor(Date.parse(day + 'T00:00:00Z') / 1000) + 86400;
try {
  const s = await this.helpers.httpRequest({ url: 'https://query1.finance.yahoo.com/v1/finance/search?q=' + encodeURIComponent(isin) + '&quotesCount=8&newsCount=0', json: true, timeout: 3000 });
  const symbols = ((s && s.quotes) || []).map(q => q && q.symbol).filter(Boolean);
  for (const sym of symbols.slice(0, 6)) {
    let r = null;
    try {
      const c = await this.helpers.httpRequest({ url: 'https://query1.finance.yahoo.com/v8/finance/chart/' + encodeURIComponent(sym) + '?period1=' + (end - 7 * 86400) + '&period2=' + end + '&interval=1d', json: true, timeout: 3000 });
      r = c && c.chart && c.chart.result && c.chart.result[0];
    } catch (e) { continue; }
    let ccy = r && r.meta ? String(r.meta.currency || '') : '';
    const pence = ccy === 'GBp';
    if (pence) ccy = 'GBP';
    if (ccy !== want || !r.timestamp || !r.indicators || !r.indicators.quote || !r.indicators.quote[0]) continue;
    const close = r.indicators.quote[0].close || [];
    for (let i = close.length - 1; i >= 0; i--) {
      if (r.timestamp[i] < end && Number(close[i]) > 0) {
        return [{ json: { ok: true, price: pence ? Number(close[i]) / 100 : Number(close[i]), symbol: sym, currency: ccy } }];
      }
    }
  }
} catch (e) { /* Yahoo-Ausfall: der Agent fragt nach */ }
return fail();
'@
    $fetch = [ordered]@{
        parameters = [ordered]@{ jsCode = $js }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(260, 0)
        id = (New-Id); name = 'Fetch close'
        onError = 'continueRegularOutput'
    }
    $sticky = Build-Sticky 'Überblick' @(-360, -300) `
        'Historischer Schlusskurs (deterministisch, kein LLM)' `
        'Input { isin, date, currency }. Ein Code-Knoten: Yahoo-Suche nach der ISIN, dann Chart mit Datumsgrenzen; letzter Kurs der 7 Tage bis zum Buchungstag. Nur Notierung in der gewünschten Währung, sonst ok:false und der Agent fragt nach dem Einstand. Output { ok, price, symbol, currency }.' 320 300
    $nodes = @($trig, $fetch, $sticky)
    $conns = [ordered]@{ 'Start' = @{ main = @( ,@( E 'Fetch close' ) ) } }
    return (Build-Workflow 'agent.finance.sub_fetch_historic_price' $nodes $conns)
}
