-- ============================================================
-- estate.fn_public_holidays (Fristen-Engine, WS-3 — IMMUTABLE, reine Arithmetik)
--   Liefert die gesetzlichen Feiertage EINES Jahres in EINEM Bundesland als date[] — die Basis der
--   Werktags-Berechnung (fn_add_business_days) fuer § 28 PStG (Sterbefallanzeige am 3. Werktag).
--   IMMUTABLE, weil KEINE Tabelle gelesen wird (Leitplanke Plan: sobald eine Fristen-fn eine Tabelle
--   liest -> STABLE): Gauss'sche Osterformel (Gregorianisch, mit den zwei Korrektur-Ausnahmen) +
--   geschlossene 16-Laender-CASE. Bundesweite Feiertage + landesspezifische (Heilige Drei Koenige,
--   Frauentag, Fronleichnam, Mariae Himmelfahrt, Weltkindertag, Reformationstag, Allerheiligen,
--   Buss- und Bettag). KONSERVATIV (Plan): nur LANDESWEITE Feiertage — kommunale (z. B. Mariae
--   Himmelfahrt in Teilen Bayerns) werden bewusst NICHT gezaehlt (weniger Feiertage -> Werktage
--   akkumulieren schneller -> fruehere Frist = konservativ, wie der bewusste Verzicht auf § 193 BGB).
--   Unbekannter/leerer Bundesland-Slug -> nur die bundesweiten Feiertage (kein Wurf).
--   EINGABE: p_year int, p_bundesland text (16-Laender-Slug). RUECKGABE: date[].
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_public_holidays.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_public_holidays(p_year int, p_bundesland text)
RETURNS date[] LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    a INT; b INT; c INT; k INT; p INT; q INT; m INT; n INT; d INT; e INT;
    v_easter     DATE;
    v_march_day  INT;
    v_bl         TEXT := lower(COALESCE(p_bundesland, ''));
    v_h          DATE[];
BEGIN
    -- Gauss'sche Osterformel (Gregorianischer Kalender).
    a := p_year % 19;  b := p_year % 4;  c := p_year % 7;
    k := p_year / 100; p := (13 + 8 * k) / 25; q := k / 4;
    m := (15 - p + k - q) % 30;  n := (4 + k - q) % 7;
    d := (19 * a + m) % 30;
    e := (2 * b + 4 * c + 6 * d + n) % 7;
    v_march_day := 22 + d + e;   -- Ostersonntag = 22. Maerz + (d+e) Tage (rollt in den April)
    v_easter := make_date(p_year, 3, 1) + (v_march_day - 1);
    -- Zwei Korrektur-Ausnahmen der Osterformel.
    IF d = 29 AND e = 6 THEN
        v_easter := make_date(p_year, 4, 19);
    ELSIF d = 28 AND e = 6 AND ((11 * m + 11) % 30) < 19 THEN
        v_easter := make_date(p_year, 4, 18);
    END IF;

    -- Bundesweite Feiertage (alle 16 Laender).
    v_h := ARRAY[
        make_date(p_year, 1, 1),       -- Neujahr
        v_easter - 2,                  -- Karfreitag
        v_easter + 1,                  -- Ostermontag
        make_date(p_year, 5, 1),       -- Tag der Arbeit
        v_easter + 39,                 -- Christi Himmelfahrt
        v_easter + 50,                 -- Pfingstmontag
        make_date(p_year, 10, 3),      -- Tag der Deutschen Einheit
        make_date(p_year, 12, 25),     -- 1. Weihnachtstag
        make_date(p_year, 12, 26)      -- 2. Weihnachtstag
    ];

    -- Landesspezifische (nur landesweite) Feiertage.
    IF v_bl IN ('baden_wuerttemberg', 'bayern', 'sachsen_anhalt') THEN
        v_h := v_h || make_date(p_year, 1, 6);                        -- Heilige Drei Koenige
    END IF;
    IF v_bl IN ('berlin', 'mecklenburg_vorpommern') THEN
        v_h := v_h || make_date(p_year, 3, 8);                        -- Internationaler Frauentag
    END IF;
    IF v_bl IN ('baden_wuerttemberg', 'bayern', 'hessen', 'nordrhein_westfalen', 'rheinland_pfalz', 'saarland') THEN
        v_h := v_h || (v_easter + 60);                               -- Fronleichnam
    END IF;
    IF v_bl = 'saarland' THEN
        v_h := v_h || make_date(p_year, 8, 15);                       -- Mariae Himmelfahrt (landesweit nur SL)
    END IF;
    IF v_bl = 'thueringen' THEN
        v_h := v_h || make_date(p_year, 9, 20);                       -- Weltkindertag
    END IF;
    IF v_bl IN ('brandenburg', 'mecklenburg_vorpommern', 'sachsen', 'sachsen_anhalt', 'thueringen',
                'bremen', 'hamburg', 'niedersachsen', 'schleswig_holstein') THEN
        v_h := v_h || make_date(p_year, 10, 31);                      -- Reformationstag (5 oestl. + 4 noerdl. seit 2018)
    END IF;
    IF v_bl IN ('baden_wuerttemberg', 'bayern', 'nordrhein_westfalen', 'rheinland_pfalz', 'saarland') THEN
        v_h := v_h || make_date(p_year, 11, 1);                       -- Allerheiligen
    END IF;
    IF v_bl = 'sachsen' THEN
        -- Buss- und Bettag = Mittwoch (isodow 3) vor dem 23.11. -> im Fenster [16.11., 22.11.].
        v_h := v_h || (make_date(p_year, 11, 22)
                       - ((EXTRACT(isodow FROM make_date(p_year, 11, 22))::int - 3 + 7) % 7));
    END IF;

    RETURN v_h;
END;
$$;
