#Requires -Version 5.1
# Definition agent.finance.sub_resolve_yahoo_symbol -> Build-ResolveYahooSymbol. Dot-gesourct von build.ps1.
# Deterministisch, KEIN LLM. Loest beim Kauf (book_stock_buy) / Korrigieren (set_holding) das richtige Yahoo-
# Kurs-Symbol fuer eine ISIN auf, damit der Markt-Preis-Cron (COALESCE(provider_symbol, symbol)) verlaesslich
# trifft. Quelle = Yahoo (wie Portfolio Performance): v1/finance/search?q=ISIN -> Kandidaten -> je Kandidat
# v8/finance/chart (Preis/Waehrung/Boerse; GBp/Pence -> GBP/100). DISAMBIGUIERUNG per Waehrung == price_currency
# (die vom Nutzer mit dem Kaufkurs genannte Waehrung; zuverlaessiger Selektor), darin die erste plausible Notierung. BEST-EFFORT /
# NON-BLOCKING: alle HTTP in EINEM Code-Node (this.helpers.httpRequest top-level, try/catch, timeout 3000ms) wie der
# Cron; jeder Fehler/Ausfall -> { verified:false, provider_symbol:raw } -> die Buchung laeuft trotzdem. Output flach:
# { ok, verified, provider_symbol, market_price, currency, exchange, candidates, foreign_listing, plausible }.
# foreign_listing (2026-10-23): KEINE Notierung in der Wunschwaehrung, der beste Kandidat notiert in einer anderen
# Waehrung (derselbe ISIN-Treffer, z. B. SPCX/USD fuer eine EUR-Position) -> Aufrufer duerfen ihn bei plausible
# uebernehmen; die Bewertung rechnet per FX in EUR um (depot_holdings_overview).
# PLAUSI-PFLICHT (Owner 2026-10-27): verified setzt plausible voraus — ein Treffer ohne passende Kurs-Groessenordnung
# zaehlt nie als verifiziert. ZWEI Referenzen, eine reicht: ref_price/ref_currency (letzter Kurs der Position, enges Band
# 0,8-1,25) ODER cost_price/cost_currency bzw. price_per_share in price_currency (Kauf-/Einstandskurs, Band 0,2-5 — deckt
# auch einen seit Wochen veralteten oder von einer falschen Notierung stammenden letzten Kurs ab). Ohne jede Referenz ->
# plausible:false. Andere Waehrung als die Referenz: Vergleich in EUR ueber fx_rates (JSON {CCY: Kurs EUR->CCY}); ohne
# FX nur roh gegen den Kaufkurs (grobes Band). adoptable = EINE Regel "darf als Kursquelle gespeichert werden"
# (verified ODER plausible Fremdwaehrungs-Notierung derselben ISIN) fuer alle Aufrufer. try_symbols (Websuche) sind nicht
# ISIN-gebunden -> dort nie foreign_listing (nur Treffer in Wunschwaehrung). name = Yahoo-Name der Notierung.
function Build-ResolveYahooSymbol {
    $trig = Build-Trigger @('isin','raw_symbol','price_currency','price_per_share','provider_symbol','ref_price','ref_currency','cost_price','cost_currency','fx_rates','try_symbols') @(0, 0)

    $resolveJs = @'
const isin    = String($('Start').item.json.isin || '').trim();
const raw     = String($('Start').item.json.raw_symbol || '').trim();
const wantCcy = String($('Start').item.json.price_currency || '').trim().toUpperCase();
const buyPx   = Number($('Start').item.json.price_per_share);
const refPx   = Number($('Start').item.json.ref_price);
const refCcy  = String($('Start').item.json.ref_currency || wantCcy).trim().toUpperCase();
const costPx  = Number($('Start').item.json.cost_price);
const costCcy = String($('Start').item.json.cost_currency || wantCcy).trim().toUpperCase();
const given   = String($('Start').item.json.provider_symbol || '').trim();
let fx = {};
try { fx = JSON.parse(String($('Start').item.json.fx_rates || '{}')) || {}; } catch (e) { fx = {}; }

// flacher Output mit Defaults (roh-Symbol, nicht verifiziert) -> spread overrides; adoptable wird hier abgeleitet
function out(o) {
  const r = Object.assign(
    { ok: true, verified: false, provider_symbol: raw, market_price: null, currency: null, exchange: null, name: null,
      candidates: [], foreign_listing: false, plausible: false }, o);
  r.adoptable = r.verified === true || (r.foreign_listing === true && r.plausible === true);
  return [{ json: r }];
}
// PURE: parst eine Yahoo-Chart-Antwort -> {symbol,price,currency,exchange,name} | null (Pence GBp -> GBP/100)
function parseChart(res, sym) {
  const r = res && res.chart && res.chart.result && res.chart.result[0];
  const m = r && r.meta ? r.meta : null;
  if (!m) return null;
  let px = Number(m.regularMarketPrice); let ccy = String(m.currency || '');
  if (ccy === 'GBp') { px = px / 100; ccy = 'GBP'; }
  if (!(px > 0) || Number.isNaN(px)) return null;
  return { symbol: sym, price: px, currency: ccy.toUpperCase(), exchange: String(m.exchangeName || m.fullExchangeName || ''),
           name: String(m.longName || m.shortName || '') };
}
// Plausi (EINE Adresse fuer alle Aufrufer): Kurs des Kandidaten vs. Referenzen der Position (eine reicht).
const rateOf = (c) => (c === 'EUR' ? 1 : Number(fx[c]));
const REFS = [];
if (refPx > 0)  REFS.push({ px: refPx,  ccy: refCcy,  lo: 0.8, hi: 1.25, rough: false });
if (costPx > 0) REFS.push({ px: costPx, ccy: costCcy, lo: 0.2, hi: 5,    rough: true });
else if (buyPx > 0) REFS.push({ px: buyPx, ccy: wantCcy, lo: 0.2, hi: 5, rough: true });
function ratioOf(c, R) {
  if (!R.ccy || c.currency === R.ccy) return c.price / R.px;
  const rc = rateOf(c.currency), rr = rateOf(R.ccy);
  if (rc > 0 && rr > 0) return (c.price / rc) / (R.px / rr);
  return R.rough ? c.price / R.px : null;   // ohne FX nur grob gegen den Kaufkurs (Band 0,2-5 faengt USD/GBP/CHF ab)
}
function isPlausible(c) { return REFS.some((R) => { const r = ratioOf(c, R); return r !== null && r > R.lo && r < R.hi; }); }
const CHART = (s) => 'https://query1.finance.yahoo.com/v8/finance/chart/' + encodeURIComponent(s)
                   + '?range=1d&interval=1d&lang=en-US&region=US&corsDomain=finance.yahoo.com';

try {
  // (1) Krypto (keine ISIN) -> kein Yahoo-Symbol-Lookup; roh-Symbol, nicht verifiziert.
  if (!isin) return out({});

  // (2) provider_symbol gegeben -> nur DIESES verifizieren (kein ISIN-Search).
  if (given) {
    let c = null;
    try { c = parseChart(await this.helpers.httpRequest({ url: CHART(given), json: true, timeout: 3000 }), given); } catch (e) { c = null; }
    if (c) {
      const pl = isPlausible(c);
      return out({ verified: (!wantCcy || c.currency === wantCcy) && pl, plausible: pl, provider_symbol: given,
                   market_price: c.price, currency: c.currency, exchange: c.exchange, name: c.name, candidates: [c] });   // foreign_listing nur aus der ISIN-Suche (nur sie weiss, ob es eine Notierung in Wunschwaehrung gibt)
    }
    return out({ provider_symbol: given });
  }

  // (3) Kandidaten-Ticker: try_symbols (Komma-Liste, z. B. aus der Websuche der Kurs-Luecken-Erinnerung) ODER Yahoo-
  // ISIN-Suche. Beide laufen danach durch DIESELBE Chart-Pruefung + Plausi-Auswahl (eine Adresse).
  const tries = String($('Start').item.json.try_symbols || '').split(',').map(s => s.trim().toUpperCase()).filter(Boolean);
  let listings = [];
  if (tries.length) {
    listings = Array.from(new Set(tries));
  } else {
    try {
      const sres = await this.helpers.httpRequest({
        url: 'https://query1.finance.yahoo.com/v1/finance/search?q=' + encodeURIComponent(isin) + '&quotesCount=8&newsCount=0',
        json: true, timeout: 3000 });
      listings = (sres && sres.quotes ? sres.quotes : []).map(q => q && q.symbol).filter(Boolean);
    } catch (e) { listings = []; }
  }
  if (!listings.length) return out({});

  // (4) je Kandidat (max 6) den Chart -> Preis/Waehrung/Boerse.
  const cands = [];
  for (const sym of listings.slice(0, 6)) {
    try { const c = parseChart(await this.helpers.httpRequest({ url: CHART(sym), json: true, timeout: 3000 }), sym); if (c) cands.push(c); }
    catch (e) { /* einzelner Kandidat-Ausfall -> skip */ }
  }
  if (!cands.length) return out({});

  // (5) Auswahl: Wunschwaehrung zuerst (SELEKTOR), darin die erste PLAUSIBLE Notierung; ohne Notierung in Wunsch-
  // waehrung die erste plausible in Fremdwaehrung (foreign_listing, gleiche ISIN). Plausi-Pflicht: verified nur mit
  // passender Kurs-Groessenordnung (Owner 2026-10-27; ein ISIN-Treffer allein reicht nicht).
  const matching = wantCcy ? cands.filter(c => c.currency === wantCcy) : cands;
  const pool = matching.length ? matching : cands;
  const best = pool.find(isPlausible) || pool[0];
  const plausible = isPlausible(best);

  // Websuche-Ticker (try_symbols) sind nicht ISIN-gebunden -> eine Fremdwaehrungs-Notierung koennte ein anderes
  // Papier sein: dort nur Treffer in Wunschwaehrung (kein foreign_listing).
  return out({ verified: matching.length > 0 && plausible, provider_symbol: best.symbol,
               market_price: best.price, currency: best.currency, exchange: best.exchange, name: best.name,
               candidates: cands.slice(0, 4), foreign_listing: !tries.length && !!wantCcy && matching.length === 0, plausible: plausible });
} catch (e) {
  return out({});   // jeder Fehler/Yahoo-Ausfall -> roh-Symbol, non-blocking
}
'@
    $resolve = [ordered]@{
        parameters = [ordered]@{ jsCode = $resolveJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(260, 0)
        id = (New-Id); name = 'Resolve'
        onError = 'continueRegularOutput'
    }

    $sticky = Build-Sticky 'Überblick' @(-360, -300) `
        'Yahoo-Symbol-Auflösung (Kauf-Zeit, deterministisch, kein LLM)' `
        'Input { isin, raw_symbol, price_currency, price_per_share, provider_symbol, ref_price/ref_currency, cost_price/cost_currency, fx_rates, try_symbols }. EIN Code-Node, alle HTTP via this.helpers.httpRequest (timeout 3000ms, try/catch -> BEST-EFFORT/NON-BLOCKING: jeder Yahoo-Ausfall liefert {verified:false, provider_symbol:raw}, die Buchung läuft trotzdem). Pfad: KEINE ISIN (Krypto) -> roh; provider_symbol gegeben -> nur dieses prüfen; try_symbols (Websuche-Funde der Kurs-Lücken-Erinnerung) -> genau diese Ticker; sonst Yahoo v1/finance/search?q=ISIN -> Kandidaten -> je Kandidat v8/finance/chart (Preis/Währung/Börse/Name, GBp/Pence->GBP/100). SELEKTOR = Währung == price_currency, darin die erste PLAUSIBLE Notierung. PLAUSI-PFLICHT (Owner 2026-10-27): verified nur mit passender Kurs-Größenordnung — eine von zwei Referenzen muss passen: letzter Kurs (ref_price, Band 0,8-1,25) ODER Kauf-/Einstandskurs (cost_price bzw. price_per_share, Band 0,2-5); ohne Referenz nie verified. Andere Währung als die Referenz: Vergleich in EUR über fx_rates, sonst grob gegen den Kaufkurs. adoptable = darf gespeichert werden (verified oder plausible Fremdwährungs-Notierung derselben ISIN; Websuche-Ticker nie Fremdwährung). Output: { ok, verified, plausible, adoptable, provider_symbol, market_price, currency, exchange, name, candidates[<=4, alle Währungen] }. Aufrufer (book_stock_buy/set_holding/commit_import) zeigen das im HITL + schlagen provider_symbol vor (Owner bestätigt am Gate); tool_verify_price_symbol gibt die Kandidaten an den Agenten (Auswahl-Rückfrage). foreign_listing (2026-10-23): keine Notierung in der Wunschwährung -> bester Kandidat in Fremdwährung derselben ISIN (z. B. SPCX/USD); Aufrufer übernehmen ihn bei plausible, die Bewertung rechnet per FX in EUR um.' 360 820

    $nodes = @($trig, $resolve, $sticky)
    $conns = [ordered]@{ 'Start' = @{ main = @( ,@( E 'Resolve' ) ) } }
    return (Build-Workflow 'agent.finance.sub_resolve_yahoo_symbol' $nodes $conns)
}
