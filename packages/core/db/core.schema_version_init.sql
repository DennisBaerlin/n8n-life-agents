-- ============================================================
-- core.schema_version — Migrations-Ledger (idempotent, Flyway-Single-Table-Modell)
--   Anwenden via: db_apply.ps1 -File packages\core\db\core.schema_version_init.sql
--   (laeuft als ERSTE Datei im Schema-Apply, vor allen Inits/Migrationen —
--    der Migrations-Treiber in apply_schema.sh / db_apply.ps1 braucht die
--    Funktionen bereits, bevor er die erste V-/R-Datei anlegt.)
--
-- Zweck: Aus EINER Quelle (packages/*/db/) zwei Artefakte konsistent halten — die
--   Windows/PowerShell-Dev-Werkzeugkette (db_apply.ps1) und der bash-
--   Auslieferungs-Kern (provisioning/lib/apply_schema.sh) fahren BEIDE
--   dasselbe Schema. Nach dem etablierten **Flyway-Standard** (meistgenutztes
--   DB-Migrations-Tool) gibt es ZWEI Migrationstypen — beide in DIESER EINEN
--   Tabelle getrackt (Flyways `flyway_schema_history`-Single-Table-Modell =
--   EIN Audit-Trail, sofort als Migrations-Ledger erkennbar):
--
--   1. **versioned** (`packages/<pkg>/db/migrations/V{NNN}__*.sql`): einmalige, nicht-
--      idempotente Struktur-Deltas (destruktiver ALTER/DROP, Spalten-RENAME,
--      Daten-Backfill, ENUM-Wert-Drop). Laeuft genau EINMAL; unveraenderlich.
--   2. **repeatable** (`packages/<pkg>/db/migrations/R__*.sql`): Views + Tool-Functions, die
--      bei JEDER Inhalts-Aenderung neu laufen sollen (Idempotenz via DROP+CREATE
--      / CREATE OR REPLACE). Per Checksum getrackt -> laeuft nur neu, wenn sich
--      der Inhalt aenderte (kein Apply-Bremsen durch wachsendes Schema; Audit,
--      welche View-/fn-Version live ist). `version` haelt hier den RELATIVEN
--      PFAD als Key (z. B. 'packages/finance/db/migrations/R__finance_views.sql').
--
-- Mechanik (Treiber-Vertrag, identisch in bash + PowerShell), je Datei in EINER
-- Transaktion mit ON_ERROR_STOP=1:
--   VERSIONED:  SELECT core.migration_should_apply('V001','V001__x.sql','<md5>')
--     -> TRUE  => der Treiber `\i`-t die Datei (Reservierung ist gesetzt;
--                 schlaegt die Datei fehl, rollt die Transaktion auch die
--                 Reservierung zurueck -> sie laeuft beim naechsten Mal erneut).
--     -> FALSE => bereits angewandt, der Treiber ueberspringt die Datei.
--     Geaenderte Checksumme einer angewandten Version => Drift-EXCEPTION
--     (unveraenderlich; korrigieren = neue V-Datei, nie editieren).
--   REPEATABLE: SELECT core.repeatable_should_apply('packages/<pkg>/db/migrations/R__x.sql','<md5>')
--     -> TRUE  => Inhalt neu (oder geaendert) -> anwenden (Eintrag/Update gesetzt).
--     -> FALSE => unveraendert -> ueberspringen. MUTABEL (keine Drift-Exception):
--                 Repeatables SIND zum Neu-Laufen gedacht — der Gegensatz zum
--                 unveraenderlichen versioned-Pfad.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.schema_version (
    version     text PRIMARY KEY,                       -- versioned: '<pkg>:V001' (paket-prefixter Key, s. migration_should_apply unten); repeatable: relativer Pfad 'packages/<pkg>/db/migrations/R__x.sql'
    filename    text        NOT NULL,                    -- 'V001__add_xyz.sql' / 'R__finance_views.sql' (Doku/Audit)
    checksum    text        NOT NULL DEFAULT '',         -- md5 des Datei-Inhalts (Drift-Guard versioned / Re-Run-Trigger repeatable; '' = ungeprueft)
    kind        text        NOT NULL DEFAULT 'versioned',-- 'versioned' | 'repeatable' (macht den Audit-Trail selbsterklaerend)
    package     text        NOT NULL DEFAULT 'core',     -- besitzendes Paket (Core-Paket-Framework): 'core' fuer Core-/Alt-Migrationen, '<paket>' fuer Paket-eigene
    applied_at  timestamptz NOT NULL DEFAULT now()
);

-- Bestehende DBs (Ledger evtl. schon angelegt): kind-Spalte nachziehen. Tabelle war bis hier
-- versioned-only -> Default 'versioned' ist fuer Altzeilen korrekt.
ALTER TABLE core.schema_version ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'versioned';

-- Core-Paket-Framework: paket-scoped Ledger (Plan §5/R5). Altzeilen = Core -> Default 'core' korrekt.
-- Paket-Zuordnung kommt aus der Session-GUC `lifeagents.package`, die der Apply-Treiber
-- (apply_schema.sh / db_apply.ps1) pro Quell-Verzeichnis-Batch setzt ('core' fuer packages/core/db/,
-- '<paket>' fuer den jeweiligen Paket-/Flach-Batch). Ungesetzt -> 'core' (Default, rueckwaerts-kompatibel).
-- GUC statt fn-Signatur-Param: Body-only-Change (CREATE OR REPLACE ohne DROP/Ueberladungs-Ambiguitaet),
-- und die bestehenden 3-/2-arg-Aufrufer im Treiber bleiben unveraendert.
ALTER TABLE core.schema_version ADD COLUMN IF NOT EXISTS package text NOT NULL DEFAULT 'core';

-- ------------------------------------------------------------
-- core.migration_should_apply(version, filename, checksum) -> boolean
--   Reserviert eine neue Migration (INSERT) und liefert TRUE = "jetzt anwenden".
--   Bereits angewandt -> FALSE (kein Doppellauf). Geaenderte Checksumme einer
--   angewandten Version -> EXCEPTION (Drift). Race-fest: die PK-Reservierung
--   passiert in derselben Transaktion wie das nachfolgende `\i` der Datei.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.migration_should_apply(
    p_version  text,
    p_filename text,
    p_checksum text DEFAULT ''
) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
    v_existing core.schema_version%ROWTYPE;
    v_pkg      text;
    v_key      text;
BEGIN
    IF p_version IS NULL OR p_version = '' THEN
        RAISE EXCEPTION 'core.migration_should_apply: leere version';
    END IF;

    -- Paket-Ledger-Scope (R5/arch-challenge C): der PK-Key der VERSIONED-Migrationen wird mit dem
    -- besitzenden Paket praefixt ('finance:V001'), damit core V001 und finance V001 NICHT kollidieren
    -- (das Schema-version-PK ist Single-Column). Das Paket kommt aus der Session-GUC, die der
    -- Apply-Treiber pro Batch setzt; ungesetzt -> 'core'. Repeatables bleiben unpraefixt (ihr
    -- relativer Pfad ist global eindeutig). Body-only: die Treiber-Aufrufe (bare 'V001') bleiben gleich.
    v_pkg := COALESCE(NULLIF(current_setting('lifeagents.package', true), ''), 'core');
    v_key := v_pkg || ':' || p_version;

    SELECT * INTO v_existing FROM core.schema_version WHERE version = v_key;
    IF FOUND THEN
        -- Drift-Guard: eine schon angewandte Migration wurde nachtraeglich editiert
        -- (anderer Inhalt) -> nie still ignorieren oder erneut fahren. Migrationen sind
        -- unveraenderlich; eine Korrektur ist eine NEUE V-Datei.
        IF p_checksum <> '' AND v_existing.checksum <> '' AND v_existing.checksum <> p_checksum THEN
            RAISE EXCEPTION
                'core.schema_version: Migration % (%) wurde bereits mit anderem Inhalt angewandt '
                '(gespeichert=%, jetzt=%). Migrationen sind unveraenderlich — neue V-Datei anlegen, nie editieren.',
                v_key, p_filename, v_existing.checksum, p_checksum;
        END IF;
        RETURN FALSE;   -- bereits angewandt -> NICHT erneut fahren
    END IF;

    -- Neue Migration: in DIESER Transaktion reservieren. Der Treiber wendet die
    -- Datei als Naechstes an; failt sie unter ON_ERROR_STOP, rollt die Transaktion
    -- diese Zeile mit zurueck -> die Migration gilt nicht als angewandt.
    INSERT INTO core.schema_version (version, filename, checksum, kind, package)
    VALUES (v_key, p_filename, p_checksum, 'versioned', v_pkg);
    RETURN TRUE;
END;
$$;

-- ------------------------------------------------------------
-- core.repeatable_should_apply(name, checksum) -> boolean
--   Gegenstueck zu migration_should_apply fuer REPEATABLES (Views/Functions,
--   packages/<pkg>/db/migrations/R__*.sql). `p_name` = relativer Pfad als Key (zugleich filename).
--     kein Eintrag        -> INSERT(kind='repeatable') + TRUE  (erstmals anwenden).
--     vorhanden, andere   -> UPDATE checksum/applied_at      + TRUE  (Inhalt geaendert -> neu fahren).
--     vorhanden, gleiche  ->                                   FALSE (unveraendert -> ueberspringen).
--   BEWUSST MUTABEL: keine Drift-Exception (anders als versioned). Race-fest wie das
--   versioned-Pendant — die Reservierung/Update passiert in derselben Transaktion wie
--   das nachfolgende `\i` der Datei (Fehler -> ON_ERROR_STOP rollt beides zurueck).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.repeatable_should_apply(
    p_name     text,
    p_checksum text DEFAULT ''
) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
    v_existing core.schema_version%ROWTYPE;
BEGIN
    IF p_name IS NULL OR p_name = '' THEN
        RAISE EXCEPTION 'core.repeatable_should_apply: leerer name';
    END IF;

    SELECT * INTO v_existing FROM core.schema_version WHERE version = p_name;
    IF FOUND THEN
        IF v_existing.checksum = p_checksum THEN
            RETURN FALSE;   -- unveraendert -> nicht neu fahren
        END IF;
        -- Inhalt geaendert -> neu fahren; Checksum/applied_at fortschreiben (mutabel).
        UPDATE core.schema_version
           SET checksum = p_checksum, applied_at = now(), kind = 'repeatable',
               package = COALESCE(NULLIF(current_setting('lifeagents.package', true), ''), 'core')
         WHERE version = p_name;
        RETURN TRUE;
    END IF;

    -- Erstmals gesehen: reservieren + anwenden.
    INSERT INTO core.schema_version (version, filename, checksum, kind, package)
    VALUES (p_name, p_name, p_checksum, 'repeatable',
            COALESCE(NULLIF(current_setting('lifeagents.package', true), ''), 'core'));
    RETURN TRUE;
END;
$$;

-- ------------------------------------------------------------
-- M2 — Bestands-Backfill der paket-prefixed VERSIONED-Keys (idempotent, Phase-0).
--   Auf einer ledger-ERHALTENDEN DB (lifeagents update / Prod) liegen Altzeilen mit UNPREFIXED
--   versioned-Key ('V001') neben kuenftig prefixed Schreibungen ('finance:V001') -> migration_should_apply
--   faende die Altzeile nicht mehr und wuerde V001 ERNEUT fahren (nicht-idempotente Migration!).
--   Darum hier einmalig + idempotent die versioned-Altzeilen auf '<package>:<version>' heben.
--   Laeuft als allererste Datei (vor allen V/R) -> die danach gefahrenen V-Migrationen sehen
--   bereits den prefixed Endzustand. Repeatables (kind='repeatable', Pfad-Key) bleiben unberuehrt.
--   Fresh-DB: Tabelle leer -> no-op. Re-Run: position(':')>0 schliesst bereits-prefixte aus -> no-op.
-- ------------------------------------------------------------
UPDATE core.schema_version
   SET version = package || ':' || version
 WHERE kind = 'versioned'
   AND position(':' IN version) = 0;
