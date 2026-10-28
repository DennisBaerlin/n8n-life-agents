-- ============================================================
-- finance.fn_advisor_review (WS2 — paket-besessener Review/Drift-Rechner der Core-Advisor-Engine)
--   Vom generischen Core-Wrapper core.fn_advisor_review_evaluate(domain) ueber die Registry
--   core.advisors GENERISCH dispatcht (domain='finance' -> diese fn). Rechnet die finance-spezifische
--   Soll-Ist-Drift + Staleness (alerts[], gelatcht vom Core-Wrapper) UND den unbedingten Quartals-
--   Voll-Digest (digest) aus den finance-Views + den publizierten Core-DEFINER-Fenstern.
--
--   WS2a = buchwert-immune Metriken (Sparziel-Pace, Notreserve, Plan-Staleness).
--   Phase A = zwei zusaetzliche Staleness-Nudges: tax_year_staleness (Plan im Vorjahr bestaetigt -> neues
--     Steuerjahr; Bool-Toggle advisor.tax_year_nudge default-ON) + risk_profile_staleness (risk_profile.as_of
--     aelter als advisor.risk_profile_stale_days, default 365). Beide gelatcht ueber den Core-Wrapper.
--   WS2b = MARKTWERT-Metriken via finance.networth_by_asset_class + finance.market_prices:
--     - per-Block-Allokations-Drift (NUR handelbar: Depot-Positionen + Cash netto; Immobilie/Vorsorge/p2p
--       NIE im Drift -> non_rebalanceable_targets), Soll = target_allocation.blocks[] gejoint auf den
--       STABILEN Block-`key` (== depot_holdings.asset_class; arch-challenge Candidate 1);
--     - Zielportfolio-Drift (goal.target_portfolio_eur vs. Marktwert Depot+Cash-netto-Schulden);
--     - Pflicht-Advisory-Sektionen unmapped/null_tag/null_price + price_as_of/Stale (advisor.price_stale_days).
--   WS3 = FIRE-Topf-Semantik (Owner 2026-06-22): goal.target_portfolio_basis steuert den Zielportfolio-Topf —
--     'investment' (Default) = Depot+Cash+Festgeld+P2P - Depot-Earmarks, OHNE Hypothek/Haus/Rente; 'net_worth'
--     = zusaetzlich Immobilien + alle Kredite (Audit Paket 3, symmetrisch); ELSE-Fail-Safe = investment. Festgeld ist seit der View-Trennung
--     eine eigene NICHT-handelbare Klasse (im Topf, raus aus dem Rebalancing-Drift; Plan-Block dafuer ->
--     non_rebalanceable_targets). P2P zaehlt zum Nennwert (imprecise-Hinweis im Digest).
--   Phase L = Cashflow-/Liquiditaets-FLUSS-Checks (kein Plan-Fakt noetig), beide aus finance.monthly_cashflow_summary
--     (Audit Paket 3: Konsum/Tilgung/Sparen getrennt): cashflow_coverage = hart monthly_free<0 (Pflichtausgaben =
--     Konsum + Kreditrate uebersteigen die Einnahmen) + sanfter Puffer advisor.cashflow_buffer_pct/_nudge;
--     savings_squeeze = monthly_free>=0 ABER Sparen>0 und monthly_account_change<0 (Sparraten leeren das Girokonto;
--     advisor.savings_squeeze_nudge). Guard monthly_income>0. has_fx_gap -> Zusatzsatz "unvollstaendig".
--   Audit Paket 3: Notreserve-Cash + Monatsbasis aus finance.fn_liquidity_snapshot (freies Cash ohne Kinderkonten
--     und Sparziel-Ruecklagen; Pflichtausgaben ohne Sparraten). Zielmix-Drift normiert die Soll-Anteile der
--     handelbaren Bloecke auf deren Summe; der Ist-Nenner sind nur handelbare Klassen MIT Plan-Block (Cash als
--     freies Cash). net_worth-Basis zaehlt die Immobilie (symmetrisch mit ihrem Kredit). Sparziel ohne Topf ->
--     savings_goal_unmeasurable statt savings_pace.
--   Monats-Check (WP-E): account_coverage:<konto> = Deckungs-Vorschau (finance.fn_account_outlook) unterschreitet
--     den Puffer finance.coverage_buffer_eur, nur Konten mit Kontoauszug; recurring_missing:<ketten-kopf> = die
--     juengsten zwei Termine einer laufenden Dauerauftrags-Kette hat ein Kontoauszug als fehlend festgestellt.
--   Instandhaltungsruecklage (2026-10-27, aus finance.maintenance_reserve_status): maintenance_reserve_low:<immobilie>
--     = eingestellte Rate (Kopf der Kette) einer aktiven Immobilie unter der Empfehlung nach II. BV (latch_keys
--     Stufe:Satz -> Stufen-/Satzwechsel meldet erneut; ohne Kurs NULL -> keine Meldung);
--     maintenance_reserve_missing:<immobilie> = aktive Immobilie ohne aktive Ruecklage (einmal). Digest: Ruecklage als
--     digest_maintenance_line (Stand + Rate) statt Prozent-Zeile; savings_pace/goal_reached entfallen (kein Ziel).
--
--   PARTIAL-TOLERANT: jeder Soll-Block optional; fehlt der Plan/das Fakt, entfaellt die Metrik still
--   (kein Crash, leeres alerts moeglich). Robust bei leeren Live-Daten.
--
--   ROLLEN-PFAD: aufgerufen vom Core-Wrapper unter dem Haupt-RW-Credential -> erreicht finance.*-Views
--   direkt; agent.* NUR ueber die publizierten Fenster core.fn_advisor_read_plan / fn_monitor_trigger_
--   summary (eine finance-schema-fn liest agent.* nicht direkt). STABLE/INVOKER.
--
--   GENERIK-VERTRAG (Textkatalog Phase C): jeder alert traegt 'msg' = [tpl…] (Saetze, mit Leerzeichen verbunden;
--   null-Elemente = entfallene Teilsaetze), der digest 'lines' = [tpl | [tpl…] | null(Leerzeile)…]; tpl =
--   {kind:'tpl', value:<finance.advisor.*-Key>, params:{typisierte Rohwerte}} (core.fn_ui_tpl/fn_ui_money/fn_ui_num/
--   fn_ui_date). Die generischen Core-Crons kennen KEINE finance-Felder: sie rendern die Struktur in der Sprache
--   des Empfaengers (Zahlen per Intl), das LLM formuliert um. 'label' ist englisch-technisch (keine Anzeige).
--
--   RUECKGABE jsonb: { alerts:[{metric_key,kind,value,target,drift,label,msg}], digest:{…Rohwerte, lines},
--     net_worth_by_class:[…], rebalanceable_drift:[…], non_rebalanceable_targets:[…],
--     advisories:{unmapped:[…], null_tag:[…], null_price:[…], price_as_of, price_stale} }
--   Anwenden via: db_apply.ps1 -File packages\finance\db\migrations\R__fn_advisor_review.sql
-- ============================================================
-- P2a: uniform 3-arg-Dispatch des Core-Wrappers (core.fn_advisor_review_evaluate dispatcht ALLE review-fns mit
--   (domain, person_id, observations)). finance ist HAUSHALT und IGNORIERT p_person_id (0 Verhaltensaenderung) —
--   die Signatur ist nur die uniforme Plugin-Schnittstelle (Rule of Three; keine scope-konditionale Aritaet).
CREATE OR REPLACE FUNCTION finance.fn_advisor_review(p_domain text, p_person_id text DEFAULT NULL, p_observations jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_facts        jsonb;
    v_er           jsonb;
    v_goal         jsonb;
    v_alloc        jsonb;
    v_alerts       jsonb := '[]'::jsonb;
    v_digest       jsonb;
    v_stale_days   numeric;
    v_drift_tol    numeric;
    v_cash_eur     numeric;
    v_er_target    numeric;
    v_mon_exp      numeric;
    v_last_conf    text;
    v_stale_age    numeric;
    r              record;
    -- WS2b
    v_trade_total  numeric;
    v_nwbc         jsonb := '[]'::jsonb;
    v_reb          jsonb := '[]'::jsonb;
    v_non_reb      jsonb := '[]'::jsonb;
    v_unmapped     jsonb := '[]'::jsonb;
    v_null_tag     jsonb := '[]'::jsonb;
    v_null_price   jsonb := '[]'::jsonb;
    v_null_rate    jsonb := '[]'::jsonb;   -- WP-3c: in Nutzung befindliche Fremdwaehrungen OHNE FX-Kurs
    v_null_tag_cnt int := 0;
    v_null_price_cnt int := 0;
    v_null_rate_cnt int := 0;
    v_price_asof   date;
    v_price_stale  boolean := false;
    v_blk          jsonb;
    v_bkey         text;
    v_btgt         numeric;
    v_cls_val      numeric;
    v_act_pct      numeric;
    v_drift        numeric;
    v_lo           numeric;
    v_hi           numeric;
    v_breach       boolean;
    v_tp_target    numeric;
    v_portfolio    numeric;
    v_dq_msg       jsonb;     -- Daten-Hinweis (Alert + Digest-Zeile), NULL = keine Luecke
    v_lines        jsonb;     -- Digest-Zeilen-Struktur
    -- WS-C3: Reserve-Coverage (Engpass)
    v_rc_cnt       int := 0;
    v_rc_eur       numeric;
    v_rc_txt       text;
    -- WS-B Stufe 3: Reserve-Aufschluesselung Cash/Depot je Konto (Digest)
    v_reserve_bd   jsonb;
    -- Audit Paket 3
    v_snap         jsonb;     -- finance.fn_liquidity_snapshot(): freies Cash + Pflicht-Basis (eine Adresse)
    v_cf           record;    -- finance.monthly_cashflow_summary (Konsum/Tilgung/Sparen getrennt)
    v_cls          jsonb := '{}'::jsonb;   -- handelbare Klasse -> Wert (ohne Kind; cash = freies Cash)
    v_tgt_trade_sum numeric;  -- Summe der Soll-Anteile handelbarer Bloecke (Normierungs-Basis)
    v_btgt_raw     numeric;
    v_outside      numeric;   -- handelbarer Wert OHNE Plan-Block (nicht im Drift-Nenner)
    v_re_missing   boolean := false;   -- Immobilie mit Kredit, aber ohne Wert (net_worth unvollstaendig)
    v_nw_fx_gap    boolean := false;   -- ein Wert der Zielportfolio-Basis ohne Wechselkurs (Summe unvollstaendig)
BEGIN
    -- Soll: financial_planning-Fakten-Sidecar (fehlt -> v_facts NULL -> Plan-Metriken entfallen still)
    SELECT c.metadata->'facts' INTO v_facts
    FROM agent.core_contexts c
    WHERE c.name = 'financial_planning';
    v_goal  := finance.fn_plan_goal_resolved(v_facts->'goal');   -- WP2: abgeleiteter dritter Zielwert (z. B. Zielportfolio)
    v_alloc := v_facts->'target_allocation';

    -- Tunbare Schwellen aus core.config ueber das generische DEFINER-Lesefenster core.fn_config_get
    -- (paket-rollen-sicher, konsistent mit F9; COALESCE-Defaults bleiben). Advisor-Config wohnt im Paket 'core'.
    v_stale_days       := COALESCE(core.fn_config_get('core', 'advisor', 'plan_stale_days')::numeric, 365);
    -- Allokations-Toleranz: aus dem Plan (target_allocation.rebalance_drift_pp), Default 5pp.
    v_drift_tol := COALESCE(NULLIF(v_alloc->>'rebalance_drift_pp','')::numeric, 5);
    -- Audit Paket 3: eine Lese-Adresse fuer freies Cash/Pflicht-Basis und fuer den Monats-Cashflow.
    v_snap := finance.fn_liquidity_snapshot();
    SELECT * INTO v_cf FROM finance.monthly_cashflow_summary;

    -- ---------- (1) Sparziel-Pace-Drift (buchwert-immun; Fakten aus der View) ----------
    -- WS-1: expected/pace/projected/catchup rechnet finance.savings_goal_progress (ein Fakt, eine Adresse);
    -- hier nur die Meldung. pace_drift_pp IS NOT NULL == (Zieldatum nach created_at) == der frueheren v_total>0-Guard.
    -- "hinter Plan" (Toleranz core/advisor/drift_pace_pp) entscheidet finance.fn_savings_goal_pace — dieselbe Regel wie die
    -- Ampel der Mini-App (2026-10-28). Abfrage bewusst unveraendert (Reihenfolge der Alerts), nur die Bedingung wechselt.
    FOR r IN
        SELECT p.name,
               COALESCE(p.progress_percent, 0)                      AS prog,
               p.expected_percent                                   AS exp,
               p.pace_drift_pp                                      AS drift,
               p.projected_completion_date                          AS projected,
               p.required_catchup_rate                              AS catchup,
               finance.fn_savings_goal_pace(p.id)                   AS pace
        FROM finance.savings_goal_progress p
        WHERE p.status = 'active' AND p.pace_drift_pp IS NOT NULL
    LOOP
        IF r.pace = 'behind' THEN
            v_alerts := v_alerts || jsonb_build_object(
                'metric_key', 'savings_goal:' || r.name,
                'kind',       'savings_pace',
                'label',      r.name,
                'value',      r.prog,
                'target',     round(r.exp, 2),
                'drift',      r.drift,
                'msg',        jsonb_build_array(
                                  core.fn_ui_tpl('finance.advisor.savings_pace', jsonb_build_object(
                                      'name', r.name, 'drift', core.fn_ui_num(r.drift, 1),
                                      'progress', core.fn_ui_num(r.prog), 'expected', core.fn_ui_num(r.exp))),
                                  CASE WHEN r.catchup IS NOT NULL
                                       THEN core.fn_ui_tpl('finance.advisor.savings_pace_catchup',
                                                jsonb_build_object('rate', core.fn_ui_money(r.catchup))) END,
                                  CASE WHEN r.projected IS NOT NULL
                                       THEN core.fn_ui_tpl('finance.advisor.savings_pace_projected',
                                                jsonb_build_object('date', core.fn_ui_date(r.projected))) END));
        END IF;
    END LOOP;

    -- ---------- Audit Paket 3: Sparziel nicht messbar (laufende Rate ohne Topf) ----------
    -- Die Rate geht als nackte Abbuchung unverfolgt vom Konto ab -> savings_goal_progress liefert dann keine Pace
    -- (pace_drift_pp NULL, der Pace-Alert oben entfaellt). Statt Dauer-"hinter Plan" EIN gelatchter Hinweis mit dem
    -- Hebel: Sparkonto zuordnen (tool_set_savings_goal mit Reserve-Konto).
    FOR r IN
        SELECT p.name FROM finance.savings_goal_progress p
        WHERE p.status = 'active' AND NOT p.progress_measurable
    LOOP
        v_alerts := v_alerts || jsonb_build_object(
            'metric_key', 'savings_goal_unmeasurable:' || r.name,
            'kind',       'savings_goal_unmeasurable',
            'label',      r.name,
            'msg',        jsonb_build_array(core.fn_ui_tpl('finance.advisor.savings_goal_unmeasurable',
                              jsonb_build_object('name', r.name))));
    END LOOP;

    -- ---------- WS-B Stufe 3: Uebererfuellt-Zweig (erreicht/uebertroffen, ORTHOGONAL zum Pace-Alert) ----------
    -- Owner-Korrektur "erreicht != ausgegeben": ein voll gefuelltes Ziel meldet sich AKTIV, OHNE Auto-Abschluss
    -- und OHNE Auto-Freigabe — der Betrag bleibt reserviert, bis der Owner ihn verwendet. Feuert NUR bei
    -- current_amount >= target (nicht bei "hinter Plan"; das ist der Pace-Alert oben). Nicht bei einem Ziel, das allein
    -- durch Hand-Zuordnung gedeckt ist (earmarked_amount >= current_amount): die Karte der Zuordnung/Anlage hat die
    -- Deckung schon gemeldet, ein Morgen-Alert waere Rauschen (Sparziel-Zweckbindung 2026-10-27).
    FOR r IN
        SELECT p.name,
               COALESCE(p.current_amount, 0) AS saved,
               p.target_amount               AS target
        FROM finance.savings_goal_progress p
        WHERE p.status = 'active' AND p.target_amount > 0 AND COALESCE(p.current_amount, 0) >= p.target_amount
          AND COALESCE(p.current_amount, 0) > COALESCE(p.earmarked_amount, 0)
    LOOP
        v_alerts := v_alerts || jsonb_build_object(
            'metric_key', 'savings_goal_reached:' || r.name,
            'kind',       'savings_goal_reached',
            'label',      r.name,
            'value',      round(r.saved, 2),
            'target',     round(r.target, 2),
            'msg',        jsonb_build_array(core.fn_ui_tpl(
                              CASE WHEN r.saved > r.target THEN 'finance.advisor.goal_exceeded'
                                   ELSE 'finance.advisor.goal_reached' END,
                              jsonb_build_object('name', r.name, 'saved', core.fn_ui_money(r.saved),
                                                 'target', core.fn_ui_money(r.target)))));
    END LOOP;

    -- ---------- (2) Notreserve-Drift (buchwert-immun: Cash zu Nennwert) ----------
    -- Audit Paket 3: freies Cash (ohne Kinderkonten + Sparziel-Ruecklagen) und Pflicht-Basis (Konsum + Kreditrate,
    -- ohne Sparraten) aus fn_liquidity_snapshot -> dieselben Zahlen wie die career-Runway.
    IF v_facts IS NOT NULL AND jsonb_typeof(v_facts->'emergency_reserve') = 'object' THEN
        v_er := v_facts->'emergency_reserve';
        v_cash_eur := COALESCE((v_snap->>'cash_eur')::numeric, 0);
        IF (v_er ? 'target_eur') AND jsonb_typeof(v_er->'target_eur') = 'number' THEN
            v_er_target := (v_er->>'target_eur')::numeric;
        ELSIF (v_er ? 'target_months') AND jsonb_typeof(v_er->'target_months') = 'number' THEN
            v_mon_exp := COALESCE((v_snap->>'monthly_expenses_eur')::numeric, 0);
            v_er_target := (v_er->>'target_months')::numeric * v_mon_exp;
        END IF;
        IF v_er_target IS NOT NULL AND v_er_target > 0 AND v_cash_eur < v_er_target THEN
            v_alerts := v_alerts || jsonb_build_object(
                'metric_key', 'emergency_reserve',
                'kind',       'emergency_reserve',
                'label',      'emergency_reserve',
                'value',      round(v_cash_eur, 2),
                'target',     round(v_er_target, 2),
                'drift',      round(v_er_target - v_cash_eur, 2),
                'msg',        jsonb_build_array(core.fn_ui_tpl('finance.advisor.emergency_reserve', jsonb_build_object(
                                  'cash', core.fn_ui_money(v_cash_eur), 'target', core.fn_ui_money(v_er_target),
                                  'gap', core.fn_ui_money(v_er_target - v_cash_eur)))));
        END IF;
    END IF;

    -- ---------- WS-C3: Reserve-Coverage (Engpass-Beratung) ----------
    -- Konten, deren live-Saldo die fuer aktive Sparziele getaggte Reserve NICHT mehr deckt (account_reserve_status.
    -- breach). ORTHOGONAL zum emergency_reserve-Alert oben (aggregiertes Cash vs. Plan-Ziel) — hier per-Konto
    -- Saldo vs. getaggte Ziel-Reserve; bei einem als Sparziel modellierten Notgroschen koennen beide dieselben
    -- Euro betreffen (Single-User: akzeptierte niedrige Frequenz, zwei Linsen). GESCHICHTET: der Wächter meldet
    -- ECHTZEIT beim Buchen (Finance-Agent, reserve_breach-Fold); dies ist die PERIODISCHE Bestandsaufnahme im
    -- Advisor-Review. Gelatcht ueber den Core-Wrapper (stabiler metric_key 'reserve_coverage').
    -- Feuert auf den BREACH-COUNT (nicht die EUR-Summe): ein fehlender FX-Kurs (fn_to_eur NULL) darf den Alert
    -- nicht unterdruecken -> die EUR-Zahl ist best-effort (COALESCE), der Count ist das Gate.
    SELECT count(*)::int,
           COALESCE(sum(finance.fn_to_eur(s.shortfall, s.currency)), 0),
           string_agg(s.account_name, ', ' ORDER BY s.account_name)
    INTO v_rc_cnt, v_rc_eur, v_rc_txt
    FROM finance.account_reserve_status s WHERE s.breach;
    IF v_rc_cnt > 0 THEN
        v_alerts := v_alerts || jsonb_build_object(
            'metric_key', 'reserve_coverage',
            'kind',       'reserve_coverage',
            'label',      'reserve_coverage',
            'value',      round(v_rc_eur, 2),
            'msg',        jsonb_build_array(
                              core.fn_ui_tpl('finance.advisor.reserve_coverage', jsonb_build_object('accounts', v_rc_txt)),
                              CASE WHEN v_rc_eur > 0
                                   THEN core.fn_ui_tpl('finance.advisor.reserve_coverage_gap',
                                            jsonb_build_object('gap', core.fn_ui_money(v_rc_eur))) END,
                              core.fn_ui_tpl('finance.advisor.reserve_coverage_levers')));
    END IF;

    -- ---------- WS-B Stufe 3: Depot-Deckungs-Dialog mit PACE-bewusster Smart-Unterdrueckung ----------
    -- Je breached Depot (depot_reserve_status: Marktwert < Σ Reserve-Journal aktiver Ziele) pruefen wir die
    -- ZIELE, die dagegen reserviert haben. Der deterministische Waechter (fn_reserve_breach) bleibt dumm; die
    -- pace-bewusste Unterdrueckung lebt HIER (cron-vs-trigger-Gesetz). Alarmiere nur, wenn mindestens ein Ziel
    -- auf dem Depot NICHT on-pace ist — d. h. die LAUFENDE (konfigurierte) Sparrate schliesst die Luecke nicht
    -- rechtzeitig: on_pace := required_catchup_rate <= laufende Rate ODER projected_completion_date <= target_date
    -- (ODER bereits gedeckt, catchup NULL). "laufende Rate" = Σ abs(monthly_equivalent) der AKTIVEN Funder
    -- (Cash-rp + verknuepfte Sparplaene) — bewusst die konfigurierte VORWAERTS-Rate, NICHT observed_monthly_rate
    -- (sonst waeren beide Disjunkte identisch). Ist ein Ziel on-pace, ist die Markt-Delle ein Transient -> still.
    FOR r IN
        WITH per_goal AS (
            SELECT d.account_id, d.account_name, d.market_value, d.reserved, d.shortfall, d.fx_missing,
                   g.name AS goal_name, g.required_catchup_rate AS catchup, g.progress_measurable AS measurable,
                   g.projected_completion_date AS projected, g.target_date AS target_date,
                   -- Audit Paket 3: die HEUTE laufenden Glieder der Ketten (Ziel-Rate + Sparplaene) — eine in die
                   -- Zukunft datierte neue Rate (Kopf) zaehlt erst ab ihrem valid_from.
                   (SELECT COALESCE(sum(abs(rp.monthly_equivalent)), 0)
                    FROM finance.recurring_payments rp
                    WHERE rp.status = 'active'
                      AND rp.valid_from <= current_date
                      AND (rp.valid_to IS NULL OR rp.valid_to > current_date)
                      AND (rp.id IN (SELECT finance.fn_recurring_lineage(g.recurring_payment_id))
                           OR rp.id IN (SELECT finance.fn_recurring_lineage(sp.recurring_payment_id)
                                        FROM finance.savings_plans sp
                                        WHERE sp.savings_goal_id = g.id AND sp.status = 'active'))) AS run_rate,
                   -- WP-3c: FX-Caveat auch bei Fremd-QUOTE-Waehrung (EUR-gefuehrte Position, US-Listing in USD) —
                   -- nicht nur bei fremder Holding-Waehrung. Der globale null_rate-Advisory meldet zusaetzlich, WELCHE
                   -- Waehrung gar keinen Kurs hat (Deckung dann unvollstaendig statt still 0).
                   EXISTS (SELECT 1 FROM finance.depot_holdings h
                           WHERE h.account_id = d.account_id AND h.shares > 0
                             AND (h.currency <> 'EUR' OR (h.quote_currency IS NOT NULL AND h.quote_currency <> 'EUR'))) AS fx_flag
            FROM finance.depot_reserve_status d
            -- DISTINCT (Ziel, Depot): das Journal ist APPEND-ONLY (k Zeilen je Paar) -> einmal je Ziel/Depot
            -- joinen, sonst liefe die run_rate-Subquery k-fach (Aggregat-Ergebnis bliebe gleich, nur teurer).
            JOIN (SELECT DISTINCT savings_goal_id, account_id FROM finance.savings_goal_reserve_entries) e
                 ON e.account_id = d.account_id
            JOIN finance.savings_goal_progress g ON g.id = e.savings_goal_id
            WHERE d.breach AND g.status = 'active'
        ),
        marked AS (
            -- Audit Paket 3: ein nicht messbares Ziel (laufende Rate ohne Topf -> catchup/projected NULL) gilt NIE als
            -- on-pace -> die Depot-Unterdeckung meldet sich (fail-loud statt still unterdrueckt).
            SELECT *,
                   (measurable AND (catchup IS NULL OR catchup <= run_rate
                    OR (projected IS NOT NULL AND projected <= target_date))) AS on_pace
            FROM per_goal
        )
        SELECT account_id, account_name,
               max(market_value) AS market_value, max(reserved) AS reserved, max(shortfall) AS shortfall,
               string_agg(DISTINCT goal_name, ', ' ORDER BY goal_name) FILTER (WHERE NOT on_pace) AS behind_goals,
               bool_or(fx_flag) AS has_fx, bool_or(fx_missing) AS any_fx_missing
        FROM marked
        GROUP BY account_id, account_name
        HAVING bool_or(NOT on_pace)
    LOOP
        v_alerts := v_alerts || jsonb_build_object(
            'metric_key', 'depot_reserve_coverage:' || r.account_id,
            'kind',       'reserve_coverage_depot',
            'label',      'reserve_coverage_depot',
            'value',      round(COALESCE(r.market_value, 0), 2),
            'target',     round(r.reserved, 2),
            'drift',      round(r.shortfall, 2),
            'msg',        jsonb_build_array(
                              core.fn_ui_tpl('finance.advisor.depot_reserve', jsonb_build_object(
                                  'goals', r.behind_goals, 'account', r.account_name,
                                  'reserved', core.fn_ui_money(r.reserved),
                                  'market', core.fn_ui_money(COALESCE(r.market_value, 0)),
                                  'gap', core.fn_ui_money(r.shortfall))),
                              CASE WHEN r.any_fx_missing THEN core.fn_ui_tpl('finance.advisor.depot_reserve_fx_missing')
                                   WHEN r.has_fx        THEN core.fn_ui_tpl('finance.advisor.depot_reserve_fx_note') END));
    END LOOP;

    -- ---------- (2b') Umschicht-Hilfe vor dem Zieldatum (Glide Path, Sparziel-Zweckbindung 2026-10-27) ----------
    -- Je aktivem Ziel, das im Fenster (Owner: 60 Monate) mehr Depot-Geld traegt als der Pfad erlaubt (+ Toleranz):
    -- Vorschlagsbetrag (drift = Ueberschuss) zum Umschichten aufs Konto, bei aktivem Sparplan zusaetzlich "pausieren oder
    -- umleiten" (sonst kauft er weiter ins Depot), dazu der Steuer-Hinweis. Die Rechnung lebt allein in
    -- finance.fn_savings_goal_derisk_status (das LLM rechnet nicht). latch_keys = Restjahr: der Edge-Latch meldet
    -- einmal je verbleibendem Jahr erneut, solange ein Ueberschuss besteht (der Vorschlag bleibt aktuell).
    FOR r IN
        SELECT * FROM finance.fn_savings_goal_derisk_status() s WHERE s.breach
    LOOP
        v_alerts := v_alerts || jsonb_build_object(
            'metric_key', 'savings_goal_derisk:' || r.goal_id,
            'kind',       'savings_goal_derisk',
            'label',      r.name,
            'value',      r.depot_share_eur,
            'target',     r.allowed_depot_eur,
            'drift',      r.excess_eur,
            'latch_keys', jsonb_build_array('y' || ceil(r.months_left / 12.0)::int),
            'msg',        jsonb_build_array(
                              core.fn_ui_tpl('finance.advisor.goal_derisk', jsonb_build_object(
                                  'name', r.name, 'date', core.fn_ui_date(r.target_date),
                                  'depot', core.fn_ui_money(r.depot_share_eur),
                                  'allowed', core.fn_ui_money(r.allowed_depot_eur),
                                  'excess', core.fn_ui_money(r.excess_eur))),
                              CASE WHEN r.active_plan THEN core.fn_ui_tpl('finance.advisor.goal_derisk_plan') END,
                              core.fn_ui_tpl('finance.advisor.goal_derisk_tax')));
    END LOOP;

    -- ---------- (2c) Monats-Check: Konto-Deckung bis zum naechsten Geldeingang ----------
    -- Nur Konten aus finance.fn_coverage_accounts (cash, aktiv, >= 1 Kontoauszug; ohne Auszug fehlt die Alltags-
    -- Schaetzung -> keine Warnung auf Halbwissen). Die Rechnung lebt allein in finance.fn_account_outlook (eine Adresse,
    -- auch fuer die Tool-Antwort und die Mini-App). Gelatcht ueber den Core-Wrapper (stabiler metric_key je Konto).
    FOR r IN
        SELECT x.o
        FROM (SELECT finance.fn_account_outlook(c.id) AS o
              FROM finance.fn_coverage_accounts() c(id)) x
        WHERE (x.o->>'ok')::boolean AND (x.o->>'shortfall')::numeric > 0
    LOOP
        v_alerts := v_alerts || jsonb_build_object(
            'metric_key', 'account_coverage:' || (r.o->>'account_id'),
            'kind',       'account_coverage',
            'label',      'account_coverage',
            'value',      (r.o->>'min_projected')::numeric,
            'target',     (r.o->>'buffer')::numeric,
            'drift',      (r.o->>'shortfall')::numeric,
            'msg',        jsonb_build_array(
                              core.fn_ui_tpl('finance.advisor.account_coverage', jsonb_build_object(
                                  'account', r.o->>'account_name',
                                  'min',     core.fn_ui_money((r.o->>'min_projected')::numeric, r.o->>'currency'),
                                  'date',    core.fn_ui_date((r.o->>'min_date')::date),
                                  'buffer',  core.fn_ui_money((r.o->>'buffer')::numeric, r.o->>'currency'))),
                              CASE WHEN jsonb_typeof(r.o->'suggestion') = 'object' THEN
                                  core.fn_ui_tpl('finance.advisor.account_coverage_suggest', jsonb_build_object(
                                      'amount', core.fn_ui_money((r.o->'suggestion'->>'amount')::numeric, r.o->>'currency'),
                                      'from',   r.o->'suggestion'->>'from_account',
                                      'date',   core.fn_ui_date((r.o->'suggestion'->>'by_date')::date))) END));
    END LOOP;

    -- ---------- (2e) Instandhaltungsruecklage (2026-10-27) ----------
    -- Rechnung allein in finance.maintenance_reserve_status (Empfehlung nach II. BV, laufende Rate in EUR ueber die
    -- Kette). low: laufende Rate < Empfehlung; latch_keys = Stufe:Satz -> ein Stufenwechsel (22/32 Jahre) oder neue
    -- II.-BV-Saetze melden erneut. missing: aktive Immobilie ohne aktive Ruecklage, einmal je Immobilie (mit
    -- Empfehlung, ohne Flaeche/Baujahr die Daten-Variante).
    FOR r IN
        SELECT * FROM finance.maintenance_reserve_status
        WHERE goal_id IS NOT NULL AND property_status = 'active' AND recommended_monthly IS NOT NULL
          AND running_monthly_eur < recommended_monthly   -- NULL (kein Kurs) meldet nicht falsch
    LOOP
        v_alerts := v_alerts || jsonb_build_object(
            'metric_key', 'maintenance_reserve_low:' || r.real_estate_id,
            'kind',       'maintenance_reserve_low',
            'label',      'maintenance reserve below II. BV recommendation',
            'value',      r.running_monthly_eur,
            'target',     r.recommended_monthly,
            'drift',      r.gap_monthly_eur,
            'latch_keys', jsonb_build_array(r.band || ':' || r.rate_eur_m2::text),
            'msg',        jsonb_build_array(core.fn_ui_tpl('finance.advisor.maintenance_reserve_low', jsonb_build_object(
                              'property', r.real_estate_name,
                              'rate',     core.fn_ui_money(r.running_monthly_eur),
                              'recommended', core.fn_ui_money(r.recommended_monthly),
                              'rate_m2',  core.fn_ui_money(r.rate_eur_m2),
                              'age',      core.fn_ui_num(r.age_years)))));
    END LOOP;
    FOR r IN
        SELECT * FROM finance.maintenance_reserve_status WHERE goal_id IS NULL
    LOOP
        v_alerts := v_alerts || jsonb_build_object(
            'metric_key', 'maintenance_reserve_missing:' || r.real_estate_id,
            'kind',       'maintenance_reserve_missing',
            'label',      'property without maintenance reserve',
            'value',      0,
            'target',     r.recommended_monthly,
            'drift',      r.recommended_monthly,
            'msg',        jsonb_build_array(CASE WHEN r.recommended_monthly IS NOT NULL
                              THEN core.fn_ui_tpl('finance.advisor.maintenance_reserve_missing', jsonb_build_object(
                                       'property', r.real_estate_name, 'recommended', core.fn_ui_money(r.recommended_monthly)))
                              ELSE core.fn_ui_tpl('finance.advisor.maintenance_reserve_missing_data', jsonb_build_object(
                                       'property', r.real_estate_name)) END));
    END LOOP;

    -- ---------- (2d) Monats-Check: Dauerauftrag zweimal in Folge nicht gekommen ----------
    -- Die juengsten zwei Termine (<= heute) einer laufenden Kette sind beide von einem Kontoauszug als fehlend
    -- festgestellt -> vermutlich gekuendigt oder Anbieter gewechselt. Zaehlt NUR Skips, die ein Auszug in seinem Zeitraum
    -- erzeugt hat (bank_statements.skipped): ein Saldo-Abgleich per Chat ueberspringt offene Termine im Sinne von "im
    -- bestaetigten Stand enthalten", ein manueller Skip ist eine Nutzer-Entscheidung — beides ist kein Fehlen (Review-
    -- Befund). Key = Ketten-Kopf (split-/reopen-fest). Transfer-Beine teilen die Faelligkeit -> UNION dedupliziert.
    FOR r IN
        WITH heads AS (
            SELECT DISTINCT finance.fn_recurring_lineage_head(id) AS head FROM finance.active_recurring_payments
        ), ev AS (
            SELECT h.head, s.due_date AS d, true AS skipped
            FROM heads h
            JOIN finance.recurring_payment_skips s ON s.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(h.head))
            WHERE s.due_date <= current_date
              AND EXISTS (SELECT 1 FROM finance.bank_statements b
                          WHERE s.due_date BETWEEN b.period_start - 10 AND b.period_end
                            AND b.skipped @> jsonb_build_array(jsonb_build_object(
                                    'recurring_payment_id', s.recurring_payment_id, 'due_date', s.due_date)))
            UNION
            SELECT h.head, t.recurring_due_date, false
            FROM heads h
            JOIN finance.transactions t ON t.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(h.head))
            WHERE t.recurring_due_date <= current_date
        ), ranked AS (
            SELECT head, d, skipped, row_number() OVER (PARTITION BY head ORDER BY d DESC, skipped) AS rn FROM ev
        )
        SELECT k.head, rp.name, rp.amount, a.currency, max(k.d) AS last_due
        FROM ranked k
        JOIN finance.recurring_payments rp ON rp.id = k.head
        JOIN finance.accounts a ON a.id = rp.account_id
        WHERE k.rn <= 2
        GROUP BY k.head, rp.name, rp.amount, a.currency
        HAVING count(*) = 2 AND bool_and(k.skipped)
    LOOP
        v_alerts := v_alerts || jsonb_build_object(
            'metric_key', 'recurring_missing:' || r.head,
            'kind',       'recurring_missing',
            'label',      'recurring_missing',
            'value',      2,
            'msg',        jsonb_build_array(core.fn_ui_tpl('finance.advisor.recurring_missing', jsonb_build_object(
                              'name',   r.name,
                              'amount', core.fn_ui_money(abs(r.amount), r.currency),
                              'date',   core.fn_ui_date(r.last_due)))));
    END LOOP;

    -- ---------- (3) Plan-Staleness ----------
    IF v_facts IS NOT NULL AND (v_facts->'_meta') ? 'last_confirmed_at'
       AND jsonb_typeof(v_facts->'_meta'->'last_confirmed_at') <> 'null' THEN
        v_last_conf := v_facts->'_meta'->>'last_confirmed_at';
        BEGIN
            v_stale_age := current_date - v_last_conf::date;
            v_alerts := v_alerts || core.fn_staleness_alert(
                'plan_staleness', 'plan_staleness', v_stale_age, v_stale_days,
                jsonb_build_array(core.fn_ui_tpl('finance.advisor.plan_stale', jsonb_build_object(
                    'days', core.fn_ui_num(v_stale_age), 'threshold', core.fn_ui_num(v_stale_days)))));
            -- Phase A: tax_year_staleness — neues Steuerjahr (Basiszins/Vorabpauschale + Freistellungsauftrag
            -- resetten jeden Januar). Billiger Kalenderjahr-Proxy auf last_confirmed_at; Bool-Toggle
            -- advisor.tax_year_nudge (default-ON via COALESCE, kein ::numeric). INNERHALB desselben EXCEPTION-
            -- Guards wie plan_staleness (M3: ein kaputtes Datum darf nicht die ganze fn killen). Gelatcht/
            -- re-armt jahr-ueber-jahr ueber die Engine -> hoechstens EINE Nachricht/Jahr.
            IF extract(year from v_last_conf::date) < extract(year from current_date)
               AND COALESCE(core.fn_config_get('core', 'advisor', 'tax_year_nudge'), 'true') = 'true' THEN
                v_alerts := v_alerts || jsonb_build_object(
                    'metric_key', 'tax_year_staleness',
                    'kind',       'staleness',
                    'label',      'tax_year',
                    'value',      extract(year from v_last_conf::date),
                    'target',     extract(year from current_date),
                    -- Jahreszahl als Text (Intl wuerde 2026 als Zahl gruppieren)
                    'msg',        jsonb_build_array(core.fn_ui_tpl('finance.advisor.tax_year',
                                      jsonb_build_object('year', to_char(v_last_conf::date, 'YYYY')))));
            END IF;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END IF;

    -- ---------- Phase A: risk_profile-Staleness (MiFID jaehrliches Re-Assessment) ----------
    -- Feuert, wenn risk_profile.as_of aelter als advisor.risk_profile_stale_days (default 365). Partial-tolerant:
    -- nur wenn risk_profile.as_of vorhanden + valide DATE (eigener EXCEPTION-Guard, NULL-bewusst); ohne as_of ->
    -- still kein Alert, kein Crash.
    IF v_facts IS NOT NULL AND jsonb_typeof(v_facts->'risk_profile') = 'object'
       AND (v_facts->'risk_profile') ? 'as_of'
       AND jsonb_typeof(v_facts->'risk_profile'->'as_of') <> 'null' THEN
        DECLARE
            v_rp_asof TEXT := v_facts->'risk_profile'->>'as_of';
            v_rp_age  NUMERIC;
            v_rp_days NUMERIC := COALESCE(core.fn_config_get('core', 'advisor', 'risk_profile_stale_days')::numeric, 365);
        BEGIN
            v_rp_age := current_date - v_rp_asof::date;
            v_alerts := v_alerts || core.fn_staleness_alert(
                'risk_profile_staleness', 'risk_profile_staleness', v_rp_age, v_rp_days,
                jsonb_build_array(core.fn_ui_tpl('finance.advisor.risk_profile_stale', jsonb_build_object(
                    'days', core.fn_ui_num(v_rp_age), 'threshold', core.fn_ui_num(v_rp_days)))));
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END IF;

    -- ---------- Phase L (WS-1): Cashflow-Deckung (FLUSS-Check, nicht Bestand) ----------
    -- Audit Paket 3: hartes Defizit monthly_free<0 = die PFLICHTausgaben (Konsum inkl. Kreditzins + Tilgung) uebersteigen
    -- die Einnahmen; Sparplaene/Sparziel-Raten zaehlen NICHT (die besitzt savings_squeeze). Sanfter Puffer: frei <
    -- buffer_pct x Einnahmen (abschaltbar). GUARD monthly_income>0 (sonst Fehlalarm auf halb-onboardeter DB). Beide
    -- Baender teilen den metric_key -> hoechstens EINES feuert (IF/ELSIF). Latch via Core-Wrapper.
    -- has_fx_gap: eine laufende Zahlung ohne Wechselkurs -> Zusatzsatz (Zahl unvollstaendig, nie still falsch).
    DECLARE
        v_cf_buf   numeric := COALESCE(core.fn_config_get('core','advisor','cashflow_buffer_pct')::numeric, 0.10);
        v_cf_nudge text    := COALESCE(core.fn_config_get('core','advisor','cashflow_buffer_nudge'), 'true');
        v_fx_tpl   jsonb   := CASE WHEN v_cf.has_fx_gap THEN core.fn_ui_tpl('finance.advisor.cashflow_fx_gap') END;
    BEGIN
        IF v_cf.monthly_income > 0 THEN
            IF v_cf.monthly_free < 0 THEN
                v_alerts := v_alerts || jsonb_build_object(
                    'metric_key', 'cashflow_coverage', 'kind', 'cashflow_coverage', 'label', 'cashflow_coverage',
                    'value', round(v_cf.monthly_free, 2), 'target', 0, 'drift', round(abs(v_cf.monthly_free), 2),
                    'msg', jsonb_build_array(core.fn_ui_tpl('finance.advisor.cashflow_deficit', jsonb_build_object(
                               'deficit', core.fn_ui_money(abs(v_cf.monthly_free)),
                               'income', core.fn_ui_money(v_cf.monthly_income),
                               'obligations', core.fn_ui_money(abs(v_cf.monthly_obligations)))), v_fx_tpl));
            ELSIF v_cf_nudge = 'true' AND v_cf.monthly_free < v_cf_buf * v_cf.monthly_income THEN
                v_alerts := v_alerts || jsonb_build_object(
                    'metric_key', 'cashflow_coverage', 'kind', 'cashflow_coverage', 'label', 'cashflow_coverage',
                    'value', round(v_cf.monthly_free, 2), 'target', round(v_cf_buf * v_cf.monthly_income, 2),
                    'drift', round(v_cf_buf * v_cf.monthly_income - v_cf.monthly_free, 2),
                    'msg', jsonb_build_array(core.fn_ui_tpl('finance.advisor.cashflow_buffer', jsonb_build_object(
                               'free', core.fn_ui_money(v_cf.monthly_free),
                               'pct', core.fn_ui_num(v_cf.monthly_free / v_cf.monthly_income * 100, 1),
                               'target', core.fn_ui_num(v_cf_buf * 100))), v_fx_tpl));
            END IF;
        END IF;
    END;

    -- ---------- Phase L (WS-2): Ueber-Sparen (Liquiditaets-Squeeze) ----------
    -- Audit Paket 3: Pflichtausgaben gedeckt (monthly_free>=0, sonst BESITZT cashflow_coverage die Meldung -> kein
    -- Doppel-Alarm), es wird gespart (monthly_saving<0) UND das Konto schrumpft trotzdem (monthly_account_change<0)
    -- = die Sparraten uebersteigen das frei Verfuegbare. gap = |Kontoveraenderung|. Eigener metric_key. Toggle
    -- advisor.savings_squeeze_nudge.
    DECLARE
        v_sq_nudge text := COALESCE(core.fn_config_get('core','advisor','savings_squeeze_nudge'), 'true');
    BEGIN
        IF v_sq_nudge = 'true' AND v_cf.monthly_income > 0 AND v_cf.monthly_free >= 0
           AND v_cf.monthly_saving < 0 AND v_cf.monthly_account_change < 0 THEN
            v_alerts := v_alerts || jsonb_build_object(
                'metric_key', 'savings_squeeze', 'kind', 'savings_squeeze', 'label', 'savings_squeeze',
                'value', round(v_cf.monthly_account_change, 2), 'target', 0,
                'drift', round(abs(v_cf.monthly_account_change), 2),
                'msg', jsonb_build_array(core.fn_ui_tpl('finance.advisor.savings_squeeze', jsonb_build_object(
                           'gap', core.fn_ui_money(abs(v_cf.monthly_account_change)),
                           'saving', core.fn_ui_money(abs(v_cf.monthly_saving)),
                           'free', core.fn_ui_money(v_cf.monthly_free))),
                       CASE WHEN v_cf.has_fx_gap THEN core.fn_ui_tpl('finance.advisor.cashflow_fx_gap') END));
        END IF;
    END;

    -- ============================================================
    -- WS2b — Marktwert-Metriken (Allokations-Drift / Zielportfolio / Datenqualitaet)
    -- ============================================================

    -- Gesamtvermoegen nach Klasse (informativ, T1 = Gesamt-Familie INKL. Kind) + handelbarer Nenner.
    -- WS-3a: networth_by_asset_class traegt jetzt owner_person_id -> fuer den Digest die Owner kollabieren
    -- (Haushalts-Summe je Klasse), sonst je Person eine Duplikat-Zeile. Hier KEIN Kind-Ausschluss (T1).
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'class', COALESCE(asset_class, '(untagged)'),
               'value_eur', value_eur, 'tradeable', tradeable) ORDER BY value_eur DESC), '[]'::jsonb)
    INTO v_nwbc FROM (
        SELECT bucket, asset_class, tradeable, sum(value_eur) AS value_eur
        FROM finance.networth_by_asset_class
        GROUP BY bucket, asset_class, tradeable) z;

    -- WS-3a: FIRE-Pool-Nenner (T2 = Eltern-Topf) schliesst kind-besessene Assets aus. Rolle ueber das
    -- publizierte DEFINER-Fenster core.fn_household_persons() (finance liest agent.persons NIE direkt, D10).
    -- owner NULL (Haushalt) + partner -> kein 'child' -> bleiben drin (IS DISTINCT FROM behandelt NULL korrekt).
    -- Audit Paket 3: Klassen-Werte EINMAL lesen (ueber Owner summiert); die Klasse 'cash' zaehlt als FREIES Cash
    -- (abzueglich der Sparziel-Ruecklagen aus fn_liquidity_snapshot) -> zurueckgelegtes Ziel-Geld blaeht
    -- "Cash uebergewichtet" nicht auf (dieselbe Sicht wie die Notreserve).
    SELECT COALESCE(jsonb_object_agg(z.asset_class, z.value_eur), '{}'::jsonb) INTO v_cls
    FROM (SELECT n.asset_class,
                 CASE WHEN n.asset_class = 'cash'
                      THEN GREATEST(sum(n.value_eur) - COALESCE((v_snap->>'earmarked_eur')::numeric, 0), 0)
                      ELSE sum(n.value_eur) END AS value_eur
          FROM finance.networth_by_asset_class n
          LEFT JOIN core.fn_household_persons() hp ON hp.person_id = n.owner_person_id
          WHERE n.tradeable AND n.asset_class IS NOT NULL AND hp.role IS DISTINCT FROM 'child'
          GROUP BY n.asset_class) z;

    -- per-Block-Drift: Soll = target_allocation.blocks[] auf den STABILEN key gejoint
    IF jsonb_typeof(v_alloc) = 'object' AND jsonb_typeof(v_alloc->'blocks') = 'array' THEN
        -- Audit Paket 3 (gleiche Basis fuer Soll und Ist): target_pct sind GESAMTplan-Anteile (inkl. Festgeld/
        -- Immobilie/Vorsorge). Soll je handelbarem Block = target_pct x 100 / Summe der handelbaren Soll-Anteile
        -- (Korridor mit demselben Faktor); Ist-Nenner = handelbare Klassen MIT Plan-Block. Handelbarer Wert ohne
        -- Block (Cash ohne cash-Block, unmapped/ungetaggt) bleibt aus dem Nenner -> Digest-Zeile + Advisories.
        -- Beispiel Welt 50/Anleihen 20/Cash 10/Festgeld 20 genau gehalten: Welt 50 x 100/80 = 62,5 = Ist 62,5.
        SELECT COALESCE(sum(NULLIF(b->>'target_pct','')::numeric), 0) INTO v_tgt_trade_sum
        FROM jsonb_array_elements(v_alloc->'blocks') b
        WHERE b->>'key' IS NOT NULL
          AND (b->>'key') NOT IN ('real_estate', 'pension', 'p2p', 'loan', 'fixed_deposit');
        SELECT COALESCE(sum(c.value::numeric), 0) INTO v_trade_total
        FROM jsonb_each_text(v_cls) c
        WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(v_alloc->'blocks') b WHERE b->>'key' = c.key);
        -- outside_plan (2026-10-23) = bewusst ausserhalb des Haushaltsplans (z. B. Kinder-Depot) -> kein "nicht zugeordnet"
        SELECT COALESCE(sum(c.value::numeric), 0) - v_trade_total INTO v_outside FROM jsonb_each_text(v_cls) c
        WHERE c.key <> 'outside_plan';

        FOR v_blk IN SELECT * FROM jsonb_array_elements(v_alloc->'blocks') LOOP
            v_bkey := v_blk->>'key';
            v_btgt_raw := NULLIF(v_blk->>'target_pct','')::numeric;
            CONTINUE WHEN v_bkey IS NULL OR v_btgt_raw IS NULL;
            -- nicht-handelbare Ziel-Klasse (per Entitaets-Typ) -> non_rebalanceable_targets, NIE Drift-Alarm
            -- WS3: fixed_deposit (Festgeld) ist seit der View-Trennung NICHT mehr tradeable -> Plan-Block dafuer
            -- muss hier landen, sonst Dauer-Fehlalarm (actual 0% gegen target).
            IF v_bkey IN ('real_estate', 'pension', 'p2p', 'loan', 'fixed_deposit') THEN
                v_non_reb := v_non_reb || jsonb_build_object('key', v_bkey, 'name', v_blk->>'name', 'target_pct', v_btgt_raw);
                CONTINUE;
            END IF;
            CONTINUE WHEN v_tgt_trade_sum <= 0;   -- alles nicht-handelbar geplant -> kein Drift
            v_btgt    := round(v_btgt_raw * 100 / v_tgt_trade_sum, 2);
            v_cls_val := COALESCE((v_cls->>v_bkey)::numeric, 0);
            v_act_pct := CASE WHEN v_trade_total > 0 THEN round(v_cls_val / v_trade_total * 100, 2) ELSE 0 END;
            v_drift   := round(v_act_pct - v_btgt, 2);
            v_lo := NULL; v_hi := NULL;
            IF jsonb_typeof(v_blk->'corridor') = 'array' THEN
                v_lo := round((v_blk->'corridor'->>0)::numeric * 100 / v_tgt_trade_sum, 2);
                v_hi := round((v_blk->'corridor'->>1)::numeric * 100 / v_tgt_trade_sum, 2);
            END IF;
            v_breach := CASE WHEN v_lo IS NOT NULL THEN (v_act_pct < v_lo OR v_act_pct > v_hi)
                             ELSE abs(v_drift) > v_drift_tol END;
            v_reb := v_reb || jsonb_build_object('key', v_bkey, 'name', v_blk->>'name',
                        'target_pct', v_btgt, 'plan_pct', v_btgt_raw, 'actual_pct', v_act_pct,
                        'drift', v_drift, 'breach', v_breach);
            IF v_breach THEN
                v_alerts := v_alerts || jsonb_build_object(
                    'metric_key', 'alloc:' || v_bkey,
                    'kind',       'allocation_drift',
                    'label',      COALESCE(v_blk->>'name', v_bkey),
                    'value',      v_act_pct,
                    'target',     v_btgt,
                    'drift',      v_drift,
                    'msg',        jsonb_build_array(core.fn_ui_tpl('finance.advisor.allocation', jsonb_build_object(
                                      'name', COALESCE(v_blk->>'name', v_bkey), 'actual', core.fn_ui_num(v_act_pct, 1),
                                      'target', core.fn_ui_num(v_btgt, 1), 'drift', core.fn_ui_num(v_drift, 1, true)))));
            END IF;
        END LOOP;
    END IF;

    -- Pflicht-Advisory: unmapped (Tag ohne Block-key-Treffer; EXAKT-Join, keine Normalisierung).
    -- WS-3a: ueber Owner aggregieren (sonst je Person ein Duplikat-Eintrag); haushaltsweiter Datenhinweis (kein Kind-Filter).
    SELECT COALESCE(jsonb_agg(jsonb_build_object('asset_class', z.asset_class, 'value_eur', z.value_eur)), '[]'::jsonb)
    INTO v_unmapped
    FROM (
        SELECT n.asset_class, sum(n.value_eur) AS value_eur
        FROM finance.networth_by_asset_class n
        WHERE n.bucket = 'depot' AND n.asset_class IS NOT NULL
          AND n.asset_class <> 'outside_plan'   -- bewusst ausserhalb des Plans (fn_set_asset_classes), kein Datenhinweis
          AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(v_alloc->'blocks', '[]'::jsonb)) b
                          WHERE b->>'key' = n.asset_class)
        GROUP BY n.asset_class) z;

    -- Pflicht-Advisory: null_tag (handelbares Holding ohne asset_class)
    -- 2026-10-23: holding_id + Depot dazu (der Berater ordnet per tool_set_asset_classes zu, der Alarm nennt Namen,
    -- latch_keys = die ids -> eine neu hinzukommende ungetaggte Position meldet erneut)
    SELECT count(*)::int,
           COALESCE(jsonb_agg(jsonb_build_object('holding_id', h.id, 'symbol', h.symbol, 'name', h.name,
                                                 'depot_name', a.name) ORDER BY h.id), '[]'::jsonb)
    INTO v_null_tag_cnt, v_null_tag
    FROM finance.depot_holdings h JOIN finance.accounts a ON a.id = h.account_id
    WHERE h.shares > 0 AND h.asset_class IS NULL;

    -- Pflicht-Advisory: null_price = gehaltene Position ohne gueltigen Kurs (missing ODER stale je Position) aus
    -- finance.fn_holding_price_status (EINE Regel mit Depot-Uebersicht + Kurs-Luecken-Erinnerung, 2026-10-27).
    -- Bewusst KEIN latch_keys-Eintrag: gemeldet wird die Luecke von agent.finance.cron_remind_missing_prices (auch ohne
    -- Finanzplan); hier steht sie nur im Datenqualitaets-Text (sonst Doppel-Meldung).
    SELECT count(*)::int,
           COALESCE(jsonb_agg(jsonb_build_object('holding_id', s.holding_id, 'symbol', s.symbol, 'name', s.name,
                                                 'status', s.status) ORDER BY s.holding_id), '[]'::jsonb)
    INTO v_null_price_cnt, v_null_price
    FROM finance.fn_holding_price_status() s
    WHERE s.status <> 'ok';

    -- WP-3c Pflicht-Advisory: null_rate — eine in Nutzung befindliche Fremdwaehrung (Konto-, Holding- ODER
    -- Quote-Waehrung, via fn_active_currencies) OHNE fx_rates-Zeile. fn_to_eur liefert dafuer NULL -> die
    -- Roll-up-Summen (Net-Worth/Reserve/Runway) ueberspringen den Betrag STILL -> Zwilling zu null_price:
    -- die Luecke wird sichtbar gemeldet statt still als 0 verbucht. real_estate/pension tragen keine currency
    -- (EUR by construction) -> nie hier. Loan/Festgeld/p2p sind ueber accounts.currency abgedeckt.
    SELECT count(*)::int,
           COALESCE(jsonb_agg(jsonb_build_object('currency', code)), '[]'::jsonb)
    INTO v_null_rate_cnt, v_null_rate
    FROM (SELECT ac.code FROM finance.fn_active_currencies() ac
          WHERE NOT EXISTS (SELECT 1 FROM finance.fx_rates fxr
                            WHERE fxr.base_currency = 'EUR' AND fxr.quote_currency = ac.code)) s;

    -- price_as_of (juengster Kurs gehaltener Symbole) + Stale-Flag
    SELECT max(mp.as_of) INTO v_price_asof
    FROM finance.market_prices mp
    WHERE EXISTS (SELECT 1 FROM finance.depot_holdings h WHERE h.symbol = mp.symbol AND h.shares > 0);
    -- Stale-Regel = finance.fn_price_status (eine Adresse; Schwelle advisor.price_stale_days, Vergleich '>')
    v_price_stale := EXISTS (SELECT 1 FROM finance.depot_holdings WHERE shares > 0)
                     AND finance.fn_price_status(v_price_asof) <> 'ok';

    -- Zielportfolio-Drift (FIRE-Topf vs. goal.target_portfolio_eur unterer Wert).
    -- WS3 FIRE-Topf-Basis (Owner-Entscheid 2026-06-22; Bengen/Trinity/Big-ERN):
    --   'investment' (Default) = liquide Anlage-Assets Depot + Cash + Festgeld + P2P (BRUTTO);
    --     OHNE Hypothek/Haus/Rente (Haus+Hypothek heben sich auf, bleiben aussen).
    --   'net_worth' = investment + Immobilien + alle Kredite (Audit Paket 3: Haus und Hypothek heben sich auf).
    --   ELSE-Fail-Safe: jede andere/unbekannte Basis rechnet wie investment (nie leerer Pot).
    --   WS-B: das Depot-Account-Earmark-Netting (savings_goal_allocations) ist mit dem Tabellen-DROP entfallen;
    --     das FIRE-Topf-Netting ist bewusst nach BACKLOG verschoben (Reserve-Fundament zuerst) -> hier Brutto.
    IF jsonb_typeof(v_goal) = 'object' AND (v_goal ? 'target_portfolio_eur') THEN
        v_tp_target := CASE WHEN jsonb_typeof(v_goal->'target_portfolio_eur') = 'array'
                            THEN (v_goal->'target_portfolio_eur'->>0)::numeric
                            ELSE (v_goal->>'target_portfolio_eur')::numeric END;
        -- (a) Basis: liquide Anlage-Assets (Festgeld als eigener bucket explizit; loan/real_estate/pension raus).
        --     WS-3a: FIRE-Topf OHNE kind-besessene Assets (T2) — Rolle ueber core.fn_household_persons().
        -- has_fx_gap (Paket 2): ein Wert DIESER Basis ohne Wechselkurs fiele still aus der Summe -> Hinweis am Alert
        -- (nur ueber die Zeilen, die der Topf auch summiert; die Waehrung selbst meldet dq_null_rate).
        SELECT COALESCE(sum(n.value_eur), 0), COALESCE(bool_or(n.has_fx_gap), false) INTO v_portfolio, v_nw_fx_gap
        FROM finance.networth_by_asset_class n
        LEFT JOIN core.fn_household_persons() hp ON hp.person_id = n.owner_person_id
        WHERE n.bucket IN ('depot', 'cash', 'fixed_deposit', 'p2p') AND hp.role IS DISTINCT FROM 'child';
        -- (b) net_worth (Audit Paket 3): investment + Immobilien + alle Kredite -> Haus und Hypothek heben sich auf
        --     (vorher zog net_worth die Hypothek ab, OHNE das Haus zu zaehlen). Symmetrisch: eine Immobilie, die
        --     herausfaellt (Kind-Eigentum oder Wert unbekannt), nimmt ihren Kredit (loans.real_estate_id) mit.
        --     Vorsorge bleibt draussen (bis zur Rente nicht entnehmbar). WS-3a: nur Nicht-Kind-Werte.
        --     ELSE/Default = investment (kein Zu-/Abschlag).
        IF COALESCE(v_goal->>'target_portfolio_basis', 'investment') = 'net_worth' THEN
            SELECT v_portfolio + COALESCE(sum(re.current_value), 0) INTO v_portfolio
            FROM finance.real_estate re
            LEFT JOIN core.fn_household_persons() hp ON hp.person_id = re.owner_person_id
            WHERE re.status = 'active' AND re.current_value IS NOT NULL AND hp.role IS DISTINCT FROM 'child';
            SELECT v_portfolio + COALESCE(sum(finance.fn_to_eur(b.balance, a.currency)), 0),
                   v_nw_fx_gap OR COALESCE(bool_or(b.balance <> 0 AND finance.fn_to_eur(b.balance, a.currency) IS NULL), false)
              INTO v_portfolio, v_nw_fx_gap
            FROM finance.accounts a
            JOIN finance.account_balances b ON b.account_id = a.id
            LEFT JOIN core.fn_household_persons() hp ON hp.person_id = a.owner_person_id
            WHERE a.status = 'active' AND a.account_type = 'loan' AND hp.role IS DISTINCT FROM 'child'
              AND NOT EXISTS (
                  SELECT 1 FROM finance.loans l
                  JOIN finance.real_estate re ON re.id = l.real_estate_id
                  LEFT JOIN core.fn_household_persons() rp ON rp.person_id = re.owner_person_id
                  WHERE l.loan_account_id = a.id
                    -- nur eine AKTIVE Immobilie, die herausfaellt, nimmt ihren Kredit mit; der Kredit einer verkauften
                    -- Immobilie bleibt eine echte Schuld (der Erloes liegt dann im Cash).
                    AND re.status = 'active' AND (re.current_value IS NULL OR rp.role = 'child'));
            -- Immobilie mit Kredit, aber ohne Wert -> Digest-Hinweis (Gesamtvermoegen ohne dieses Objekt)
            v_re_missing := EXISTS (SELECT 1 FROM finance.real_estate re
                                    JOIN finance.loans l ON l.real_estate_id = re.id
                                    WHERE re.status = 'active' AND re.current_value IS NULL);
        END IF;
        IF v_tp_target IS NOT NULL AND v_tp_target > 0 AND v_portfolio < v_tp_target THEN
            v_alerts := v_alerts || jsonb_build_object(
                'metric_key', 'target_portfolio',
                'kind',       'target_portfolio',
                'label',      'target_portfolio',
                'value',      round(v_portfolio, 2),
                'target',     round(v_tp_target, 2),
                'drift',      round(v_tp_target - v_portfolio, 2),
                'msg',        jsonb_build_array(core.fn_ui_tpl('finance.advisor.target_portfolio', jsonb_build_object(
                                  'value', core.fn_ui_money(v_portfolio), 'target', core.fn_ui_money(v_tp_target),
                                  'gap', core.fn_ui_money(v_tp_target - v_portfolio))),
                                  CASE WHEN v_nw_fx_gap THEN core.fn_ui_tpl('finance.advisor.target_portfolio_fx_gap') END));
        END IF;
    END IF;

    -- Datenqualitaet: EIN gelatchter Sammel-Alert (stabiler key) wenn Tag-/Kurs-Luecken bestehen; der
    -- Digest listet sie zusaetzlich unbedingt (nicht-unterdrueckbar im Quartals-Review). Kurs-Luecken allein loesen den
    -- Alert NICHT aus (2026-10-27): die meldet agent.finance.cron_remind_missing_prices (sonst Doppel-Meldung); sie stehen
    -- nur mit im Text, wenn der Alert aus anderem Grund kommt.
    IF v_null_tag_cnt > 0 OR v_null_rate_cnt > 0 OR jsonb_array_length(v_unmapped) > 0 THEN
        v_dq_msg := jsonb_build_array(
            core.fn_ui_tpl('finance.advisor.dq_intro'),
            -- Namen (bis 5) statt nur Anzahl (2026-10-23); mehr -> eigener Text "und n weitere"
            CASE WHEN v_null_tag_cnt > 0 THEN core.fn_ui_tpl('finance.advisor.dq_null_tag',
                 jsonb_build_object('n', core.fn_ui_num(v_null_tag_cnt),
                     'names', (SELECT string_agg(e->>'name', ', ' ORDER BY ord)
                               FROM jsonb_array_elements(v_null_tag) WITH ORDINALITY t(e, ord) WHERE ord <= 5))) END,
            CASE WHEN v_null_tag_cnt > 5 THEN core.fn_ui_tpl('finance.advisor.dq_null_tag_more',
                 jsonb_build_object('n', core.fn_ui_num(v_null_tag_cnt - 5))) END,
            CASE WHEN jsonb_array_length(v_unmapped) > 0 THEN core.fn_ui_tpl('finance.advisor.dq_unmapped',
                 jsonb_build_object('n', core.fn_ui_num(jsonb_array_length(v_unmapped)))) END,
            CASE WHEN v_null_price_cnt > 0 THEN core.fn_ui_tpl('finance.advisor.dq_null_price',
                 jsonb_build_object('n', core.fn_ui_num(v_null_price_cnt),
                     'names', (SELECT string_agg(e->>'name', ', ' ORDER BY ord)
                               FROM jsonb_array_elements(v_null_price) WITH ORDINALITY t(e, ord) WHERE ord <= 5))) END,
            CASE WHEN v_null_price_cnt > 5 THEN core.fn_ui_tpl('finance.advisor.dq_null_price_more',
                 jsonb_build_object('n', core.fn_ui_num(v_null_price_cnt - 5))) END,
            CASE WHEN v_null_rate_cnt > 0 THEN core.fn_ui_tpl('finance.advisor.dq_null_rate',
                 jsonb_build_object('n', core.fn_ui_num(v_null_rate_cnt))) END);
        v_alerts := v_alerts || jsonb_build_object(
            'metric_key', 'data_quality',
            'kind',       'data_quality',
            'label',      'data_quality',
            'value',      v_null_tag_cnt + v_null_price_cnt + v_null_rate_cnt + jsonb_array_length(v_unmapped),
            'msg',        v_dq_msg,
            -- latch_keys (2026-10-23, Engine core.fn_advisor_review_evaluate von Session 6b): je ungetaggter Position
            -- ein Latch -> eine NEUE ungetaggte Position meldet erneut; ohne Engine-Unterstuetzung ignoriert
            'latch_keys', (SELECT COALESCE(jsonb_agg('null_tag:' || (e->>'holding_id')), '[]'::jsonb)
                           FROM jsonb_array_elements(v_null_tag) e));
    END IF;

    -- ---------- Voll-Digest (Quartals-Review) ----------
    -- Rohwerte (Zahlen, ISO-Datum) — die Anzeige formatiert der Workflow per Intl (nie to_char: lc_numeric).
    v_digest := jsonb_build_object(
        'plan_count',      (SELECT count(*)::int FROM core.fn_advisor_read_plan('finance') WHERE status = 'active'),
        'plan_version',    (SELECT version       FROM core.fn_advisor_read_plan('finance') WHERE status = 'active'),
        'plan_published',  (SELECT updated_at::date FROM core.fn_advisor_read_plan('finance') WHERE status = 'active'),
        -- Audit Paket 3: Konsum / Tilgung / Pflicht / frei / Sparen / Kontoveraenderung getrennt (Ausgaben als ABS)
        'income',          round(v_cf.monthly_income, 2),
        'consumption',     round(abs(v_cf.monthly_consumption), 2),
        'principal',       round(abs(v_cf.monthly_principal), 2),
        'obligations',     round(abs(v_cf.monthly_obligations), 2),
        'free',            round(v_cf.monthly_free, 2),
        'saving',          round(abs(v_cf.monthly_saving), 2),
        'account_change',  round(v_cf.monthly_account_change, 2),
        'cash_total',      (SELECT round(COALESCE(sum(balance_eur), 0), 2) FROM finance.account_overview WHERE status = 'active' AND account_type = 'cash'),
        'depot_book_value',(SELECT round(COALESCE(sum(book_value_eur), 0), 2) FROM finance.depot_holdings_overview),
        'debt_total',      (SELECT round(ABS(COALESCE(total_debt, 0)), 2) FROM finance.loan_summary),
        'triggers_armed',  (SELECT armed FROM core.fn_monitor_trigger_summary('finance')),
        'triggers_fired',  (SELECT fired FROM core.fn_monitor_trigger_summary('finance')));

    -- Digest als Zeilen-STRUKTUR (Textkatalog Phase C): je Zeile ein tpl, ein Array von tpl (= eine Zeile, Teile mit
    -- Leerzeichen verbunden) oder null (= Leerzeile); der Workflow rendert sie in der Sprache des Empfaengers.
    v_lines := CASE WHEN (v_digest->>'plan_count')::int = 0
                    THEN jsonb_build_array(core.fn_ui_tpl('finance.advisor.digest_title_none'), NULL,
                                           core.fn_ui_tpl('finance.advisor.digest_no_plan'))
                    ELSE jsonb_build_array(core.fn_ui_tpl('finance.advisor.digest_title', jsonb_build_object(
                             'version', v_digest->>'plan_version',
                             'date', core.fn_ui_date((v_digest->>'plan_published')::date))))
               END
        || jsonb_build_array(NULL,
               core.fn_ui_tpl('finance.advisor.digest_cashflow', jsonb_build_object(
                   'income', core.fn_ui_money((v_digest->>'income')::numeric),
                   'consumption', core.fn_ui_money((v_digest->>'consumption')::numeric),
                   'principal', core.fn_ui_money((v_digest->>'principal')::numeric),
                   'free', core.fn_ui_money((v_digest->>'free')::numeric),
                   'saving', core.fn_ui_money((v_digest->>'saving')::numeric),
                   'account_change', core.fn_ui_money((v_digest->>'account_change')::numeric))),
               core.fn_ui_tpl('finance.advisor.digest_cash', jsonb_build_object('value', core.fn_ui_money((v_digest->>'cash_total')::numeric))),
               core.fn_ui_tpl('finance.advisor.digest_depot', jsonb_build_object('value', core.fn_ui_money((v_digest->>'depot_book_value')::numeric))),
               core.fn_ui_tpl('finance.advisor.digest_debt', jsonb_build_object('value', core.fn_ui_money((v_digest->>'debt_total')::numeric))),
               NULL,
               core.fn_ui_tpl('finance.advisor.digest_goals'))
        -- WS-C1: Engpass-Reihung im Digest sichtbar — target_date ASC, priority ASC NULLS LAST, name als
        -- Tie-Breaker (deterministisch -> kein Flake bei gleichem Datum+priority).
        -- Audit Paket 3: Ziel ohne Topf -> "nicht messbar" statt einer irrefuehrenden 0-%-Zeile.
        || COALESCE((SELECT jsonb_agg(CASE
                         -- Instandhaltungsruecklage: kein Ziel -> Stand + eingestellte Rate statt "x % von —"
                         -- (Rate aus maintenance_reserve_status, EIN Join; ohne Kurs NULL -> "—", nie still 0)
                         WHEN sgp.real_estate_id IS NOT NULL
                         THEN core.fn_ui_tpl('finance.advisor.digest_maintenance_line', jsonb_build_object(
                                  'name', sgp.name, 'current', core.fn_ui_money(COALESCE(sgp.current_amount, 0)),
                                  'rate', core.fn_ui_money(m.running_monthly_eur)))
                         WHEN sgp.progress_measurable
                         THEN core.fn_ui_tpl('finance.advisor.digest_goal_line', jsonb_build_object(
                                  'name', sgp.name, 'pct', core.fn_ui_num(COALESCE(sgp.progress_percent, 0)),
                                  'current', core.fn_ui_money(COALESCE(sgp.current_amount, 0)),
                                  'target', core.fn_ui_money(sgp.target_amount)))
                         ELSE core.fn_ui_tpl('finance.advisor.digest_goal_line_unmeasurable', jsonb_build_object(
                                  'name', sgp.name, 'target', core.fn_ui_money(sgp.target_amount))) END
                       ORDER BY sgp.target_date, sgp.priority NULLS LAST, sgp.name)
                     FROM finance.savings_goal_progress sgp
                     LEFT JOIN finance.maintenance_reserve_status m ON m.goal_id = sgp.id
                     WHERE sgp.status = 'active'),
                    jsonb_build_array(core.fn_ui_tpl('finance.advisor.digest_no_goals')));

    -- WS-B Stufe 3: Reserve-Aufschluesselung Cash/Depot je Konto ("wo liegt mein Ziel-Geld?") aus der
    -- savings_goal_reserve_breakdown-View, nur aktive Ziele (reserved_amount in EUR, WP-3b).
    SELECT jsonb_agg(core.fn_ui_tpl('finance.advisor.digest_reserve_line', jsonb_build_object(
               'goal', g.name, 'account', b.account_name, 'amount', core.fn_ui_money(b.reserved_amount),
               'source', jsonb_build_object('kind', 'enum', 'enum', 'finance.advisor.reserve_source', 'value', b.source)))
             ORDER BY g.name, b.source, b.account_name)
      INTO v_reserve_bd
    FROM finance.savings_goal_reserve_breakdown b
    JOIN finance.savings_goals g ON g.id = b.goal_id AND g.status = 'active';
    IF v_reserve_bd IS NOT NULL THEN
        v_lines := v_lines || jsonb_build_array(NULL, core.fn_ui_tpl('finance.advisor.digest_reserve_heading')) || v_reserve_bd;
    END IF;

    -- Rebalancing-Zusammenfassung (Marktwert): je handelbarem Block Ist vs. Soll.
    IF jsonb_array_length(v_reb) > 0 THEN
        v_lines := v_lines || jsonb_build_array(NULL, core.fn_ui_tpl('finance.advisor.digest_alloc_heading'))
            || (SELECT jsonb_agg(core.fn_ui_tpl(
                       CASE WHEN (b->>'breach')::boolean THEN 'finance.advisor.digest_alloc_line_out'
                            ELSE 'finance.advisor.digest_alloc_line' END,
                       jsonb_build_object('name', COALESCE(b->>'name', b->>'key'),
                                          'actual', core.fn_ui_num((b->>'actual_pct')::numeric, 1),
                                          'target', core.fn_ui_num((b->>'target_pct')::numeric, 1))))
                  FROM jsonb_array_elements(v_reb) b);
    END IF;
    -- Audit Paket 3: handelbarer Wert ohne Plan-Block steht nicht im Drift-Nenner -> sichtbar machen
    IF jsonb_array_length(v_reb) > 0 AND COALESCE(v_outside, 0) > 0 THEN
        v_lines := v_lines || jsonb_build_array(core.fn_ui_tpl('finance.advisor.digest_alloc_outside',
                       jsonb_build_object('value', core.fn_ui_money(v_outside))));
    END IF;
    IF v_re_missing THEN
        v_lines := v_lines || jsonb_build_array(NULL, core.fn_ui_tpl('finance.advisor.digest_real_estate_value_missing'));
    END IF;
    IF v_price_stale THEN
        v_lines := v_lines || jsonb_build_array(NULL, core.fn_ui_tpl('finance.advisor.digest_price_stale'));
    END IF;
    -- WS3: P2P zaehlt zum Nennwert im FIRE-Topf (Owner-Wahl) -> Marktwert/Ausfallrisiko nicht beruecksichtigt
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_nwbc) c
               WHERE c->>'class' = 'p2p' AND COALESCE((c->>'value_eur')::numeric, 0) <> 0) THEN
        v_lines := v_lines || jsonb_build_array(NULL, core.fn_ui_tpl('finance.advisor.digest_p2p'));
    END IF;
    IF v_dq_msg IS NOT NULL THEN
        v_lines := v_lines || jsonb_build_array(NULL, v_dq_msg);
    END IF;
    v_lines := v_lines || jsonb_build_array(NULL, core.fn_ui_tpl('finance.advisor.digest_triggers', jsonb_build_object(
                   'armed', core.fn_ui_num((v_digest->>'triggers_armed')::numeric),
                   'fired', core.fn_ui_num((v_digest->>'triggers_fired')::numeric))));

    v_digest := v_digest || jsonb_build_object('lines', v_lines);

    RETURN jsonb_build_object(
        'alerts', v_alerts,
        'digest', v_digest,
        'net_worth_by_class', v_nwbc,
        'rebalanceable_drift', v_reb,
        'non_rebalanceable_targets', v_non_reb,
        'advisories', jsonb_build_object(
            'unmapped',    v_unmapped,
            'null_tag',    v_null_tag,
            'null_price',  v_null_price,
            'null_rate',   v_null_rate,
            'price_as_of', v_price_asof,
            'price_stale', v_price_stale));
END;
$$;
