-- ============================================================
-- core.update_requests — Update-Auftraege aus dem Chat (Update-Hinweis, 2026-10-24)
--   Anwenden via: db_apply.ps1 -File packages\core\db\core.update_requests_init.sql
--
-- Zweck: die Bruecke zwischen dem unprivilegierten n8n (Owner tippt [Jetzt aktualisieren] auf der Release-Karte)
--   und dem root-Runner (systemd-Timer lifeagents-update-run, `lifeagents update --run-requested`). Der Tap endet
--   ueber die Callback-Registry in core.fn_handle_update_cb -> eine Zeile hier; der Runner uebernimmt sie atomar
--   (core.fn_update_request_claim), fuehrt das Update aus und schliesst sie (core.fn_update_request_finish).
--   Muster "Trigger = Daten-Zeile" (Monitor): keine Spool-Datei, kein Datei-Node in n8n (provisioning/CLAUDE.md).
--
-- INVARIANTEN (DB-Gesetz):
--   * hoechstens EIN offener Auftrag (partieller Unique-Index) -> Doppel-Tap/zweiter Weg legt nie einen zweiten an;
--   * finished_at und outcome nur gemeinsam; abgeschlossen nur, was uebernommen wurde;
--   * tag ist ein stabiles Release-Tag vX.Y.Z (der Runner prueft zusaetzlich in bash, bevor er ihn als Argument nutzt).
--   Der Runner traut der Zeile trotzdem nicht: er installiert nur, wenn tag = aktuelles releases/latest > VERSION.
--
-- Ephemer (Betriebs-Protokoll, keine Nutzerdaten) -> nicht im backup-Block des Manifests.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.update_requests (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind          text NOT NULL DEFAULT 'update'
                  CHECK (kind IN ('update', 'retry')),               -- retry = [Erneut versuchen] nach partial/failed/interrupted
    tag           text NOT NULL
                  CHECK (tag ~ '^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$'),   -- dieselbe Form wie core.fn_semver_cmp
    requested_by  text REFERENCES agent.persons (person_id) ON DELETE SET NULL,
    requested_at  timestamptz NOT NULL DEFAULT now(),
    claimed_at    timestamptz,                                       -- vom Runner uebernommen (unter der Update-Sperre)
    from_version  text CHECK (from_version IS NULL OR from_version ~ '^[A-Za-z0-9._-]{1,64}$'),  -- VERSION bei Uebernahme
    finished_at   timestamptz,
    outcome       text CHECK (outcome IN ('succeeded', 'partial', 'held', 'failed', 'interrupted',
                                          'already_current', 'superseded')),
    stage         text CHECK (stage IS NULL OR stage ~ '^[a-z_]{1,40}$'),        -- Schritt beim Abbruch (Ergebnis-Datei)
    reason_code   text CHECK (reason_code IS NULL OR reason_code ~ '^[a-z_]{1,40}$'),
    changed       boolean,                                           -- hat der Lauf schon etwas am System geaendert?
    detail        text CHECK (detail IS NULL OR length(detail) <= 500),  -- gekuerzte letzte die-Zeile (nur Anzeige, nie in Links)
    CONSTRAINT update_requests_finish_pair CHECK ((finished_at IS NULL) = (outcome IS NULL)),
    CONSTRAINT update_requests_finish_claimed CHECK (finished_at IS NULL OR claimed_at IS NOT NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS update_requests_one_open
    ON core.update_requests ((TRUE)) WHERE finished_at IS NULL;

CREATE INDEX IF NOT EXISTS update_requests_tag_idx
    ON core.update_requests (tag, requested_at DESC);
