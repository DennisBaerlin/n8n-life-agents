-- ============================================================
-- core.fn_semver_cmp(a, b) (read-only, IMMUTABLE — Update-Hinweis 2026-10-24)
--   Die EINE SemVer-Vergleichs-Logik des Systems (Release-Karte, Callback-Handler, root-Runner per psql — nie in
--   bash nachgebaut). Vergleicht stabile Release-Tags 'vMAJOR.MINOR.PATCH' numerisch (v0.10.0 > v0.9.2).
--   RUECKGABE: 1 (a > b) | 0 (gleich) | -1 (a < b) | NULL, wenn eine Seite kein stabiles Tag ist ('dev',
--   Prerelease 'v1.0.0-rc1', NULL) — Aufrufer behandeln NULL als "nicht vergleichbar" (nie als gleich).
--   Tests: tests/db/core/test_fn_release_card.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_semver_cmp(a text, b text)
RETURNS integer
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH x AS (
        SELECT (regexp_match(a, '^v([0-9]{1,6})\.([0-9]{1,6})\.([0-9]{1,6})$'))::int[] AS va,
               (regexp_match(b, '^v([0-9]{1,6})\.([0-9]{1,6})\.([0-9]{1,6})$'))::int[] AS vb
    )
    SELECT CASE
             WHEN va IS NULL OR vb IS NULL THEN NULL
             WHEN va > vb THEN 1
             WHEN va < vb THEN -1
             ELSE 0
           END
      FROM x;
$$;
