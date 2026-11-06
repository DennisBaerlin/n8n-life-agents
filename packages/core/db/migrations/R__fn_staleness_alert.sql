-- ============================================================
-- core.fn_staleness_alert — geteilter Staleness-Alarm-Form-Helfer der Paket-Reviewer (fn_advisor_review)
--   Kapselt die 4x ueber finance/career/estate duplizierte Staleness-Logik: die Schwellen-Entscheidung
--   (`alter > schwelle`) + die {kind:'staleness'}-Alarm-jsonb-Form (metric_key/label/value/target/drift/msg).
--   `drift` (age-threshold, round 0) wird UNIFORM mit-emittiert (kein Konsument liest es, harmlos). Datum-Extraktion
--   + die Alarm-Struktur bleiben paket-lokal (Generik-Vertrag: der Core-Wrapper kennt keine Paket-Felder); das Paket
--   berechnet das Alter (das es fuer die Struktur ohnehin bildet) und uebergibt es hier.
--
--   EINGANG: p_metric_key (Latch-Anker, 1:1 vom Paket durchgereicht -> Stabilitaet von fn_should_notify/
--     fn_notify_reconcile), p_label (englisch-technisches Label, keine Anzeige), p_age_days (current_date - datumsfeld,
--     im Paket berechnet), p_threshold_days (Config-Schwelle, im Paket gelesen), p_msg (Struktur statt Text:
--     [{kind:'tpl', value:<text-key>, params:{…typisierte Rohwerte…}}], HITL-Form; der Workflow rendert daraus den
--     Text in der Sprache des Empfaengers per Get-UiRenderLibJs, Zahlen per Intl).
--   RUECKGABE: jsonb-ARRAY — '[]' (nicht stale / NULL age) | '[{metric_key,kind:'staleness',label,value,
--     target,drift,msg}]' (stale). Array (nicht jsonb|NULL), damit `v_alerts || core.fn_staleness_alert(...)`
--     BEDINGUNGSLOS sicher ist (array || array) — die `array || NULL`-Falle (stiller Verlust ALLER Alerts
--     der Domaene) ist strukturell ausgeschlossen.
--
--   TYP-VERTRAG: Parameter NUMERIC (nicht integer) — die Aufrufer-Variablen sind numeric (finance/career)
--     bzw. integer (estate r.age_days); `integer->numeric` ist ein impliziter Cast, `numeric->integer` NICHT
--     (Assignment-Cast) -> integer-Parameter wuerden die numeric-Aufrufe zur Laufzeit nicht aufloesen.
--   REIN: keine Tabellen-Reads, kein current_date -> IMMUTABLE, kein SECURITY DEFINER/Grant noetig (die
--     D10-Cross-Schema-Read-Regel greift mangels Read nicht; Default-PUBLIC-EXECUTE wie fn_monthly_equivalent).
--   Die fruehere Text-Ueberladung (p_text text) ist seit core:V030 gedroppt.
--   Anwenden via: db_apply.ps1 -File packages\core\db\migrations\R__fn_staleness_alert.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_staleness_alert(
    p_metric_key     text,
    p_label          text,
    p_age_days       numeric,
    p_threshold_days numeric,
    p_msg            jsonb
) RETURNS jsonb
LANGUAGE sql IMMUTABLE
AS $$
    SELECT CASE
        WHEN p_age_days IS NOT NULL AND p_age_days > p_threshold_days
        THEN jsonb_build_array(jsonb_build_object(
            'metric_key', p_metric_key,
            'kind',       'staleness',
            'label',      p_label,
            'value',      p_age_days,
            'target',     p_threshold_days,
            'drift',      round(p_age_days - p_threshold_days, 0),
            'msg',        p_msg))
        ELSE '[]'::jsonb
    END
$$;
