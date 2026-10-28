-- ============================================================
-- finance.fn_xirr(p_dates date[], p_amounts numeric[], p_annualize boolean DEFAULT TRUE) — geldgewichtete Rendite (READ)
--   Interner Zinsfuss datierter Geldfluesse (XIRR / IZF): der Satz r mit Summe a_i / (1 + r)^((d_i - d_0) / 365) = 0.
--   Konvention Act/365 wie Excel XIRR und Portfolio Performance „IZF" (NPVFunction: Tage / 365.0). Vorzeichen aus Sicht
--   des Anlegers: Einzahlung (Kauf) negativ, Auszahlung (Verkauf, Dividende, Endwert) positiv.
--   p_annualize = true  -> Jahresrendite r (Excel-XIRR-kompatibel); NULL, wenn sie nicht darstellbar ist (Ueberlauf bei
--                          sehr kurzer Periode mit grossem Gewinn); -1 bei entsprechend grossem Verlust.
--                 false -> Rendite ueber die ganze Periode erster..letzter Fluss, nicht annualisiert
--                          ((1 + r)^(Tage/365) - 1); fuer Zeitraeume unter einem Jahr (GIPS: nie hochrechnen).
--   Verfahren: geloest wird nach dem Periodenfaktor y = (1 + r)^(T/365) (T = Tage erster..letzter Fluss), damit kurze
--   Zeitraeume nicht ueberlaufen. Erst Klammer-Suche auf einem festen Raster von y (1e-12..1e12, die Vorzeichenwechsel-
--   Klammer naechst y = 1, d. h. die Loesung naechst 0 %), dann Bisektion (geometrisch) bis die Klammer eng ist, dann
--   Newton mit Rueckfall auf Bisektion, wenn ein Schritt die Klammer verlaesst (wie PP IRR.java: Bisektions-Start +
--   Newton). Abbruch bei relativer Schrittweite < 1e-12 in y (Satz damit genauer als 1e-8) oder nach 200 Schritten.
--   Gleiche Tage werden summiert. NULL bei: ungleich langen/leeren Arrays, NULL-Element, Zeitspanne 0, nicht mindestens
--   einem positiven UND einem negativen (Tages-)Fluss, keinem Vorzeichenwechsel im Raster.
--   Quellen: Microsoft XIRR https://support.microsoft.com/en-us/office/xirr-function-de1242ec-6477-445b-b11b-a303ad9adc9d ·
--   Portfolio Performance NPVFunction/IRR https://github.com/portfolio-performance/portfolio/blob/master/name.abuchen.portfolio/src/name/abuchen/portfolio/math/NPVFunction.java
--   und https://github.com/portfolio-performance/portfolio/blob/master/name.abuchen.portfolio/src/name/abuchen/portfolio/math/IRR.java ·
--   Money-weighted (IZF) https://help.portfolio-performance.info/de/konzepte/performance/money-weighted/ ·
--   GIPS 2020 (Renditen unter einem Jahr nicht annualisieren) https://www.gipsstandards.org/standards/
--   Reine Rechen-fn (IMMUTABLE, liest keine Tabelle); Aufrufer: finance.fn_depot_performance.
--   Tests: tests/db/finance/test_fn_xirr.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_xirr(p_dates date[], p_amounts numeric[], p_annualize boolean DEFAULT TRUE)
RETURNS numeric
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    v_t     double precision[];   -- Zeitpunkt je Tagesfluss als Anteil der Periode (0..1)
    v_a     double precision[];   -- Tagesfluss
    v_days  int;
    v_grid  double precision[] := ARRAY[1e-12, 1e-9, 1e-6, 1e-4, 1e-3, 0.01, 0.1, 0.25, 0.5, 0.75, 0.9, 1,
                                        1.1, 1.25, 1.5, 2, 4, 10, 100, 1e3, 1e4, 1e6, 1e9, 1e12];
    v_lo    double precision;
    v_hi    double precision;
    v_flo   double precision;
    v_f     double precision;
    v_df    double precision;
    v_y     double precision;
    v_next  double precision;
    v_prev  double precision;
    v_fprev double precision;
    v_dist  double precision;
    v_best  double precision;
    v_ln    double precision;
    i       int;
    k       int;
