-- ============================================================
-- estate.fn_render_register_body (WS-5 — der GETEILTE Register-Body von Overview UND Notfallmappe)
--   Baut render-at-fetch den vollstaendigen Haushalts-Notfall-Register-Ueberblick aus den estate-
--   Register-Tabellen (Vorsorge-Dokumente, Vertraege, digitaler Nachlass OHNE Passwoerter, Kontakte,
--   Stammdaten, Bestattungswuensche, Fundstellen, Sonderfall-Stubs, System-Steckbrief) UND konsumiert
--   die WS-0b-finance-Lese-fns (fn_insurance/account/liability_register) DOPPEL-GUARDET
--   (core.fn_package_active('finance') + to_regprocedure je Call-Site, docs/package-contract.md §4.2
--   Oberflaeche A) -> finance absent/fn fehlt = ehrliche Absenz-Zeile statt stiller Auslassung, nie
--   ein Crash.
--   RULE OF THREE (Plan-Critique/genericity): dies ist die EINE Register-Rendering-Logik. Zwei Konsumenten
--   rufen sie, statt sie zu duplizieren -> strukturell drift-frei:
--     * estate.fn_render_estate_overview(text) = duenner Wrapper -> fn_render_register_body(false, 'de').
--     * estate.fn_render_emergency_binder(jsonb) = Druck-Header + fn_render_register_body(mask, <Sprache>).
--   p_mask (WS-5 Maskierung): TRUE maskiert die sensibelsten Kennnummern (Steuer-ID + RV-Nr.) als
--     '••••••' — fuer eine weitergabe-taugliche Notfallmappe an Dritte; Default-Konsum (Overview,
--     vollstaendige Binder) = false (der Partner braucht die Nummern fuer die Aemter).
--   p_lang (Textkatalog Phase C): Sprache der Ueberschriften/Bezeichnungen (Katalog estate.register.*,
--     estate.gap.*; Fallback lang -> en -> Key). Gespeicherte Eintraege (Namen, Fundorte, Rechtsbegriffe der
--     directive_types) bleiben in Originalsprache. Der Binder rendert in der Sprache des Anfragenden, die
--     Overview (Modell-Kontext) fest 'de' (Verhalten des Agenten unveraendert).
--   SECURITY INVOKER + STABLE: laeuft in BEIDEN Aufrufern im DEFINER-Superuser-Kontext (Overview via
--     core.fn_fetch_context-DEFINER; Binder ist selbst DEFINER) -> sieht finance + core.ui_texts. KEIN eigenes
--     SET search_path -> erbt den Aufrufer-Pfad; ALLE Referenzen schema-qualifiziert (der Overview-DEFINER-Pin
--     hat KEIN estate/finance im Pfad -> Schema-Qualifikation ist Pflicht, empirisch geprueft).
--   RAISE-FREI; leeres Register -> ehrlicher Leer-Hinweis (nie NULL). Gap-Marker: NULL rendert als 'OFFEN'.
--   RUECKGABE: mehrzeiliger Register-Text (Schicht-5-Registerdaten; nie NULL).
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_render_register_body.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_render_register_body(p_mask boolean, p_lang text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_blocks   TEXT[] := '{}';
    v_lines    TEXT[];
    v_total    INT;
    v_fin_on   BOOLEAN;
    v_fin      TEXT[];
    v_j        JSONB;
    v_e        JSONB;
    r          RECORD;
    -- EIN Katalog-Read fuer alle Bezeichnungen (Keys vollstaendig als Literale, locale_lint prueft sie)
    t          JSONB := core.fn_ui_texts(p_lang, ARRAY[
        'estate.register.empty', 'estate.register.household', 'estate.register.directives',
        'estate.register.status_exists', 'estate.register.status_planned', 'estate.register.status_not_existing',
        'estate.register.status_missing', 'estate.register.location', 'estate.register.authorized',
        'estate.register.contracts', 'estate.register.customer_no', 'estate.register.contract_no',
        'estate.register.death_action', 'estate.register.contact', 'estate.register.open',
        'estate.register.digital', 'estate.register.key_account', 'estate.register.legacy_contact',
        'estate.register.access_location', 'estate.register.twofa_location', 'estate.register.seed_location',
        'estate.register.contacts', 'estate.register.for_person', 'estate.register.person_records',
        'estate.register.tax_id', 'estate.register.pension_no', 'estate.register.number',
        'estate.register.employer', 'estate.register.certificates', 'estate.register.funeral',
        'estate.register.burial_open', 'estate.register.prepaid', 'estate.register.yes', 'estate.register.no',
        'estate.register.unknown', 'estate.register.wishes', 'estate.register.storage', 'estate.register.access',
        'estate.register.special', 'estate.register.asset_vehicle', 'estate.register.asset_business_interest',
        'estate.register.asset_firearm', 'estate.register.asset_pet', 'estate.register.fin_insurances',
        'estate.register.type_open', 'estate.register.policy', 'estate.register.beneficiary',
        'estate.register.coverage', 'estate.register.claim_deadline', 'estate.register.none',
        'estate.register.fin_accounts', 'estate.register.ownership', 'estate.register.transmortal_poa',
        'estate.register.fin_loans', 'estate.register.remaining_debt', 'estate.register.status',
        'estate.register.fin_unavailable', 'estate.register.fin_heading', 'estate.register.fin_absent',
        'estate.register.system', 'estate.register.sys_location', 'estate.register.sys_admin',
        'estate.register.sys_backup', 'estate.register.sys_restore', 'estate.register.sys_notes',
        'estate.register.gaps', 'estate.register.gaps_none', 'estate.register.essential',
        'estate.register.fin_gap_insurance', 'estate.register.fin_gap_account', 'estate.register.fin_gap_fields',
        'estate.register.fin_gap_hint',
        'estate.gap.death_action_open', 'estate.gap.digital_action_open', 'estate.gap.key_account_no_access',
        'estate.gap.person_record_missing', 'estate.gap.funeral_missing']);
    v_hh       TEXT;
BEGIN
    v_hh := t->>'estate.register.household';
    -- ---------- Register-Stand (Summe ueber alle estate-Register) ----------
    SELECT (SELECT count(*) FROM estate.directives)
         + (SELECT count(*) FROM estate.provider_contracts)
         + (SELECT count(*) FROM estate.digital_accounts)
         + (SELECT count(*) FROM estate.contacts)
         + (SELECT count(*) FROM estate.person_records)
         + (SELECT count(*) FROM estate.funeral_preferences)
         + (SELECT count(*) FROM estate.storage_places)
         + (SELECT count(*) FROM estate.special_assets)
         + (SELECT count(*) FROM estate.system_profile)
      INTO v_total;
    IF v_total = 0 THEN
        v_blocks := v_blocks || (t->>'estate.register.empty');
    END IF;

    -- ---------- Vorsorge-Dokumente ----------
    v_lines := '{}';
    FOR r IN
        SELECT COALESCE(p.full_name, d.owner_person_id, v_hh) AS who,
               dt.label, d.doc_status, d.form, d.registry, d.location_note, d.authorized_person,
               sp.name AS storage_name
        FROM estate.directives d
        JOIN estate.directive_types dt ON dt.doc_type = d.doc_type
        LEFT JOIN agent.persons p ON p.person_id = d.owner_person_id
        LEFT JOIN estate.storage_places sp ON sp.id = d.storage_place_id
        ORDER BY COALESCE(p.full_name, v_hh), dt.ord
    LOOP
        v_lines := v_lines || (r.who || ': ' || r.label || ' — '
            || CASE r.doc_status WHEN 'exists' THEN t->>'estate.register.status_exists'
                                 WHEN 'planned' THEN t->>'estate.register.status_planned'
                                 ELSE t->>'estate.register.status_not_existing' END
            || CASE WHEN r.form IS NOT NULL THEN ' (' || r.form
                 || CASE WHEN r.registry IS NOT NULL THEN ', ' || upper(r.registry) ELSE '' END || ')'
                    WHEN r.registry IS NOT NULL THEN ' (' || upper(r.registry) || ')' ELSE '' END
            || CASE WHEN COALESCE(r.storage_name, r.location_note) IS NOT NULL
                    THEN ' · ' || (t->>'estate.register.location') || ': ' || COALESCE(r.storage_name, r.location_note) ELSE '' END
            || CASE WHEN r.authorized_person IS NOT NULL
                    THEN ' · ' || (t->>'estate.register.authorized') || ': ' || r.authorized_person ELSE '' END);
    END LOOP;
    IF array_length(v_lines, 1) IS NOT NULL THEN
        v_blocks := v_blocks || ((t->>'estate.register.directives') || ':' || E'\n- ' || array_to_string(v_lines, E'\n- '));
    END IF;

    -- ---------- Vertraege (nicht-finance) ----------
    v_lines := '{}';
    FOR r IN
        SELECT COALESCE(p.full_name, c.owner_person_id) AS who,
               c.category, c.provider, c.customer_no, c.contract_no, c.contact_info, c.death_action
        FROM estate.provider_contracts c
        LEFT JOIN agent.persons p ON p.person_id = c.owner_person_id
        ORDER BY c.category, c.provider
    LOOP
        v_lines := v_lines || (r.provider || ' (' || r.category
            || CASE WHEN r.who IS NOT NULL THEN ', ' || r.who ELSE '' END || ')'
            || CASE WHEN r.customer_no IS NOT NULL THEN ' · ' || (t->>'estate.register.customer_no') || ' ' || r.customer_no ELSE '' END
            || CASE WHEN r.contract_no IS NOT NULL THEN ' · ' || (t->>'estate.register.contract_no') || ' ' || r.contract_no ELSE '' END
            || ' · ' || (t->>'estate.register.death_action') || ': ' || COALESCE(r.death_action, t->>'estate.register.open')
            || CASE WHEN r.contact_info IS NOT NULL THEN ' · ' || (t->>'estate.register.contact') || ': ' || r.contact_info ELSE '' END);
    END LOOP;
    IF array_length(v_lines, 1) IS NOT NULL THEN
        v_blocks := v_blocks || ((t->>'estate.register.contracts') || ':' || E'\n- ' || array_to_string(v_lines, E'\n- '));
    END IF;

    -- ---------- Digitaler Nachlass (NIE Passwoerter — nur Fundort-Verweise) ----------
    v_lines := '{}';
    FOR r IN
        SELECT COALESCE(p.full_name, a.owner_person_id) AS who,
               a.category, a.provider, a.username, a.is_key_account, a.desired_action,
               a.access_path, a.legacy_contact_status, a.twofa_hint, a.seed_backup_location
        FROM estate.digital_accounts a
        LEFT JOIN agent.persons p ON p.person_id = a.owner_person_id
        ORDER BY a.is_key_account DESC, a.category, a.provider
    LOOP
        v_lines := v_lines || (r.provider || ' (' || r.category
            || CASE WHEN r.username IS NOT NULL THEN ', ' || r.username ELSE '' END
            || CASE WHEN r.who IS NOT NULL THEN ', ' || r.who ELSE '' END || ')'
            || CASE WHEN r.is_key_account THEN ' · ' || (t->>'estate.register.key_account') ELSE '' END
            || ' · ' || (t->>'estate.register.death_action') || ': ' || COALESCE(r.desired_action, t->>'estate.register.open')
            || CASE WHEN r.legacy_contact_status IS NOT NULL
                    THEN ' · ' || (t->>'estate.register.legacy_contact') || ': ' || r.legacy_contact_status ELSE '' END
            || CASE WHEN r.access_path IS NOT NULL THEN ' · ' || (t->>'estate.register.access_location') || ': ' || r.access_path ELSE '' END
            || CASE WHEN r.twofa_hint IS NOT NULL THEN ' · ' || (t->>'estate.register.twofa_location') || ': ' || r.twofa_hint ELSE '' END
            || CASE WHEN r.seed_backup_location IS NOT NULL
                    THEN ' · ' || (t->>'estate.register.seed_location') || ': ' || r.seed_backup_location ELSE '' END);
    END LOOP;
    IF array_length(v_lines, 1) IS NOT NULL THEN
        v_blocks := v_blocks || ((t->>'estate.register.digital') || ':' || E'\n- ' || array_to_string(v_lines, E'\n- '));
    END IF;

    -- ---------- Schluessel-Kontakte ----------
    v_lines := '{}';
    FOR r IN
        SELECT c.role, c.name, c.organization, c.phone, c.email,
               COALESCE(p.full_name, c.owner_person_id) AS who
        FROM estate.contacts c
        LEFT JOIN agent.persons p ON p.person_id = c.owner_person_id
        ORDER BY c.role, c.name
    LOOP
        v_lines := v_lines || (r.role || ': ' || r.name
            || CASE WHEN r.organization IS NOT NULL THEN ' (' || r.organization || ')' ELSE '' END
            || CASE WHEN r.who IS NOT NULL THEN ' · ' || (t->>'estate.register.for_person') || ': ' || r.who ELSE '' END
            || CASE WHEN r.phone IS NOT NULL THEN ' · ' || r.phone ELSE '' END
            || CASE WHEN r.email IS NOT NULL THEN ' · ' || r.email ELSE '' END);
    END LOOP;
    IF array_length(v_lines, 1) IS NOT NULL THEN
        v_blocks := v_blocks || ((t->>'estate.register.contacts') || ':' || E'\n- ' || array_to_string(v_lines, E'\n- '));
    END IF;

    -- ---------- Amtliche Stammdaten je Person (WS-5: Steuer-ID + RV-Nr. bei p_mask maskiert) ----------
    v_lines := '{}';
    FOR r IN
        SELECT COALESCE(p.full_name, pr.person_id) AS who,
               pr.tax_id, pr.pension_insurance_no, pr.health_insurance_type,
               pr.health_insurance_name, pr.health_insurance_no, pr.employer, pr.certificates_location
        FROM estate.person_records pr
        LEFT JOIN agent.persons p ON p.person_id = pr.person_id
        ORDER BY 1
    LOOP
        v_lines := v_lines || (r.who || ':'
            || CASE WHEN r.tax_id IS NOT NULL
                    THEN ' ' || (t->>'estate.register.tax_id') || ' ' || CASE WHEN p_mask THEN '••••••' ELSE r.tax_id END ELSE '' END
            || CASE WHEN r.pension_insurance_no IS NOT NULL
                    THEN ' · ' || (t->>'estate.register.pension_no') || ' ' || CASE WHEN p_mask THEN '••••••' ELSE r.pension_insurance_no END ELSE '' END
            || CASE WHEN r.health_insurance_type IS NOT NULL
                    THEN ' · ' || upper(r.health_insurance_type)
                      || CASE WHEN r.health_insurance_name IS NOT NULL THEN ' (' || r.health_insurance_name
                           || CASE WHEN r.health_insurance_no IS NOT NULL THEN ', ' || (t->>'estate.register.number') || ' ' || r.health_insurance_no ELSE '' END || ')'
                              ELSE '' END
                    ELSE '' END
            || CASE WHEN r.employer IS NOT NULL THEN ' · ' || (t->>'estate.register.employer') || ': ' || r.employer ELSE '' END
            || CASE WHEN r.certificates_location IS NOT NULL THEN ' · ' || (t->>'estate.register.certificates') || ': ' || r.certificates_location ELSE '' END);
    END LOOP;
    IF array_length(v_lines, 1) IS NOT NULL THEN
        v_blocks := v_blocks || ((t->>'estate.register.person_records') || ':' || E'\n- ' || array_to_string(v_lines, E'\n- '));
    END IF;

    -- ---------- Bestattungswuensche ----------
    v_lines := '{}';
    FOR r IN
        SELECT COALESCE(p.full_name, f.person_id) AS who,
               f.burial_type, f.has_prepaid_contract, f.prepaid_contract_provider, f.wishes
        FROM estate.funeral_preferences f
        LEFT JOIN agent.persons p ON p.person_id = f.person_id
        ORDER BY 1
    LOOP
        v_lines := v_lines || (r.who || ': '
            || COALESCE(initcap(r.burial_type), t->>'estate.register.burial_open')
            || ' · ' || (t->>'estate.register.prepaid') || ': '
            || CASE WHEN r.has_prepaid_contract IS TRUE
                    THEN (t->>'estate.register.yes') || CASE WHEN r.prepaid_contract_provider IS NOT NULL
                                                             THEN ' (' || r.prepaid_contract_provider || ')' ELSE '' END
                    WHEN r.has_prepaid_contract IS FALSE THEN t->>'estate.register.no'
                    ELSE t->>'estate.register.unknown' END
            || CASE WHEN r.wishes IS NOT NULL THEN ' · ' || (t->>'estate.register.wishes') || ': ' || r.wishes ELSE '' END);
    END LOOP;
    IF array_length(v_lines, 1) IS NOT NULL THEN
        v_blocks := v_blocks || ((t->>'estate.register.funeral') || ':' || E'\n- ' || array_to_string(v_lines, E'\n- '));
    END IF;

    -- ---------- Fundstellen ----------
    v_lines := '{}';
    FOR r IN
        SELECT s.name, s.kind, s.location, s.access_hint,
               COALESCE(p.full_name, s.owner_person_id) AS who
        FROM estate.storage_places s
        LEFT JOIN agent.persons p ON p.person_id = s.owner_person_id
        ORDER BY s.name
    LOOP
        v_lines := v_lines || (r.name || ' (' || r.kind
            || CASE WHEN r.location IS NOT NULL THEN ', ' || r.location ELSE '' END
            || CASE WHEN r.who IS NOT NULL THEN ', ' || r.who ELSE '' END || ')'
            || CASE WHEN r.access_hint IS NOT NULL THEN ' · ' || (t->>'estate.register.access') || ': ' || r.access_hint ELSE '' END);
    END LOOP;
    IF array_length(v_lines, 1) IS NOT NULL THEN
        v_blocks := v_blocks || ((t->>'estate.register.storage') || ':' || E'\n- ' || array_to_string(v_lines, E'\n- '));
    END IF;

    -- ---------- Sonderfaelle (Stubs — erkennen + ehrlich verweisen, Owner-Entscheid 7) ----------
    v_lines := '{}';
    FOR r IN
        SELECT COALESCE(p.full_name, s.owner_person_id) AS who, s.asset_type, s.description
        FROM estate.special_assets s
        LEFT JOIN agent.persons p ON p.person_id = s.owner_person_id
        ORDER BY s.asset_type, s.description
    LOOP
        v_lines := v_lines || (CASE r.asset_type WHEN 'vehicle' THEN t->>'estate.register.asset_vehicle'
                                                 WHEN 'business_interest' THEN t->>'estate.register.asset_business_interest'
                                                 WHEN 'firearm' THEN t->>'estate.register.asset_firearm'
                                                 ELSE t->>'estate.register.asset_pet' END
            || ': ' || r.description
            || CASE WHEN r.who IS NOT NULL THEN ' (' || r.who || ')' ELSE '' END);
    END LOOP;
    IF array_length(v_lines, 1) IS NOT NULL THEN
        v_blocks := v_blocks || ((t->>'estate.register.special') || ':' || E'\n- ' || array_to_string(v_lines, E'\n- '));
    END IF;

    -- ---------- Finanz-Register (finance-Paket, §4.2 Oberflaeche A — DOPPEL-GUARD je Call-Site) ----------
    -- Stammdaten leben bei finance (Grenzregel); hier nur die nachlass-relevante Lese-Sicht. Absenz
    -- (Paket inaktiv ODER Provider-fn fehlt) wird SICHTBAR gemeldet, nie still ausgelassen.
    v_fin_on := core.fn_package_active('finance');
    IF v_fin_on THEN
        v_fin := '{}';
        IF to_regprocedure('finance.fn_insurance_register()') IS NOT NULL THEN
            EXECUTE 'SELECT finance.fn_insurance_register()' INTO v_j;
            v_lines := '{}';
            FOR v_e IN SELECT * FROM jsonb_array_elements(COALESCE(v_j, '[]'::jsonb)) LOOP
                v_lines := v_lines || ((v_e->>'name')
                    || ' (' || COALESCE(v_e->>'insurance_type', t->>'estate.register.type_open')
                    || CASE WHEN v_e->>'insurance_company' IS NOT NULL THEN ', ' || (v_e->>'insurance_company') ELSE '' END || ')'
                    || CASE WHEN v_e->>'policy_number' IS NOT NULL THEN ' · ' || (t->>'estate.register.policy') || ' ' || (v_e->>'policy_number') ELSE '' END
                    || ' · ' || (t->>'estate.register.beneficiary') || ': ' || COALESCE(v_e->>'beneficiary', t->>'estate.register.open')
                    || CASE WHEN v_e->>'coverage_amount' IS NOT NULL THEN ' · ' || (t->>'estate.register.coverage') || ' ' || (v_e->>'coverage_amount') ELSE '' END
                    || CASE WHEN v_e->>'claim_deadline_hours' IS NOT NULL
                            THEN ' · ' || (t->>'estate.register.claim_deadline') || ' ' || (v_e->>'claim_deadline_hours') || ' h!' ELSE '' END);
            END LOOP;
            v_fin := v_fin || ((t->>'estate.register.fin_insurances') || ':' ||
                CASE WHEN array_length(v_lines, 1) IS NULL THEN ' ' || (t->>'estate.register.none')
                     ELSE E'\n- ' || array_to_string(v_lines, E'\n- ') END);
        END IF;
        IF to_regprocedure('finance.fn_account_register()') IS NOT NULL THEN
            EXECUTE 'SELECT finance.fn_account_register()' INTO v_j;
            v_lines := '{}';
            FOR v_e IN SELECT * FROM jsonb_array_elements(COALESCE(v_j, '[]'::jsonb)) LOOP
                v_lines := v_lines || ((v_e->>'name')
                    || ' (' || COALESCE(v_e->>'account_type', '?')
                    || CASE WHEN v_e->>'bank' IS NOT NULL THEN ', ' || (v_e->>'bank') ELSE '' END || ')'
                    || CASE WHEN v_e->>'account_number' IS NOT NULL THEN ' · ' || (t->>'estate.register.number') || ' ' || (v_e->>'account_number') ELSE '' END
                    || ' · ' || (t->>'estate.register.ownership') || ': ' || COALESCE(v_e->>'ownership', t->>'estate.register.open')
                    || ' · ' || (t->>'estate.register.transmortal_poa') || ': '
                    || CASE WHEN (v_e->>'has_transmortal_poa')::boolean IS TRUE THEN t->>'estate.register.yes'
                            WHEN (v_e->>'has_transmortal_poa')::boolean IS FALSE THEN t->>'estate.register.no'
                            ELSE t->>'estate.register.open' END);
            END LOOP;
            v_fin := v_fin || ((t->>'estate.register.fin_accounts') || ':' ||
                CASE WHEN array_length(v_lines, 1) IS NULL THEN ' ' || (t->>'estate.register.none')
                     ELSE E'\n- ' || array_to_string(v_lines, E'\n- ') END);
        END IF;
        IF to_regprocedure('finance.fn_liability_register()') IS NOT NULL THEN
            EXECUTE 'SELECT finance.fn_liability_register()' INTO v_j;
            v_lines := '{}';
            FOR v_e IN SELECT * FROM jsonb_array_elements(COALESCE(v_j, '[]'::jsonb)) LOOP
                v_lines := v_lines || ((v_e->>'name')
                    || CASE WHEN v_e->>'lender' IS NOT NULL THEN ' (' || (v_e->>'lender') || ')' ELSE '' END
                    || CASE WHEN v_e->>'current_remaining_debt_eur' IS NOT NULL
                            THEN ' · ' || (t->>'estate.register.remaining_debt') || ' ~' || (v_e->>'current_remaining_debt_eur') || ' EUR' ELSE '' END
                    || ' · ' || (t->>'estate.register.status') || ': ' || COALESCE(v_e->>'status', '?'));
            END LOOP;
            v_fin := v_fin || ((t->>'estate.register.fin_loans') || ':' ||
                CASE WHEN array_length(v_lines, 1) IS NULL THEN ' ' || (t->>'estate.register.none')
                     ELSE E'\n- ' || array_to_string(v_lines, E'\n- ') END);
        END IF;
        IF array_length(v_fin, 1) IS NULL THEN
            -- Paket aktiv, aber KEINE Provider-fn auffindbar (Drift) -> wie Absenz sichtbar melden.
            v_blocks := v_blocks || (t->>'estate.register.fin_unavailable');
        ELSE
            v_blocks := v_blocks || ((t->>'estate.register.fin_heading') || ':' || E'\n' || array_to_string(v_fin, E'\n'));
        END IF;
    ELSE
        v_blocks := v_blocks || (t->>'estate.register.fin_absent');
    END IF;

    -- ---------- System-Steckbrief & Notfall-Zugang (WS-5 — DR-Info fuer den Hinterbliebenen) ----------
    -- Household-Singleton (0/1 Zeile). Nur Fundort-Verweise (nie Passwoerter/Schluessel). Der
    -- backup_key-Fundort deckt den Fall "beide Partner betroffen / System aus" (Owner-Entscheid 9).
    v_lines := '{}';
    FOR r IN SELECT backup_key_location, system_location, admin_access, restore_hint, notes
             FROM estate.system_profile
    LOOP
        IF r.system_location     IS NOT NULL THEN v_lines := v_lines || ((t->>'estate.register.sys_location') || ': ' || r.system_location); END IF;
        IF r.admin_access        IS NOT NULL THEN v_lines := v_lines || ((t->>'estate.register.sys_admin') || ': ' || r.admin_access); END IF;
        IF r.backup_key_location IS NOT NULL THEN v_lines := v_lines || ((t->>'estate.register.sys_backup') || ': ' || r.backup_key_location); END IF;
        IF r.restore_hint        IS NOT NULL THEN v_lines := v_lines || ((t->>'estate.register.sys_restore') || ': ' || r.restore_hint); END IF;
        IF r.notes               IS NOT NULL THEN v_lines := v_lines || ((t->>'estate.register.sys_notes') || ': ' || r.notes); END IF;
    END LOOP;
    IF array_length(v_lines, 1) IS NOT NULL THEN
        v_blocks := v_blocks || ((t->>'estate.register.system') || ':' || E'\n- ' || array_to_string(v_lines, E'\n- '));
    END IF;

    -- ---------- Luecken (Gap-Report, WS-2 — EINE Quelle: estate.fn_gap_report) ----------
    -- Erwartungsmenge = essential+recommended je ERWACHSENEM (Haushalts-Urkunde deckt beide);
    -- + offene Feld-/Zeilen-Luecken + konkrete finance-Feld-Gaps (doppel-guardet in der fn).
    -- Im DEFINER-Kontext ist finance lesbar -> hier erscheint der volle Gap-Blick.
    v_j := estate.fn_gap_report();
    v_lines := '{}';
    FOR v_e IN SELECT * FROM jsonb_array_elements(v_j->'directive_gaps') LOOP
        v_lines := v_lines || ((v_e->>'full_name') || ': ' || (v_e->>'label') || ' — '
            || CASE v_e->>'status' WHEN 'missing' THEN t->>'estate.register.status_missing'
                                   WHEN 'planned' THEN t->>'estate.register.status_planned'
                                   ELSE t->>'estate.register.status_not_existing' END
            || CASE WHEN v_e->>'recommendation' = 'essential' THEN ' ' || (t->>'estate.register.essential') ELSE '' END);
    END LOOP;
    FOR v_e IN SELECT * FROM jsonb_array_elements(v_j->'register_gaps') LOOP
        -- gap_code -> Katalog (vollstaendige Literale); unbekannter Code -> englischer Modelltext der View
        v_lines := v_lines || ((v_e->>'item') || ': ' || COALESCE(CASE v_e->>'gap_code'
            WHEN 'death_action_open'     THEN t->>'estate.gap.death_action_open'
            WHEN 'digital_action_open'   THEN t->>'estate.gap.digital_action_open'
            WHEN 'key_account_no_access' THEN t->>'estate.gap.key_account_no_access'
            WHEN 'person_record_missing' THEN t->>'estate.gap.person_record_missing'
            WHEN 'funeral_missing'       THEN t->>'estate.gap.funeral_missing' END, v_e->>'gap'));
    END LOOP;
    FOR v_e IN SELECT * FROM jsonb_array_elements(v_j->'finance'->'gaps') LOOP
        v_lines := v_lines || ((v_e->>'item') || ' (finance-' ||
            CASE v_e->>'area' WHEN 'insurance' THEN t->>'estate.register.fin_gap_insurance' ELSE t->>'estate.register.fin_gap_account' END
            || '): ' || (t->>'estate.register.fin_gap_fields') || ' — '
            || (SELECT string_agg(x, ', ') FROM jsonb_array_elements_text(v_e->'missing_fields') AS mf(x))
            || ' ' || (t->>'estate.register.fin_gap_hint'));
    END LOOP;
    IF array_length(v_lines, 1) IS NOT NULL THEN
        v_blocks := v_blocks || ((t->>'estate.register.gaps') || ':' || E'\n- ' || array_to_string(v_lines, E'\n- '));
    ELSE
        v_blocks := v_blocks || (t->>'estate.register.gaps_none');
    END IF;

    RETURN array_to_string(v_blocks, E'\n\n');
END;
$$;
