-- ============================================================
-- fn_validate_financial_planning (READ HELPER, STABLE)
--   Strukturvalidierung des paket-besessenen 'financial_planning'-Plan-Fakten-Sidecars
--   (metadata.facts: goal / risk_profile / target_allocation / glidepath / _meta). emergency_reserve wird
--   abgewiesen (Notreserve = Ruecklage kind emergency_reserve, fn_emergency_reserve_status).
--   risk_profile = {risk_tolerance, risk_capacity (low|medium|high), as_of (DATE, nicht Zukunft)}.
--   Jeder target_allocation.blocks[]-Eintrag traegt einen stabilen Maschinen-`key`
--   (lowercase snake, == depot_holdings.asset_class-Format) neben dem Anzeige-`name` — Pflicht je Block,
--   Format-geprueft + eindeutig (der stabile Drift-Join-Key, ueberlebt name-Renames; Praezedenz Nautobot key/label).
--   Vom Core-Trigger agent.trg_core_contexts_validate_facts_fn generisch ueber die Registry
--   core.context_validators dispatcht (NEW.name='financial_planning' -> diese fn); fehlt die
--   Registry-Zeile (Paket nicht installiert), entfaellt die Plan-Strukturpruefung still.
--   Eingabe: p_facts jsonb (kein Objekt oder NULL -> gueltig).
--
--   Partial-tolerant: jeder Top-Block ist optional — innere Konsistenz wird nur geprueft,
--   wenn der Block vorhanden ist (Muster fn_validate_finance_profile: 'IF p_facts ? x'-geguardet).
--   Sonst wuerde der BEFORE-UPDATE-Trigger jeden Publish mit noch-unvollstaendigem facts hart
--   ablehnen (Compose materialisiert nur die im Interview beruehrten Sektionen).
--
--   Derived-Guard: die rekursive Derived-Key-Denylist (calendar years / ages / years_to_* /
--   nominal / derived_/computed_-Prefix) lebt generisch im Core-Validator
--   agent.fn_validate_household_facts (laeuft vom selben Trigger vor diesem Paket-Validator, fuer
--   jeden facts-Sidecar) — hier nicht dupliziert. Dieser Validator prueft nur die Domaenen-
--   Struktur der Plan-facts.
--
--   RUECKGABE: NULL = gueltig; sonst englischer Fehlertext (der Core-Trigger -> RAISE EXCEPTION).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_validate_financial_planning(p_facts jsonb)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_alloc   JSONB;
    v_sum     NUMERIC;
    v_blk     JSONB;
    v_t       NUMERIC;
    v_lo      NUMERIC;
    v_hi      NUMERIC;
    v_gp      JSONB;
    v_ph      JSONB;
    v_key     TEXT;
    v_keys    TEXT[] := '{}';
    v_prev_to NUMERIC;
    v_from    NUMERIC;
    v_to      NUMERIC;
    v_eq      NUMERIC;
    v_rate    NUMERIC;
    v_asof    TEXT;
