#Requires -Version 5.1
# Definition agent.finance.sub_resolve_yahoo_symbol -> Build-ResolveYahooSymbol. Dot-gesourct von build.ps1.
# Deterministisch, KEIN LLM. Loest beim Kauf (book_stock_buy) / Korrigieren (set_holding) das richtige Yahoo-
# Kurs-Symbol fuer eine ISIN auf, damit der Markt-Preis-Cron (COALESCE(provider_symbol, symbol)) verlaesslich
# trifft. Quelle = Yahoo (wie Portfolio Performance): v1/finance/search?q=ISIN -> Kandidaten -> je Kandidat
# v8/finance/chart (Preis/Waehrung/Boerse; GBp/Pence -> GBP/100). DISAMBIGUIERUNG per Waehrung == price_currency
# (die vom Nutzer mit dem Kaufkurs genannte Waehrung; zuverlaessiger Selektor, kein Preis-Auto-Pick). BEST-EFFORT /
# NON-BLOCKING: alle HTTP in EINEM Code-Node (this.helpers.httpRequest top-level, try/catch, timeout 3000ms) wie der
# Cron; jeder Fehler/Ausfall -> { verified:false, provider_symbol:raw } -> die Buchung laeuft trotzdem. Output flach:
# { ok, verified, provider_symbol, market_price, currency, exchange, candidates, foreign_listing, plausible }.
# foreign_listing (2026-10-23): KEINE Notierung in der Wunschwaehrung, der beste Kandidat notiert in einer anderen
# Waehrung (derselbe ISIN-Treffer, z. B. SPCX/USD fuer eine EUR-Position) -> Aufrufer duerfen ihn bei plausible
# uebernehmen; die Bewertung rechnet per FX in EUR um (depot_holdings_overview).
function Build-ResolveYahooSymbol {
    $trig = Build-Trigger @('isin','raw_symbol','price_currency','price_per_share','provider_symbol') @(0, 0)

    $resolveJs = @'
const isin    = String($('Start').item.json.isin || '').trim();
const raw     = String($('Start').item.json.raw_symbol || '').trim();
const wantCcy = String($('Start').item.json.price_currency || '').trim().toUpperCase();
const buyPx   = Number($('Start').item.json.price_per_share);
const given   = String($('Start').item.json.provider_symbol || '').trim();

// flacher Output mit Defaults (roh-Symbol, nicht verifiziert) -> spread overrides
function out(o) {
  return [{ json: Object.assign(
    { ok: true, verified: false, provider_symbol: raw, market_price: null, currency: null, exchange: null, candidates: [],
      foreign_listing: false, plausible: false }, o) }];
}
// PURE: parst eine Yahoo-Chart-Antwort -> {symbol,price,currency,exchange} | null (Pence GBp -> GBP/100)
function parseChart(res, sym) {
  const r = res && res.chart && res.chart.result && res.chart.result[0];
  const m = r && r.meta ? r.meta : null;
  if (!m) return null;
  let px = Number(m.regularMarketPrice); let ccy = String(m.currency || '');
  if (ccy === 'GBp') { px = px / 100; ccy = 'GBP'; }
  if (!(px > 0) || Number.isNaN(px)) return null;
  return { symbol: sym, price: px, currency: ccy.toUpperCase(), exchange: String(m.exchangeName || m.fullExchangeName || '') };
}
const CHART = (s) => 'https://query1.finance.yahoo.com/v8/finance/chart/' + encodeURIComponent(s)
                   + '?range=1d&interval=1d&lang=en-US&region=US&corsDomain=finance.yahoo.com';

try {
  // (1) Krypto (keine ISIN) -> kein Yahoo-Symbol-Lookup; roh-Symbol, nicht verifiziert.
  if (!isin) return out({});

  // (2) provider_symbol gegeben -> nur DIESES verifizieren (kein ISIN-Search).
  if (given) {
    let c = null;
    try { c = parseChart(await this.helpers.httpRequest({ url: CHART(given), json: true, timeout: 3000 }), given); } catch (e) { c = null; }
    if (c) return out({ verified: (!wantCcy || c.currency === wantCcy), provider_symbol: given,
                        market_price: c.price, currency: c.currency, exchange: c.exchange, candidates: [c] });   // foreign_listing nur aus der ISIN-Suche (nur sie weiss, ob es eine Notierung in Wunschwaehrung gibt)
    return out({ provider_symbol: given });
  }

  // (3) ISIN-Suche -> Kandidaten-Ticker.
  let listings = [];
  try {
    const sres = await this.helpers.httpRequest({
      url: 'https://query1.finance.yahoo.com/v1/finance/search?q=' + encodeURIComponent(isin) + '&quotesCount=8&newsCount=0',
      json: true, timeout: 3000 });
    listings = (sres && sres.quotes ? sres.quotes : []).map(q => q && q.symbol).filter(Boolean);
  } catch (e) { listings = []; }
  if (!listings.length) return out({});

  // (4) je Kandidat (max 6) den Chart -> Preis/Waehrung/Boerse.
  const cands = [];
  for (const sym of listings.slice(0, 6)) {
    try { const c = parseChart(await this.helpers.httpRequest({ url: CHART(sym), json: true, timeout: 3000 }), sym); if (c) cands.push(c); }
    catch (e) { /* einzelner Kandidat-Ausfall -> skip */ }
  }
  if (!cands.length) return out({});

  // (5) Filter/Rank: currency == price_currency zuerst (SELEKTOR); sonst alle. Preis ist NUR Plausi-Anzeige.
  const matching = wantCcy ? cands.filter(c => c.currency === wantCcy) : cands;
  const pool = matching.length ? matching : cands;
  const best = pool[0];

  // Plausi-Check (setzt nur verified/HITL-Hinweis, NIE Selektor): Groessenordnung Kaufkurs vs. Marktkurs.
  // plausible = Groessenordnung per Kaufkurs BESTAETIGT (ohne Kaufkurs false -> keine Fremdwaehrungs-Uebernahme ungeprueft).
  let ratioOk = true;
  if (buyPx > 0 && best.price > 0) { const ratio = best.price / buyPx; ratioOk = (ratio > 0.2 && ratio < 5); }
  const plausible = buyPx > 0 && ratioOk;

  // foreign_listing: keine Notierung in der Wunschwaehrung -> der beste Kandidat in Fremdwaehrung (gleiche ISIN);
  // plausible vergleicht dann Kurs-Groessenordnungen ueber die Waehrungsgrenze (0,2-5 faengt USD/GBP/CHF ab).
  return out({ verified: (matching.length > 0 && ratioOk), provider_symbol: best.symbol,
               market_price: best.price, currency: best.currency, exchange: best.exchange, candidates: cands.slice(0, 4),
               foreign_listing: !!wantCcy && matching.length === 0, plausible: plausible });
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
        'Input { isin, raw_symbol, price_currency, price_per_share, provider_symbol }. EIN Code-Node, alle HTTP via this.helpers.httpRequest (timeout 3000ms, try/catch -> BEST-EFFORT/NON-BLOCKING: jeder Yahoo-Ausfall liefert {verified:false, provider_symbol:raw}, die Buchung läuft trotzdem). Pfad: KEINE ISIN (Krypto) -> roh; provider_symbol gegeben -> nur dieses verifizieren; sonst Yahoo v1/finance/search?q=ISIN -> Kandidaten -> je Kandidat v8/finance/chart (Preis/Währung/Börse, GBp/Pence->GBP/100). SELEKTOR = Währung == price_currency (die mit dem Kaufkurs genannte Währung); der Kaufkurs ist NUR Plausi-Anzeige (Größenordnung -> verified-Flag), NIE Selektor. Output: { ok, verified, provider_symbol, market_price, currency, exchange, candidates[<=4, alle Währungen] }. Aufrufer (book_stock_buy/set_holding/commit_import) zeigen das im HITL + schlagen provider_symbol vor (Owner bestätigt am Gate); tool_verify_price_symbol gibt die Kandidaten an den Agenten (Auswahl-Rückfrage). foreign_listing (2026-10-23): keine Notierung in der Wunschwährung -> bester Kandidat in Fremdwährung derselben ISIN (z. B. SPCX/USD); Aufrufer übernehmen ihn bei plausible, die Bewertung rechnet per FX in EUR um.' 360 820

    $nodes = @($trig, $resolve, $sticky)
    $conns = [ordered]@{ 'Start' = @{ main = @( ,@( E 'Resolve' ) ) } }
    return (Build-Workflow 'agent.finance.sub_resolve_yahoo_symbol' $nodes $conns)
}