BEGIN
    IF p_dates IS NULL OR p_amounts IS NULL OR cardinality(p_dates) < 2
       OR cardinality(p_dates) <> cardinality(p_amounts)
       OR array_position(p_dates, NULL) IS NOT NULL OR array_position(p_amounts, NULL) IS NOT NULL THEN
        RETURN NULL;
    END IF;

    SELECT max(u.d) - min(u.d) INTO v_days FROM unnest(p_dates) AS u(d);
    IF v_days = 0 THEN RETURN NULL; END IF;

    SELECT array_agg(((g.d - g.d0)::double precision / v_days) ORDER BY g.d), array_agg(g.a::double precision ORDER BY g.d)
      INTO v_t, v_a
      FROM (SELECT u.d, sum(u.a) AS a, min(u.d) OVER () AS d0
              FROM unnest(p_dates, p_amounts) AS u(d, a)
             GROUP BY u.d) g
     WHERE g.a <> 0;
    IF v_a IS NULL OR NOT (0 < ANY (v_a) AND 0 > ANY (v_a)) THEN RETURN NULL; END IF;

    -- Klammer: Vorzeichenwechsel zwischen zwei Rasterpunkten, naechst y = 1 (Loesung naechst 0 %)
    v_prev := NULL;
    FOREACH v_y IN ARRAY v_grid LOOP
        v_f := 0;
        FOR i IN 1 .. cardinality(v_a) LOOP
            v_f := v_f + v_a[i] * power(v_y, -v_t[i]);
        END LOOP;
        IF v_f = 0 THEN
            v_dist := abs(ln(v_y));
            IF v_best IS NULL OR v_dist < v_best THEN v_best := v_dist; v_lo := v_y; v_hi := v_y; v_flo := 0; END IF;
        ELSIF v_prev IS NOT NULL AND sign(v_f) <> sign(v_fprev) AND v_fprev <> 0 THEN
            v_dist := CASE WHEN v_prev <= 1 AND v_y >= 1 THEN 0 ELSE least(abs(ln(v_prev)), abs(ln(v_y))) END;
            IF v_best IS NULL OR v_dist < v_best THEN v_best := v_dist; v_lo := v_prev; v_hi := v_y; v_flo := v_fprev; END IF;
        END IF;
        v_prev := v_y;
        v_fprev := v_f;
    END LOOP;
    IF v_lo IS NULL THEN RETURN NULL; END IF;

    v_y := v_lo;
    IF v_lo <> v_hi THEN
        -- Bisektion (geometrische Mitte), bis die Klammer eng ist; danach Newton mit Rueckfall auf Bisektion
        v_y := sqrt(v_lo * v_hi);
        FOR k IN 1 .. 200 LOOP
            v_f := 0;
            v_df := 0;
            FOR i IN 1 .. cardinality(v_a) LOOP
                v_f := v_f + v_a[i] * power(v_y, -v_t[i]);
                v_df := v_df - v_t[i] * v_a[i] * power(v_y, -v_t[i] - 1);
            END LOOP;
            IF v_f = 0 THEN v_next := v_y; EXIT; END IF;
            IF sign(v_f) = sign(v_flo) THEN v_lo := v_y; v_flo := v_f; ELSE v_hi := v_y; END IF;
            IF v_hi / v_lo > 1.01 OR v_df = 0 THEN
                v_next := sqrt(v_lo * v_hi);
            ELSE
                v_next := v_y - v_f / v_df;
                IF v_next <= v_lo OR v_next >= v_hi THEN v_next := sqrt(v_lo * v_hi); END IF;
            END IF;
            EXIT WHEN abs(v_next - v_y) < 1e-12 * v_y;
            v_y := v_next;
        END LOOP;
        v_y := v_next;
    END IF;

    IF NOT p_annualize THEN
        RETURN round((v_y - 1)::numeric, 12);
    END IF;
    v_ln := ln(v_y) * 365.0 / v_days;
    IF v_ln > 700 THEN RETURN NULL; END IF;
    -- grosser Verlust in kurzer Zeit: (1 + r) unterhalb der float-Grenze -> praktisch -100 % (exp() wuerfe underflow)
    IF v_ln < -700 THEN RETURN -1; END IF;
    RETURN round((exp(v_ln) - 1)::numeric, 12);
END;
$$;