BEGIN
    IF p_facts IS NULL OR jsonb_typeof(p_facts) IS DISTINCT FROM 'object' THEN
        RETURN NULL;  -- facts optional / nicht-Objekt: nichts zu pruefen (Compose schreibt immer ein Objekt)
    END IF;

    -- Notreserve: kein Plan-Fakt, sondern eine Ruecklage (Sparziel kind emergency_reserve) — ein
    -- Fakt, eine Adresse. Alt-Bloecke raeumt finance:V033 aus den gespeicherten Plaenen.
    IF p_facts ? 'emergency_reserve' THEN
        RETURN 'emergency_reserve is no longer a plan block - the emergency reserve is kept as a reserve goal (the '
            || 'bookkeeper creates it with tool_create_savings_goal kind emergency_reserve); describe the strategy in the '
            || 'section prose only';
    END IF;

    -- ---------- goal (optional) ----------
    IF p_facts ? 'goal' AND jsonb_typeof(p_facts->'goal') = 'object' THEN
        -- Keine ableitbaren Spalten: von Einkommen, Entnahmerate und Zielportfolio nur zwei speichern -- der dritte
        -- haengt an den beiden (fn_plan_goal_resolved leitet ihn fuer Anzeige + Drift ab).
        IF (p_facts->'goal') ? 'target_income_eur_month' AND (p_facts->'goal') ? 'withdrawal_rate_pct'
           AND (p_facts->'goal') ? 'target_portfolio_eur' THEN
            RETURN 'goal stores only two of target_income_eur_month, withdrawal_rate_pct and target_portfolio_eur - '
                || 'the third is derived; keep the two figures the user stated';
        END IF;
        IF (p_facts->'goal') ? 'withdrawal_rate_pct'
           AND jsonb_typeof(p_facts->'goal'->'withdrawal_rate_pct') = 'number' THEN
            v_rate := (p_facts->'goal'->>'withdrawal_rate_pct')::numeric;
            IF v_rate <= 0 OR v_rate > 10 THEN
                RETURN format('goal.withdrawal_rate_pct %s out of range (0,10]', v_rate);
            END IF;
        END IF;
        -- Inflations-Annahme (FPA "improved method": alles real gespeichert + eine Annahme, Nominal abgeleitet)
        IF (p_facts->'goal') ? 'inflation_pct'
           AND jsonb_typeof(p_facts->'goal'->'inflation_pct') = 'number' THEN
            IF (p_facts->'goal'->>'inflation_pct')::numeric < 0 OR (p_facts->'goal'->>'inflation_pct')::numeric > 10 THEN
                RETURN format('goal.inflation_pct %s out of range [0,10]', p_facts->'goal'->>'inflation_pct');
            END IF;
        END IF;
        -- target_portfolio_basis = wie der Review-Drift den FIRE-Topf misst.
        --   'investment' (Default) = Depot + Cash + Festgeld + P2P (brutto, kein Netting der Sparziel-Reserven), ohne Hypothek/Haus/Rente
        --     (Bengen/Trinity/Big-ERN: der 4%-Entnahme-Topf; Haus+Hypothek heben sich auf, bleiben aussen).
        --   'net_worth' = investierbar + Immobilien + alle Kredite (Haus und Hypothek heben sich auf;
        --   eine herausfallende Immobilie nimmt ihren Kredit mit). Der Review honoriert es per
        --   COALESCE(...,'investment') mit ELSE-Fail-Safe -> hier nur die Enum-Integritaet (Backstop).
        IF (p_facts->'goal') ? 'target_portfolio_basis'
           AND (p_facts->'goal'->>'target_portfolio_basis') NOT IN ('investment', 'net_worth') THEN
            RETURN format('goal.target_portfolio_basis %s invalid (expected investment|net_worth)',
                          p_facts->'goal'->>'target_portfolio_basis');
        END IF;
    END IF;

    -- ---------- target_allocation (optional) ----------
    IF p_facts ? 'target_allocation' AND jsonb_typeof(p_facts->'target_allocation') = 'object' THEN
        v_alloc := p_facts->'target_allocation';
        IF (v_alloc ? 'rebalance_drift_pp') AND jsonb_typeof(v_alloc->'rebalance_drift_pp') = 'number'
           AND (v_alloc->>'rebalance_drift_pp')::numeric <= 0 THEN
            RETURN 'target_allocation.rebalance_drift_pp must be > 0';
        END IF;
        -- blocks nur pruefen, wenn nicht-leeres Array (partial: leere/fehlende blocks = noch nicht erfasst)
        IF (v_alloc ? 'blocks') AND jsonb_typeof(v_alloc->'blocks') = 'array'
           AND jsonb_array_length(v_alloc->'blocks') > 0 THEN
            v_sum := 0;
            FOR v_blk IN SELECT * FROM jsonb_array_elements(v_alloc->'blocks') LOOP
                -- jeder Block traegt einen stabilen Maschinen-`key`
                -- (lowercase snake, == depot_holdings.asset_class-Tag-Format) neben dem Anzeige-`name`.
                -- Der key ist der stabile Join-Key der Drift (ueberlebt name-Renames); Pflicht je Block +
                -- Format + eindeutig (Praezedenz Nautobot key/label, Ghostfolio enum+UI, PP uuid+name).
                IF jsonb_typeof(v_blk->'key') IS DISTINCT FROM 'string'
                   OR (v_blk->>'key') !~ '^[a-z0-9_]+$' THEN
                    RETURN 'each target_allocation.blocks[] needs a key matching ^[a-z0-9_]+$ (lowercase machine key, e.g. sp500)';
                END IF;
                v_key := v_blk->>'key';
                -- outside_plan ist reserviert: Positionen "bewusst ausserhalb des Plans"; ein Block mit
                -- diesem key zoege sie zurueck in den Drift-Nenner
                IF v_key = 'outside_plan' THEN
                    RETURN 'target_allocation.blocks[] key "outside_plan" is reserved (positions deliberately outside the plan) - choose another key';
                END IF;
                IF v_key = ANY (v_keys) THEN
                    RETURN format('target_allocation.blocks[] key "%s" is duplicated (keys must be unique)', v_key);
                END IF;
                v_keys := v_keys || v_key;
                IF jsonb_typeof(v_blk->'target_pct') IS DISTINCT FROM 'number' THEN
                    RETURN 'each target_allocation.blocks[] needs a numeric target_pct';
                END IF;
                v_t := (v_blk->>'target_pct')::numeric;
                IF v_t < 0 OR v_t > 100 THEN
                    RETURN format('target_pct %s out of range 0..100', v_t);
                END IF;
                v_sum := v_sum + v_t;
                IF (v_blk ? 'corridor') AND jsonb_typeof(v_blk->'corridor') = 'array'
                   AND jsonb_array_length(v_blk->'corridor') = 2 THEN
                    v_lo := (v_blk->'corridor'->>0)::numeric;
                    v_hi := (v_blk->'corridor'->>1)::numeric;
                    IF v_lo < 0 OR v_hi > 100 OR v_lo > v_hi THEN
                        RETURN format('corridor [%s,%s] must satisfy 0<=low<=high<=100', v_lo, v_hi);
                    END IF;
                    IF v_t < v_lo OR v_t > v_hi THEN
                        RETURN format('target_pct %s outside its corridor [%s,%s]', v_t, v_lo, v_hi);
                    END IF;
                END IF;
            END LOOP;
            -- Allokations-Summe = 100 (±0.5 Toleranz fuer Rundung). target_pct/corridor sind Gesamtplan-Anteile
            -- (inkl. Festgeld/Immobilie/Vorsorge); fn_advisor_review normiert die handelbaren Bloecke fuer den
            -- Drift auf deren Summe -> hier bewusst keine zweite, handelbare Summenpruefung.
            IF abs(v_sum - 100) > 0.5 THEN
                RETURN format('target_allocation.blocks target_pct sum to %s, expected 100 (±0.5)', v_sum);
            END IF;
        END IF;
    END IF;

    -- ---------- glidepath (optional) — Phasen zeitlich geordnet, lueckenlos, equity 0..100 ----------
    IF p_facts ? 'glidepath' AND jsonb_typeof(p_facts->'glidepath') = 'object' THEN
        v_gp := p_facts->'glidepath';
        IF (v_gp ? 'phases') AND jsonb_typeof(v_gp->'phases') = 'array'
           AND jsonb_array_length(v_gp->'phases') > 0 THEN
            v_prev_to := NULL;
            FOR v_ph IN SELECT * FROM jsonb_array_elements(v_gp->'phases') LOOP
                IF (v_ph ? 'equity_pct') AND jsonb_typeof(v_ph->'equity_pct') = 'number' THEN
                    v_eq := (v_ph->>'equity_pct')::numeric;
                    IF v_eq < 0 OR v_eq > 100 THEN
                        RETURN format('glidepath equity_pct %s out of range 0..100', v_eq);
                    END IF;
                END IF;
                -- Ordnung: age_from der Folge-Phase > age_to der vorigen (monoton, lueckenlos genug)
                IF (v_ph ? 'age_from') AND jsonb_typeof(v_ph->'age_from') = 'number' THEN
                    v_from := (v_ph->>'age_from')::numeric;
                    IF v_prev_to IS NOT NULL AND v_from <= v_prev_to THEN
                        RETURN format('glidepath phases not strictly ordered (age_from %s <= previous age_to %s)', v_from, v_prev_to);
                    END IF;
                END IF;
                IF (v_ph ? 'age_to') AND jsonb_typeof(v_ph->'age_to') = 'number' THEN
                    v_to := (v_ph->>'age_to')::numeric;
                    IF (v_ph ? 'age_from') AND v_to < (v_ph->>'age_from')::numeric THEN
                        RETURN format('glidepath phase age_to %s before age_from', v_to);
                    END IF;
                    v_prev_to := v_to;
                END IF;
            END LOOP;
        END IF;
    END IF;

    -- ---------- risk_profile (optional) — MiFID-Dimensionen + as_of-Stempel ----------
    -- risk_tolerance (Bereitschaft) + risk_capacity (Tragfaehigkeit) als grobe low|medium|high-Enums
    -- (konversationelles Tool, keine numerischen Robo-Scores); as_of = Stand der
    -- Risiko-Erhebung (MiFID-Jahres-Re-Assessment; treibt den risk_profile_staleness-Nudge). Bewusst kein
    -- risk_need (semi-ableitbar -> in der Prosa gegen goal abgewogen, nicht gespeichert) und kein
    -- time_horizon (abgeleitet planned_retirement_age - Alter; die Core-Denylist verbietet gespeicherten
    -- Horizont). Partial-tolerant: jedes Feld optional.
    IF p_facts ? 'risk_profile' AND jsonb_typeof(p_facts->'risk_profile') = 'object' THEN
        IF (p_facts->'risk_profile') ? 'risk_tolerance'
           AND (p_facts->'risk_profile'->>'risk_tolerance') NOT IN ('low', 'medium', 'high') THEN
            RETURN format('risk_profile.risk_tolerance %s invalid (expected low|medium|high)',
                          p_facts->'risk_profile'->>'risk_tolerance');
        END IF;
        IF (p_facts->'risk_profile') ? 'risk_capacity'
           AND (p_facts->'risk_profile'->>'risk_capacity') NOT IN ('low', 'medium', 'high') THEN
            RETURN format('risk_profile.risk_capacity %s invalid (expected low|medium|high)',
                          p_facts->'risk_profile'->>'risk_capacity');
        END IF;
        IF (p_facts->'risk_profile') ? 'as_of'
           AND jsonb_typeof(p_facts->'risk_profile'->'as_of') <> 'null' THEN
            v_asof := p_facts->'risk_profile'->>'as_of';
            BEGIN
                IF v_asof::date > CURRENT_DATE THEN
                    RETURN format('risk_profile.as_of %s is in the future', v_asof);
                END IF;
            EXCEPTION WHEN OTHERS THEN
                RETURN format('risk_profile.as_of "%s" is not a valid DATE', v_asof);
            END;
        END IF;
    END IF;

    -- ---------- _meta.last_confirmed_at nicht in der Zukunft (Frische-Monitor-Schutz) ----------
    IF (p_facts->'_meta') ? 'last_confirmed_at'
       AND jsonb_typeof(p_facts->'_meta'->'last_confirmed_at') <> 'null' THEN
        v_asof := p_facts->'_meta'->>'last_confirmed_at';
        BEGIN
            IF v_asof::date > CURRENT_DATE THEN
                RETURN format('_meta.last_confirmed_at %s is in the future', v_asof);
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RETURN format('_meta.last_confirmed_at "%s" is not a valid DATE', v_asof);
        END;
    END IF;

    RETURN NULL;
END;
$$;
