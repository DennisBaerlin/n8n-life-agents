-- ============================================================
-- Estate-Paket — Schema "estate" (Baseline-Init, idempotent)
--   WS-0a Geruest (Plan groovy-watching-wave): das Vorsorge-/Nachlass-REGISTER — Vorsorge-Dokumente,
--   Nicht-finance-Vertraege, digitaler Nachlass, Schluessel-Kontakte, Stammdaten, Bestattungswuensche,
--   Fundstellen, Sonderfall-Stubs + household-Onboarding-State. OHNE Ereignisfall (cases/case_tasks/
--   task_templates = WS-3), OHNE Agent (WS-1), OHNE Write-fns (WS-2).
--   GRENZREGEL (Owner-Entscheid 2/5): Produkt-Attribute (Versicherungen, Konten) leben bei FINANCE;
--   estate haelt Prozess-/Fundort-/Wunsch-Attribute + lose Referenzen — NIE Kopien, NIE Cross-Schema-FKs
--   (FK nur auf agent.persons + estate-intern). GEHEIMNISSE NIE: keine Passwoerter/PINs/Seeds —
--   ausschliesslich Fundort-VERWEISE (die Spalten-Kommentare + WS-2-Tool-Descriptions tragen das).
--   Usage: db_apply.ps1 -File packages/estate/db/estate.tables_init.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS estate;

-- ============================================================
-- Generischer updated_at-Touch-Trigger (paket-lokal, Muster career/finance.touch_updated_at).
--   Paket-lokal (nicht core/shared), weil die engen Paket-Rollen kein Cross-Schema-EXECUTE haben
--   und ein Paket sein eigenes Schema voll besitzt (D10).
-- ============================================================
CREATE OR REPLACE FUNCTION estate.touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at := NOW(); RETURN NEW; END; $$;

-- ============================================================
-- DIRECTIVE_TYPES (Seed-Katalog, dev-besessen) — die 9 deutschen Vorsorge-Dokumenttypen.
--   doc_type = deutscher Rechtsbegriff als stabiler Schluessel (Sprachpolitik: Steuer-/Rechtsbegriffe
--   bleiben Deutsch; identisch zu den Plan-/Recherche-Begriffen). FK-Ziel von estate.directives ->
--   Tippfehler werden FK-Fehler (Muster finance.currencies).
--   recommendation = Empfehlungsklasse fuer die Gap-Analyse (WS-2 fn_gap_report): 'essential' +
--   'recommended' bilden die ERWARTUNGSMENGE je ERWACHSENEM Haushaltsmitglied (Minderjaehrigen-
--   Gap-Nudges waeren rechtlich unsinnig — Testierfaehigkeit ab 16, Vorsorgevollmacht ab 18);
--   'situational' wird NIE genudgt (nur situativ relevant: Erbvertrag als Testament-Alternative,
--   Sorgerechtsverfuegung nur bei minderjaehrigen Kindern, Organspende ist persoenliche Wahl).
--   Einstufung nach verbraucherzentrale.de-Vorsorge-Trio (Vorsorgevollmacht/Patientenverfuegung/
--   Betreuungsverfuegung) + Recherche-Synthese des Plans.
--   SEED per ON CONFLICT DO UPDATE (nicht DO NOTHING wie currencies): der Katalog ist DEV-besessen
--   (arch-challenge P4a) — Label-/Einstufungs-Korrekturen muessen Bestands-Substrate per Re-Apply
--   erreichen; Nutzer erweitern ihn nie (kein Write-Tool auf dieser Tabelle).
-- ============================================================
CREATE TABLE IF NOT EXISTS estate.directive_types (
    doc_type       text NOT NULL PRIMARY KEY CHECK (doc_type ~ '^[a-z_]+$'),
    label          text NOT NULL,   -- deutsches Anzeige-Label (Schicht 5 Originalsprache)
    recommendation text NOT NULL CHECK (recommendation IN ('essential', 'recommended', 'situational')),
    ord            int  NOT NULL    -- stabile Anzeige-Reihenfolge im Register/Gap-Report
);

INSERT INTO estate.directive_types (doc_type, label, recommendation, ord) VALUES
    ('testament',                 'Testament',                  'essential',   10),
    ('vorsorgevollmacht',         'Vorsorgevollmacht',          'essential',   20),
    ('patientenverfuegung',       'Patientenverfügung',         'essential',   30),
    ('bankvollmacht_transmortal', 'Transmortale Bankvollmacht', 'recommended', 40),
    ('betreuungsverfuegung',      'Betreuungsverfügung',        'recommended', 50),
    ('erbvertrag',                'Erbvertrag',                 'situational', 60),
    ('bestattungsverfuegung',     'Bestattungsverfügung',       'situational', 70),
    ('sorgerechtsverfuegung',     'Sorgerechtsverfügung',       'situational', 80),
    ('organspendeausweis',        'Organspendeausweis',         'situational', 90)
ON CONFLICT (doc_type) DO UPDATE
    SET label = excluded.label, recommendation = excluded.recommendation, ord = excluded.ord;

-- ============================================================
-- STORAGE_PLACES — Fundstellen (Tresor/Bankschliessfach/Ordner/digital).
--   Vor den Registern definiert (directives referenziert sie per FK). access_hint = WIE man
--   rankommt ("Schluessel im Sekretaer"), NIE Codes/PINs (Owner-Entscheid 2; Inhalt ist per DB
--   nicht pruefbar -> WS-2-Tool-Description + Instructions tragen die Hard-Rule).
--   owner_person_id NULL = Haushalts-Fundstelle (Muster finance *_person_id: NULL=Haushalt).
-- ============================================================
CREATE TABLE IF NOT EXISTS estate.storage_places (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_person_id text REFERENCES agent.persons(person_id) ON DELETE RESTRICT,
    name            text NOT NULL,
    kind            text NOT NULL CHECK (kind IN ('safe', 'bank_deposit_box', 'folder', 'digital', 'other')),
    location        text,            -- wo (Raum/Filiale/Pfad)
    access_hint     text,            -- Zugangs-Hinweis OHNE Codes/PINs (nur Verweis)
    notes           text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_storage_places_touch ON estate.storage_places;
CREATE TRIGGER trg_storage_places_touch BEFORE UPDATE ON estate.storage_places
    FOR EACH ROW EXECUTE FUNCTION estate.touch_updated_at();

-- ============================================================
-- DIRECTIVES — das Dokumente-REGISTER (nur Metadaten, nie Inhalte).
--   * owner_person_id NULLABLE, BEGRUENDET: gemeinschaftliche Urkunden (Berliner Testament,
--     Erbvertrag beider Partner) sind EIN Dokument des HAUSHALTS -> NULL. Person-eigene Dokumente
--     tragen den Slug (FK agent.persons RESTRICT — eine referenzierte Person ist aus `family`
--     nicht entfernbar, Muster finance).
--   * UNIQUE(owner_person_id, doc_type) NULLS NOT DISTINCT (PG15+): genau EIN Registereintrag je
--     (Person|Haushalt, Dokumenttyp). OHNE NULLS NOT DISTINCT waeren zwei Haushalts-Testamente
--     beide einfuegbar (NULL-UNIQUE-Falle, Lektion advisor_plans P0c) — das ist zugleich der
--     kuenftige UPSERT-Key von record_directive (WS-2).
--   * doc_status: 'exists' (liegt vor) / 'does_not_exist' (bewusst erfasst: gibt es nicht ->
--     ehrlicher Gap) / 'planned' (in Arbeit). KEIN Default — der Status ist die Kern-Aussage
--     des Eintrags, das Tool muss ihn explizit setzen.
--   * form: privat/notariell/amtlich (notarielle Urkunde macht den Erbschein oft ueberfluessig —
--     Beratungs-Wissen, WS-1 Instructions). registry: ZTR (Zentrales Testamentsregister) /
--     ZVR (Zentrales Vorsorgeregister), NULL = nicht registriert/unbekannt.
--   * storage_place_id RESTRICT: eine Fundstelle mit Dokumenten ist nicht loeschbar (Ledger-FK-
--     Politik); location_note = freier Fundort-Text ohne Fundstellen-Zeile.
--   * authorized_person FREITEXT (nicht FK): Bevollmaechtigte koennen Haushalts-EXTERNE sein
--     (Geschwister, Freund) — agent.persons deckt nur den Haushalt.
-- ============================================================
CREATE TABLE IF NOT EXISTS estate.directives (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_person_id   text REFERENCES agent.persons(person_id) ON DELETE RESTRICT,   -- NULL = Haushalt (gemeinschaftliche Urkunde)
    doc_type          text NOT NULL REFERENCES estate.directive_types(doc_type) ON DELETE RESTRICT,
    doc_status        text NOT NULL CHECK (doc_status IN ('exists', 'does_not_exist', 'planned')),
    form              text CHECK (form IN ('privat', 'notariell', 'amtlich')),
    registry          text CHECK (registry IN ('ztr', 'zvr')),                        -- NULL = nicht registriert/unbekannt
    storage_place_id  bigint REFERENCES estate.storage_places(id) ON DELETE RESTRICT,
    location_note     text,            -- freier Fundort-Text (ohne storage_places-Zeile)
    authorized_person text,            -- bevollmaechtigte Person (Freitext, darf haushalts-extern sein)
    notes             text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE NULLS NOT DISTINCT (owner_person_id, doc_type)
);

DROP TRIGGER IF EXISTS trg_directives_touch ON estate.directives;
CREATE TRIGGER trg_directives_touch BEFORE UPDATE ON estate.directives
    FOR EACH ROW EXECUTE FUNCTION estate.touch_updated_at();

-- ============================================================
-- PROVIDER_CONTRACTS — Nicht-finance-Vertraege (Anbieter, Kundennummern, Todesfall-Aktion).
--   Versicherungs-/Konto-STAMMDATEN leben bei finance (Grenzregel oben); hier stehen die Vertraege,
--   die finance nicht fuehrt (Energie/Telekom/Abos/Vereine/Wohnen) + die PROZESS-Attribute.
--   * death_action: cancel (Sonderkuendigung §§ 563 f. BGB u. ae.) / transfer (auf Partner
--     umschreiben) / keep. NULL = offener GAP — die Gap-Analyse (WS-2) nudgt genau darauf.
--   * finance_recurring_payment_id: LOSE Referenz auf finance.recurring_payments.id OHNE FK
--     (Cross-Schema-FK verboten, finance ist optionale Dependency §4.2): eine stale ID ist
--     eine GAP-ANZEIGE im Rendering, nie ein Crash (Doppel-Guard deckt nur Paket-Absenz).
-- ============================================================
CREATE TABLE IF NOT EXISTS estate.provider_contracts (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_person_id text REFERENCES agent.persons(person_id) ON DELETE RESTRICT,     -- NULL = Haushalt
    category        text NOT NULL CHECK (category IN
                        ('utilities', 'telecom', 'media', 'subscription', 'membership', 'housing', 'mobility', 'other')),
    provider        text NOT NULL,
    customer_no     text,
    contract_no     text,
    contact_info    text,            -- Hotline/Portal/E-Mail des Anbieters
    death_action    text CHECK (death_action IN ('cancel', 'transfer', 'keep')),     -- NULL = offener Gap
    finance_recurring_payment_id bigint,   -- lose Referenz OHNE FK (stale = Gap-Anzeige, nie Crash)
    notes           text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_provider_contracts_touch ON estate.provider_contracts;
CREATE TRIGGER trg_provider_contracts_touch BEFORE UPDATE ON estate.provider_contracts
    FOR EACH ROW EXECUTE FUNCTION estate.touch_updated_at();

-- ============================================================
-- DIGITAL_ACCOUNTS — digitaler Nachlass OHNE Passwoerter (Owner-Entscheid 2).
--   * is_key_account: das SCHLUESSELKONTO (v. a. E-Mail) — dessen Verlust sperrt Resets aller
--     anderen Konten; der Ereignisfall (WS-3) priorisiert Key-Accounts.
--   * desired_action: delete/memorialize (Gedenkzustand, z. B. Facebook — irreversibel!)/
--     transfer/keep. NULL = offener Gap.
--   * legacy_contact_status: Nachlass-Funktion des Anbieters (Google Inactive Account Manager,
--     Facebook Legacy Contact, Apple Legacy Contact): configured/not_configured/unavailable,
--     NULL = unbekannt.
--   * access_path = FUNDORT-Verweis auf den Zugang ("Passwort-Manager X, Master-Passwort im
--     Tresor"), twofa_hint = 2FA-Geraet/Backup-Codes-FUNDORT — beides nie das Geheimnis selbst.
--   * seed_backup_location NUR fuer category='crypto' (CHECK-Kopplung): der FUNDORT des
--     Seed-Phrase-Backups (Metallplatte/Schliessfach). Die Seed-Phrase selbst gehoert NIE ins
--     System/Testament (Recherche: Nachlass-Fallstricke).
-- ============================================================
CREATE TABLE IF NOT EXISTS estate.digital_accounts (
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_person_id       text REFERENCES agent.persons(person_id) ON DELETE RESTRICT,   -- NULL = Haushalt (geteilte Konten)
    category              text NOT NULL CHECK (category IN
                              ('email', 'social', 'cloud', 'finance', 'crypto', 'commerce', 'media', 'other')),
    provider              text NOT NULL,
    username              text,
    is_key_account        boolean NOT NULL DEFAULT FALSE,
    desired_action        text CHECK (desired_action IN ('delete', 'memorialize', 'transfer', 'keep')),   -- NULL = Gap
    access_path           text,      -- Fundort-Verweis auf den Zugang (nie das Passwort)
    legacy_contact_status text CHECK (legacy_contact_status IN ('configured', 'not_configured', 'unavailable')),
    twofa_hint            text,      -- 2FA-Geraet/Backup-Codes-Fundort (nie die Codes)
    seed_backup_location  text CHECK (seed_backup_location IS NULL OR category = 'crypto'),
    notes                 text,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_digital_accounts_touch ON estate.digital_accounts;
CREATE TRIGGER trg_digital_accounts_touch BEFORE UPDATE ON estate.digital_accounts
    FOR EACH ROW EXECUTE FUNCTION estate.touch_updated_at();

-- ============================================================
-- CONTACTS — Schluessel-Kontakte des Ereignis-/Vorsorgefalls.
--   role = geschlossene Liste (Plan): der Ereignisfall (WS-3) referenziert Rollen deterministisch
--   ("Kontaktiere den Bestatter"). KEIN UNIQUE auf role: mehrere trusted_person/physician sind
--   legitim. employer_hr ist person-gebunden -> owner_person_id (NULL = Haushalts-Kontakt).
-- ============================================================
CREATE TABLE IF NOT EXISTS estate.contacts (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_person_id text REFERENCES agent.persons(person_id) ON DELETE RESTRICT,     -- NULL = Haushalt
    role            text NOT NULL CHECK (role IN
                        ('notary', 'tax_advisor', 'lawyer', 'physician', 'undertaker', 'employer_hr', 'landlord', 'trusted_person')),
    name            text NOT NULL,
    organization    text,
    phone           text,
    email           text,
    address         text,
    notes           text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_contacts_touch ON estate.contacts;
CREATE TRIGGER trg_contacts_touch BEFORE UPDATE ON estate.contacts
    FOR EACH ROW EXECUTE FUNCTION estate.touch_updated_at();

-- ============================================================
-- PERSON_RECORDS — amtliche Stammdaten je Person (1 Zeile je Person, PK person_id).
--   Der Ereignisfall braucht sie SOFORT (Sterbefallanzeige, Renten-/Krankenkassen-Meldung).
--   Format-CHECKs = Gesetz (das LLM validiert nie): Steuer-ID = 11 Ziffern (§ 139b AO);
--   RV-Nummer = 2 Ziffern Bereichsnummer + 6 Ziffern Geburtsdatum + Grossbuchstabe
--   (Anfangsbuchstabe Geburtsname) + 3 Ziffern (Serie/Pruefziffer) -> ^\d{8}[A-Z]\d{3}$
--   (kanonisch OHNE Leerzeichen gespeichert; das WS-2-Tool normalisiert die Eingabe).
--   certificates_location = Fundort Stammbuch/Geburts-/Heiratsurkunden (Freitext-Verweis).
-- ============================================================
CREATE TABLE IF NOT EXISTS estate.person_records (
    person_id             text NOT NULL PRIMARY KEY REFERENCES agent.persons(person_id) ON DELETE RESTRICT,
    tax_id                text CHECK (tax_id ~ '^[0-9]{11}$'),
    pension_insurance_no  text CHECK (pension_insurance_no ~ '^[0-9]{8}[A-Z][0-9]{3}$'),
    health_insurance_type text CHECK (health_insurance_type IN ('gkv', 'pkv')),
    health_insurance_name text,
    health_insurance_no   text,
    employer              text,
    certificates_location text,      -- Fundort Stammbuch/Urkunden (Verweis)
    notes                 text,
    last_reviewed_at      timestamptz,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_person_records_touch ON estate.person_records;
CREATE TRIGGER trg_person_records_touch BEFORE UPDATE ON estate.person_records
    FOR EACH ROW EXECUTE FUNCTION estate.touch_updated_at();

-- ============================================================
-- FUNERAL_PREFERENCES — Bestattungswuensche (1 Zeile je Person, PK person_id).
--   burial_type = deutsche Bestattungsarten (Schicht-5-Domaenenwerte, wie doc_type);
--   has_prepaid_contract NULLABLE = Tri-State (NULL = unbekannt/nicht erfasst) — ein
--   Bestattungs-VORSORGEVERTRAG (+ Anbieter) spart dem Partner im Ereignisfall die
--   teuerste Ad-hoc-Entscheidung.
-- ============================================================
CREATE TABLE IF NOT EXISTS estate.funeral_preferences (
    person_id                 text NOT NULL PRIMARY KEY REFERENCES agent.persons(person_id) ON DELETE RESTRICT,
    burial_type               text CHECK (burial_type IN
                                  ('erdbestattung', 'feuerbestattung', 'seebestattung', 'baumbestattung', 'sonstige')),
    has_prepaid_contract      boolean,     -- NULL = unbekannt (Tri-State)
    prepaid_contract_provider text,
    wishes                    text,
    created_at                timestamptz NOT NULL DEFAULT now(),
    updated_at                timestamptz NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_funeral_preferences_touch ON estate.funeral_preferences;
CREATE TRIGGER trg_funeral_preferences_touch BEFORE UPDATE ON estate.funeral_preferences
    FOR EACH ROW EXECUTE FUNCTION estate.touch_updated_at();

-- ============================================================
-- SPECIAL_ASSETS — Sonderfall-Stubs (Owner-Entscheid 7: erkennen + ehrlich verweisen).
--   Geschlossene asset_type-Liste: jeder Typ mappt auf eine Checklisten-Condition des
--   Ereignisfalls (WS-3 task_templates.condition_key) + einen Verweis-Baustein (Notar/Anwalt/StB,
--   RDG-Disclaimer): vehicle (Umschreibung/Versicherung), business_interest (GmbH-Anteile ->
--   Gesellschaftsvertrag vor Erbrecht), firearm (§ 20 WaffG: 1 Monat!), pet (Versorgung).
--   BEWUSST kein 'other' — ein offener Typ haette keine Condition und wuerde still nichts ausloesen.
-- ============================================================
CREATE TABLE IF NOT EXISTS estate.special_assets (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_person_id text REFERENCES agent.persons(person_id) ON DELETE RESTRICT,     -- NULL = Haushalt
    asset_type      text NOT NULL CHECK (asset_type IN ('vehicle', 'business_interest', 'firearm', 'pet')),
    description     text NOT NULL,
    notes           text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_special_assets_touch ON estate.special_assets;
CREATE TRIGGER trg_special_assets_touch BEFORE UPDATE ON estate.special_assets
    FOR EACH ROW EXECUTE FUNCTION estate.touch_updated_at();

-- ============================================================
-- ONBOARDING-FORTSCHRITT — household-Form (PK section_key), byte-gleich finance/guide.
--   Estate-Onboarding ist HAUSHALTS-Sache (EIN Register, symmetrisch — Owner-Entscheid 3),
--   anders als career (per-person). Sektionen kommen aus packages/estate/onboarding/sections.json
--   (WS-1, Host-Seeder _seed_onboarding_sections); gelesen/geschrieben ueber die geteilten
--   Core-Onboarding-fns. KEIN Pflicht-Gate am Agenten (arch-challenge P3: fail-open fuer den
--   Notfall-Pfad) — nur die 3 geteilten Gates der Advisor-Naht (WS-1).
-- ============================================================
CREATE TABLE IF NOT EXISTS estate.onboarding_state (
    section_key text PRIMARY KEY,
    ord         int  NOT NULL,
    label       text NOT NULL,
    status      text NOT NULL DEFAULT 'unknown' CHECK (status IN ('unknown', 'completed', 'skipped')),
    skipped_at  timestamptz,
    updated_at  timestamptz NOT NULL DEFAULT now()
);
-- Roter Faden (Nachfassen): Zeitpunkt der letzten STATUS-Aenderung, gesetzt nur von core.fn_set_onboarding_section
-- (Konvention jedes <pkg>.onboarding_state, s. agent.guide_init.sql).
ALTER TABLE estate.onboarding_state ADD COLUMN IF NOT EXISTS status_changed_at timestamptz NOT NULL DEFAULT now();

DROP TRIGGER IF EXISTS trg_onboarding_state_touch ON estate.onboarding_state;
CREATE TRIGGER trg_onboarding_state_touch BEFORE UPDATE ON estate.onboarding_state
    FOR EACH ROW EXECUTE FUNCTION estate.touch_updated_at();

-- ============================================================
-- =============  EREIGNISFALL (WS-3, Plan groovy-watching-wave)  ==============
--   Der Ereignisfall-Modus: stirbt ein Mitglied (death) oder wird es handlungsunfaehig
--   (incapacity/Vorsorgefall), instanziiert der Agent aus dem Template-Katalog eine
--   Fristen-Checkliste. Die FRISTEN RECHNET DIE DB (estate.fn_compute_due_date +
--   fn_add_business_days + fn_public_holidays), NIE das LLM (Daten-Integritaet:
--   das Modell rechnet nicht). Register-Tabellen oben = Vorsorge; die drei hier = Ereignisfall.
-- ============================================================

-- ============================================================
-- TASK_TEMPLATES (Seed-Katalog, dev-besessen) — der Fristen-/Aufgaben-Katalog des Ereignisfalls.
--   Muster directive_types: dev-besessener Seed (ON CONFLICT DO UPDATE, kein Write-Tool), stabile
--   Schluessel. Ein Fall instanziiert daraus seine case_tasks (Snapshot). Recherche-Synthese des
--   Plans (§§ PStG/BGB/ErbStG/SGB/VVG/WaffG, Quellen im Plan-Header). Werte:
--     * phase: grobe Dringlichkeits-Stufe (immediate/first_week/first_month/later); ord = Feinordnung.
--     * deadline_anchor: 'event' (ab Ereignis-/Todestag) vs. 'knowledge' (ab KENNTNIS — § 1944 BGB
--       Ausschlagung 6 Wo., § 30 ErbStG 3 Mon. laufen ab Kenntnis, nicht ab Tod).
--     * offset_count/offset_unit: die Frist relativ zum Anker; NULL/NULL = 'unverzueglich' (sofort
--       faellig). unit business_day = § 28 PStG (Sa/So/Feiertage zaehlen nicht); day/week/month
--       kalendarisch (§§ 187/188 BGB). Paarungs-CHECK: beide gesetzt oder beide NULL.
--     * condition_key: NULL = gilt IMMER; sonst ein Praedikat, das fn_case_template_rows auswertet
--       (derived: adult_subject/finance_absent/minor_children; sonst ein case.flags-Schluessel, den
--       der Agent im Intake erfragt: tenant/employed/pension_relevant/has_will/no_poa/abroad_or_work_accident).
--       Condition FALSE -> die Task wird als 'not_applicable' SICHTBAR instanziiert (nicht still
--       weggelassen — Transparenz: der Nutzer sieht, dass sie geprueft wurde).
--     * fan_out: NULL = eine Task; sonst ein special_assets.asset_type — je passendem Sonderfall-Stub
--       (Fahrzeug/Waffe/Firma/Haustier des Subjekts oder Haushalts) EINE eigene Task (subject_ref='asset:<id>').
--     * hardness: critical (zeitkritisch/rechtlich hart) / recommended / optional — Sortier-/Render-Prio.
--     * retired: Soft-Delete (Muster active_*) — ein ueberholtes Template wird nie geloescht (bestehende
--       case_tasks referenzieren es per FK), nur retired=true -> es instanziiert nicht mehr.
--   SEED per ON CONFLICT DO UPDATE (dev-besessen wie directive_types): Titel-/Fristen-Korrekturen
--   erreichen Bestands-Substrate per Re-Apply.
-- ============================================================
CREATE TABLE IF NOT EXISTS estate.task_templates (
    template_key    text NOT NULL PRIMARY KEY CHECK (template_key ~ '^[a-z0-9_]+$'),
    case_type       text NOT NULL CHECK (case_type IN ('death', 'incapacity')),
    phase           text NOT NULL CHECK (phase IN ('immediate', 'first_week', 'first_month', 'later')),
    ord             int  NOT NULL,
    title           text NOT NULL,                              -- deutscher Aufgaben-Titel (Schicht 5, dem Nutzer gezeigt)
    detail          text,                                       -- optionaler Erklaer-/Warn-Text (deutsch)
    deadline_anchor text NOT NULL DEFAULT 'event' CHECK (deadline_anchor IN ('event', 'knowledge')),
    offset_count    int CHECK (offset_count IS NULL OR offset_count >= 0),   -- NULL = unverzueglich
    offset_unit     text CHECK (offset_unit IN ('business_day', 'day', 'week', 'month')),
    condition_key   text,                                       -- NULL = immer; sonst Praedikat (s. Kopf)
    fan_out         text CHECK (fan_out IN ('vehicle', 'business_interest', 'firearm', 'pet')),  -- NULL = 1 Task
    legal_source    text,                                       -- Rechtsgrundlage (Beleg im Report)
    hardness        text NOT NULL DEFAULT 'recommended' CHECK (hardness IN ('critical', 'recommended', 'optional')),
    retired         boolean NOT NULL DEFAULT FALSE,
    -- offset_count und offset_unit sind gemeinsam gesetzt oder gemeinsam NULL (NULL/NULL = unverzueglich).
    CONSTRAINT task_templates_offset_pairing CHECK ((offset_count IS NULL) = (offset_unit IS NULL))
);

INSERT INTO estate.task_templates
    (template_key, case_type, phase, ord, title, detail, deadline_anchor, offset_count, offset_unit, condition_key, fan_out, legal_source, hardness) VALUES
    -- ---------- DEATH ----------
    ('death_certificate',        'death', 'immediate',   10, 'Ärztliche Todesbescheinigung (Totenschein) ausstellen lassen', 'Ein Arzt stellt den Totenschein aus — Voraussetzung für alles Weitere.', 'event', NULL, NULL, NULL, NULL, '§ 28 PStG (Vorstufe)', 'critical'),
    ('secure_key_email',         'death', 'immediate',   20, 'Schlüsselkonto (E-Mail) und SIM/2FA-Gerät des Verstorbenen sichern', 'Das E-Mail-Konto und das 2FA-Gerät gaten die Zurücksetzung aller anderen Konten — zuerst sichern, nichts vorschnell löschen.', 'event', NULL, NULL, NULL, NULL, NULL, 'critical'),
    ('claim_life_accident',      'death', 'immediate',   30, 'Lebens-/Unfallversicherung: Meldefrist prüfen und Anspruch anmelden', 'Unfalltod muss oft binnen 48 Stunden gemeldet werden (GDV-AUB), Lebensversicherungen 24–72 Stunden je Vertrag. Bezugsrecht prüfen.', 'event', 2, 'day', NULL, NULL, 'GDV-AUB / AVB', 'critical'),
    ('engage_undertaker',        'death', 'immediate',   40, 'Bestatter beauftragen (Bestattungsart/Wünsche, ggf. Vorsorgevertrag)', 'Der Bestatter übernimmt meist auch die Sterbefallanzeige beim Standesamt.', 'event', 2, 'day', NULL, NULL, NULL, 'critical'),
    ('sterbefallanzeige',        'death', 'immediate',   50, 'Sterbefallanzeige beim Standesamt', 'Spätestens am dritten auf den Tod folgenden Werktag — der Bestatter erledigt das üblicherweise.', 'event', 3, 'business_day', NULL, NULL, '§ 28 PStG', 'critical'),
    ('finance_absent_death',     'death', 'immediate',   60, 'Versicherungen und Bank-Ansprüche MANUELL prüfen (Meldefristen 24–48 h!)', 'Es sind keine Finanzdaten im System erfasst (finance-Paket nicht installiert) — prüfe Policen und Konten des Verstorbenen selbst, viele Ansprüche haben sehr kurze Fristen.', 'event', NULL, NULL, 'finance_absent', NULL, NULL, 'critical'),
    ('order_death_certs',        'death', 'first_week',  110, 'Ca. 5–10 Sterbeurkunden beim Standesamt bestellen', 'Viele Stellen (Banken, Versicherer, Grundbuch) verlangen Originale.', 'event', 1, 'week', NULL, NULL, NULL, 'recommended'),
    ('do_not_dissolve_account',  'death', 'first_week',  120, 'Konto des Verstorbenen NICHT auflösen', 'Renten-Rückbuchungen brauchen das Konto; ein Oder-Konto oder eine transmortale Vollmacht hält den Partner liquide.', 'event', NULL, NULL, NULL, NULL, NULL, 'critical'),
    ('notify_employer',          'death', 'first_week',  130, 'Arbeitgeber informieren (Lohn, betriebliche Vorsorge)', 'Bei einem Arbeitsunfall zusätzlich die Berufsgenossenschaft.', 'event', 3, 'day', 'employed', NULL, NULL, 'recommended'),
    ('notify_health_insurer',    'death', 'first_week',  140, 'Krankenkasse informieren', 'Die gesetzliche Krankenversicherung endet am Todestag.', 'event', 1, 'week', NULL, NULL, '§ 190 SGB V', 'recommended'),
    ('pension_survivor',         'death', 'first_week',  150, 'Renten Service / DRV informieren; Sterbevierteljahr beantragen', 'Der Witwen-/Witwerrenten-Vorschuss (Sterbevierteljahr) läuft über den Renten Service, Antrag binnen ~30 Tagen.', 'event', 30, 'day', 'pension_relevant', NULL, '§ 99 SGB VI', 'recommended'),
    ('secure_firearms',          'death', 'first_week',  160, 'Waffe der zuständigen Behörde melden und sichern', 'Erben müssen den Besitz binnen eines Monats anzeigen und die Waffe sichern lassen.', 'event', 1, 'month', NULL, 'firearm', '§ 20 WaffG', 'critical'),
    ('care_pet',                 'death', 'first_week',  170, 'Versorgung des Haustiers sicherstellen', NULL, 'event', NULL, NULL, NULL, 'pet', NULL, 'recommended'),
    ('minor_children_custody',   'death', 'first_week',  180, 'Sorgerecht für minderjährige Kinder klären', 'Prüfe eine Sorgerechtsverfügung; sonst entscheidet das Familiengericht.', 'event', 1, 'week', 'minor_children', NULL, NULL, 'critical'),
    ('death_abroad_accident',    'death', 'first_week',  190, 'Todesfall im Ausland / Arbeitsunfall: Konsulat bzw. Berufsgenossenschaft einschalten', NULL, 'event', 3, 'day', 'abroad_or_work_accident', NULL, NULL, 'recommended'),
    ('deliver_will',             'death', 'first_month', 210, 'Testament beim Nachlassgericht abliefern', 'Wer ein Testament besitzt, muss es unverzüglich beim Nachlassgericht abliefern.', 'event', 2, 'week', 'has_will', NULL, '§ 2259 BGB', 'recommended'),
    ('check_beneficiaries',      'death', 'first_month', 220, 'Bezugsberechtigungen (Lebensversicherung) prüfen', 'Ein Bezugsrecht wird außerhalb des Testaments ausgezahlt — auf überholte Begünstigte (Ex-Partner-Falle) achten.', 'event', 2, 'week', NULL, NULL, NULL, 'recommended'),
    ('manage_contracts',         'death', 'first_month', 230, 'Laufende Verträge (Strom/Telefon/Abos) prüfen, kündigen oder umschreiben', 'Sonderkündigungsrechte nutzen; Kundennummern stehen im Register.', 'event', 2, 'week', NULL, NULL, NULL, 'recommended'),
    ('tenancy',                  'death', 'first_month', 240, 'Vermieter informieren; Mietverhältnis regeln', 'Eintritt/Fortsetzung oder Sonderkündigung des Mietverhältnisses.', 'event', 1, 'month', 'tenant', NULL, '§§ 563/564 BGB', 'recommended'),
    ('inheritance_refusal',      'death', 'first_month', 250, 'Erbe prüfen: Ausschlagung nur binnen 6 Wochen ab Kenntnis', 'Wer sich wie ein Erbe verhält, kann das Recht zur Ausschlagung verwirken — bei Schuldenverdacht schnell Notar/Anwalt.', 'knowledge', 6, 'week', NULL, NULL, '§ 1944 BGB', 'critical'),
    ('estate_tax_notice',        'death', 'first_month', 260, 'Erbschaft dem Finanzamt anzeigen', 'Anzeigepflicht binnen drei Monaten ab Kenntnis des Erwerbs.', 'knowledge', 3, 'month', NULL, NULL, '§ 30 ErbStG', 'recommended'),
    ('business_interest_death',  'death', 'first_month', 270, 'Unternehmensbeteiligung: Gesellschaftsvertrag prüfen', 'Der Gesellschaftsvertrag geht dem Erbrecht vor — Notar/Anwalt einschalten.', 'event', 2, 'week', NULL, 'business_interest', 'Gesellschaftsvertrag', 'critical'),
    ('digital_estate',           'death', 'first_month', 280, 'Digitalen Nachlass regeln (Konten memorialisieren/löschen)', 'Facebook-Gedenkzustand ist irreversibel; Inaktivitätslöschung läuft (Google ~2 J., GMX ~6 Mon.).', 'event', 1, 'month', NULL, NULL, NULL, 'recommended'),
    ('vehicle_death',            'death', 'first_month', 290, 'Fahrzeug ummelden, versichern oder verkaufen', NULL, 'event', 1, 'month', NULL, 'vehicle', NULL, 'recommended'),
    ('probate_certificate',      'death', 'later',       310, 'Erbschein/Nachlassabwicklung klären', 'Ein notarielles Testament macht den Erbschein oft überflüssig; eine transmortale Vollmacht beschleunigt.', 'event', 1, 'month', NULL, NULL, NULL, 'recommended'),
    ('final_tax_return',         'death', 'later',       320, 'Letzte Einkommensteuererklärung des Verstorbenen (Steuerberater)', NULL, 'event', 3, 'month', 'adult_subject', NULL, NULL, 'optional'),
    -- ---------- INCAPACITY (Vorsorgefall) ----------
    ('check_poa',                'incapacity', 'immediate',   10, 'Vorsorgevollmacht/Betreuungsverfügung im Register prüfen', 'Ohne Vorsorgevollmacht bestellt das Gericht einen Betreuer; § 1358 BGB deckt nur enge Gesundheitsfragen zwischen Ehegatten.', 'event', NULL, NULL, NULL, NULL, '§ 1358 BGB', 'critical'),
    ('secure_ongoing_payments',  'incapacity', 'immediate',   20, 'Zugriff auf laufende Zahlungen sichern (Bankvollmacht prüfen)', 'Daueraufträge, Miete und Versicherungen laufen weiter — die Handlungsfähigkeit muss gesichert sein.', 'event', NULL, NULL, NULL, NULL, NULL, 'critical'),
    ('present_patient_directive','incapacity', 'immediate',   30, 'Patientenverfügung den behandelnden Ärzten vorlegen', NULL, 'event', NULL, NULL, NULL, NULL, NULL, 'recommended'),
    ('finance_absent_incap',     'incapacity', 'immediate',   40, 'Bankvollmachten und laufende Verpflichtungen MANUELL prüfen', 'Es sind keine Finanzdaten im System erfasst (finance-Paket nicht installiert) — prüfe Vollmachten und Verträge selbst.', 'event', NULL, NULL, 'finance_absent', NULL, NULL, 'critical'),
    ('apply_betreuung',          'incapacity', 'first_week',  110, 'Ohne Vorsorgevollmacht: Betreuung beim Betreuungsgericht anregen', NULL, 'event', 1, 'week', 'no_poa', NULL, NULL, 'critical'),
    ('notify_employer_incap',    'incapacity', 'first_week',  120, 'Arbeitgeber und Krankenkasse informieren (Entgeltfortzahlung/Krankengeld)', NULL, 'event', 3, 'day', 'employed', NULL, NULL, 'recommended'),
    ('minor_children_incap',     'incapacity', 'first_week',  130, 'Betreuung/Sorge für minderjährige Kinder organisieren', NULL, 'event', 1, 'week', 'minor_children', NULL, NULL, 'critical'),
    ('care_application',         'incapacity', 'first_month', 210, 'Pflegegrad bei der Pflegekasse beantragen', 'Leistungen gibt es frühestens ab dem Antragsmonat — früh beantragen.', 'event', 2, 'week', NULL, NULL, NULL, 'recommended'),
    ('manage_contracts_incap',   'incapacity', 'first_month', 220, 'Laufende Verträge und Abos sichten (weiterführen/kündigen)', 'Erfordert eine gültige Vollmacht.', 'event', 1, 'month', NULL, NULL, NULL, 'recommended'),
    ('business_interest_incap',  'incapacity', 'first_month', 230, 'Unternehmensbeteiligung: Handlungsfähigkeit sichern (Prokura/Vollmacht)', NULL, 'event', 2, 'week', NULL, 'business_interest', NULL, 'recommended')
ON CONFLICT (template_key) DO UPDATE SET
    case_type = excluded.case_type, phase = excluded.phase, ord = excluded.ord, title = excluded.title,
    detail = excluded.detail, deadline_anchor = excluded.deadline_anchor, offset_count = excluded.offset_count,
    offset_unit = excluded.offset_unit, condition_key = excluded.condition_key, fan_out = excluded.fan_out,
    legal_source = excluded.legal_source, hardness = excluded.hardness, retired = excluded.retired;

-- ============================================================
-- CASES — ein Ereignisfall (Tod/Vorsorgefall) je Zeile.
--   * subject_person_id FK RESTRICT auf agent.persons (das BETROFFENE Mitglied). NOT NULL: ein Fall
--     hat immer ein Subjekt (anders als die Register-owner_person_id = NULL fuer Haushalt).
--   * event_date = Ereignis-/Todestag; knowledge_date = ab wann der Haushalt Kenntnis hatte (Default =
--     event_date; CHECK >= event_date). Anker fuer die Fristen (§ 1944/§ 30 laufen ab Kenntnis).
--   * bundesland = 16-Laender-Slug (Feiertage der Werktags-Berechnung). fail-closed erzwingt die fn
--     (weder Config estate.bundesland noch Parameter -> {ok:false}); die geschlossene Liste ist der
--     DB-Backstop (unbekannter Slug -> CHECK-RAISE; die fn faengt ihn vorher freundlich ab).
--   * flags jsonb = Intake-Antworten des Agenten (tenant/employed/pension_relevant/has_will/no_poa/
--     abroad_or_work_accident ...), die condition_key-Praedikate auswerten. {} = keine gesetzt.
--   * status open|completed|cancelled|superseded, closed_at MATERIALISIERT (Auto-Complete-Trigger auf
--     case_tasks kippt open->completed, wenn die letzte Task done/n.a. ist; cancel/supersede setzen es
--     ebenfalls). CHECK: open <=> closed_at IS NULL.
--   * partial UNIQUE(subject_person_id) WHERE status='open' = hoechstens EIN offener Fall je Person
--     (Multi-Row-Invariante strukturell, kein Gate-Trigger). fn_create_case(death) supersedet einen
--     offenen incapacity-Fall derselben Person in EINER Tx, bevor es einfuegt (sonst blockte der Index).
-- ============================================================
CREATE TABLE IF NOT EXISTS estate.cases (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_type         text NOT NULL CHECK (case_type IN ('death', 'incapacity')),
    subject_person_id text NOT NULL REFERENCES agent.persons(person_id) ON DELETE RESTRICT,
    event_date        date NOT NULL,
    knowledge_date    date NOT NULL,
    bundesland        text NOT NULL CHECK (bundesland IN
                          ('baden_wuerttemberg', 'bayern', 'berlin', 'brandenburg', 'bremen', 'hamburg',
                           'hessen', 'mecklenburg_vorpommern', 'niedersachsen', 'nordrhein_westfalen',
                           'rheinland_pfalz', 'saarland', 'sachsen', 'sachsen_anhalt', 'schleswig_holstein', 'thueringen')),
    flags             jsonb NOT NULL DEFAULT '{}'::jsonb,
    status            text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'completed', 'cancelled', 'superseded')),
    closed_at         timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT cases_knowledge_ge_event   CHECK (knowledge_date >= event_date),
    CONSTRAINT cases_closed_at_consistency CHECK ((status = 'open') = (closed_at IS NULL))
);

-- Hoechstens EIN offener Fall je Person (Multi-Row-Invariante = partial UNIQUE, nicht Gate-Trigger).
CREATE UNIQUE INDEX IF NOT EXISTS cases_one_open_per_subject
    ON estate.cases (subject_person_id) WHERE status = 'open';

DROP TRIGGER IF EXISTS trg_cases_touch ON estate.cases;
CREATE TRIGGER trg_cases_touch BEFORE UPDATE ON estate.cases
    FOR EACH ROW EXECUTE FUNCTION estate.touch_updated_at();

-- ============================================================
-- CASE_TASKS — die instanziierte Checkliste eines Falls (template-Snapshot + manuelle Tasks).
--   * template_key FK RESTRICT auf task_templates (Snapshot-Herkunft; NULL = manuelle Task via
--     create_case_task). Templates werden nie geloescht (retired=Soft-Delete) -> FK bleibt intakt.
--   * subject_ref text NOT NULL DEFAULT '' = fan-out-Diskriminator ('' = 1 Task; 'asset:<id>' je
--     Sonderfall-Stub). NOT NULL DEFAULT '' loest die NULL-UNIQUE-Falle (Lektion advisor_plans P0c):
--     UNIQUE(case_id, template_key, subject_ref) macht die Instanziierung idempotent (ON CONFLICT) —
--     mit NULL waeren zwei gleiche Template-Tasks beide einfuegbar.
--   * title/detail/phase/due_date/hardness/legal_source = SNAPSHOT beim Instanziieren (der Katalog
--     kann sich spaeter aendern, die laufende Checkliste bleibt stabil). due_date DB-berechnet
--     (fn_compute_due_date), NULL = unverzueglich/kein Datum.
--   * status open|done|not_applicable. not_applicable = Condition beim Instanziieren FALSE (sichtbar
--     n.a., nicht still weg) ODER manuell abgehakt als "trifft nicht zu". done_at materialisiert.
-- ============================================================
CREATE TABLE IF NOT EXISTS estate.case_tasks (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id       bigint NOT NULL REFERENCES estate.cases(id) ON DELETE CASCADE,
    template_key  text REFERENCES estate.task_templates(template_key) ON DELETE RESTRICT,   -- NULL = manuelle Task
    subject_ref   text NOT NULL DEFAULT '',
    phase         text NOT NULL CHECK (phase IN ('immediate', 'first_week', 'first_month', 'later')),
    title         text NOT NULL,
    detail        text,
    due_date      date,
    hardness      text NOT NULL DEFAULT 'recommended' CHECK (hardness IN ('critical', 'recommended', 'optional')),
    legal_source  text,
    status        text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done', 'not_applicable')),
    done_at       timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (case_id, template_key, subject_ref)
);

DROP TRIGGER IF EXISTS trg_case_tasks_touch ON estate.case_tasks;
CREATE TRIGGER trg_case_tasks_touch BEFORE UPDATE ON estate.case_tasks
    FOR EACH ROW EXECUTE FUNCTION estate.touch_updated_at();

-- ============================================================
-- AUTO-COMPLETE-STATUS-MASCHINE (DB-Gesetz, Trigger — kein Tool pflegt cases.status selbst).
--   Sobald die LETZTE offene Task eines Falls done/not_applicable wird, kippt der Fall auf
--   'completed' (closed_at=now()). Umgekehrt: wird eine Task eines faelschlich completed Falls wieder
--   'open', kippt der Fall zurueck auf 'open' (defensiv — der Tool-Pfad editiert nur Tasks OFFENER
--   Faelle, aber der Trigger bleibt konsistent). cancelled/superseded sind TERMINAL (kein Auto-Flip).
--   Inline-Baseline-fn (Trigger-gekoppelt, wie estate.touch_updated_at) — kein R__.
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_case_tasks_autocomplete()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_status TEXT;
    v_open   INT;
BEGIN
    SELECT status INTO v_status FROM estate.cases WHERE id = NEW.case_id;
    IF v_status NOT IN ('open', 'completed') THEN
        RETURN NEW;   -- cancelled/superseded = terminal, nie auto-flippen
    END IF;
    SELECT count(*) INTO v_open FROM estate.case_tasks WHERE case_id = NEW.case_id AND status = 'open';
    IF v_open = 0 AND v_status = 'open' THEN
        UPDATE estate.cases SET status = 'completed', closed_at = now() WHERE id = NEW.case_id;
    ELSIF v_open > 0 AND v_status = 'completed' THEN
        UPDATE estate.cases SET status = 'open', closed_at = NULL WHERE id = NEW.case_id;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_case_tasks_autocomplete ON estate.case_tasks;
CREATE TRIGGER trg_case_tasks_autocomplete AFTER UPDATE OF status ON estate.case_tasks
    FOR EACH ROW WHEN (old.status IS DISTINCT FROM new.status)
    EXECUTE FUNCTION estate.fn_case_tasks_autocomplete();

-- ============================================================
-- =============  SYSTEM-STECKBRIEF (WS-5, Plan groovy-watching-wave)  ==============
-- SYSTEM_PROFILE — genau EINE Haushalts-Zeile (Singleton): der System-Steckbrief + der FUNDORT der
--   Offline-Kopie des core.backup_key (Owner-Entscheid 9; docs/package-contract.md §3.6 nennt die
--   Offline-Kopie explizit als DR-Pflicht). GEHEIMNISSE NIE — ausschliesslich Fundort-VERWEISE
--   (Grenzregel wie digital_accounts.seed_backup_location; die WS-5-Tool-Description + Instructions
--   tragen "nur Verweis, nie das Geheimnis"). Deckt den DR-Fall "beide Partner betroffen / System aus":
--   der Hinterbliebene findet damit Backup-Schluessel-Fundort + Admin/Restore-Weg, selbst wenn das
--   System nicht laeuft.
--   SINGLETON-ERZWINGUNG (arch-challenge P-B ADOPT, Option b): scope text PK DEFAULT 'household'
--   CHECK(scope='household') = strukturell genau 0/1 Zeile (PK-Unique auf einem CHECK-fixierten Wert).
--   Naming-Paritaet zu core.context_scopes.scope (selbst-dokumentierend: sagt WAS die Zeile ist, nicht
--   nur "Singleton"). Der CHECK ist PFLICHT-Backstop, weil ein AGENT-Tool schreibt (hoeheres Drift-Risiko
--   als core.backup_key, das nur der Installer per ON CONFLICT DO NOTHING schreibt — kein Praezedenz).
--   Init-only, KEIN V (additiv idempotent, WS-3-Praezedenz cases/case_tasks).
-- ============================================================
CREATE TABLE IF NOT EXISTS estate.system_profile (
    scope               text PRIMARY KEY DEFAULT 'household' CHECK (scope = 'household'),
    backup_key_location text,   -- Fundort der OFFLINE-Kopie des core.backup_key (NIE der Schluessel)
    system_location     text,   -- wo laeuft das System (Host/Provider/Standort)
    admin_access        text,   -- wie erreicht man Admin/Restore-Hilfe (Person/Kontakt, kein Passwort)
    restore_hint        text,   -- Verweis auf die Restore-Prozedur/Doku (z. B. lifeagents backup restore, Ordner ...)
    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_system_profile_touch ON estate.system_profile;
CREATE TRIGGER trg_system_profile_touch BEFORE UPDATE ON estate.system_profile
    FOR EACH ROW EXECUTE FUNCTION estate.touch_updated_at();

-- ============================================================
-- Reset-Lebenszyklus-Marker (Phase B, docs/package-contract.md §6 *Werkszustand-Reset*): core.fn_reset_user_data
--   leert jede Basistabelle dieses Schemas ausser den hier als 'lifecycle:reference' markierten (deny-by-default;
--   system_profile ist Nutzerdaten -> wird geleert).
-- ============================================================
COMMENT ON TABLE estate.directive_types IS 'lifecycle:reference - Seed-Katalog der Vorsorge-Dokumenttypen (diese Init)';
COMMENT ON TABLE estate.task_templates  IS 'lifecycle:reference - Seed-Katalog der Fristen-/Aufgaben-Vorlagen (diese Init)';
