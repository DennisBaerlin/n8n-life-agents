-- ============================================================
-- fn_recurring_suggestion_text (STABLE) -- Text einer Dauerauftrags-Vorschlags-Nachricht in einer Sprache
--   Die eine Adresse fuer Angebot (Versand, fn_get_recurring_suggestion_queue), Ergebnis nach dem Tipp und Owner-Hinweis
--   (fn_handle_recurring_suggestion_cb): reiner Text ohne Markdown, Feldreihenfolge wie die Karte der Einzelanlage
--   (Name, Betrag in Kontowaehrung, Rhythmus, erste Zahlung, Konto), Werte ueber core.fn_fmt_money/core.fn_fmt_date.
--   Namen kommen bereinigt aus dem Stapel (fn_recurring_clean_name).
--   p_mode: offer | accepted | declined | failed | owner_notice.
--   p_v: {name, entity_type, direction, amount, currency, unit, interval, dom, start (date), account, to_account,
--   recurring_kind, origin_kind (statement|export), confidence, rhythm_assumed, reason_key (failed), member (owner_notice)}.
--   RUECKGABE: text.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_suggestion_text(p_mode text, p_v jsonb, p_lang text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_name   TEXT := COALESCE(p_v->>'name', '');
    v_amount TEXT := core.fn_fmt_money((p_v->>'amount')::numeric, p_v->>'currency', p_lang);
    v_rhythm TEXT := finance.fn_recurring_rhythm_text(p_v->>'unit', NULLIF(p_v->>'interval', '')::int, NULLIF(p_v->>'dom', '')::int, p_lang);
    v_start  TEXT := core.fn_fmt_date(NULLIF(p_v->>'start', '')::date, p_lang);
    v_acct   TEXT := CASE WHEN p_v->>'entity_type' = 'recurring_transfer'
                          THEN core.fn_ui_text('finance.recurring_suggest.route', p_lang,
                                   jsonb_build_object('from', p_v->>'account', 'to', p_v->>'to_account'))
                          ELSE COALESCE(p_v->>'account', '') END;
    v_params JSONB;
    v_l      TEXT[];
BEGIN
    v_params := jsonb_build_object('name', v_name, 'amount', v_amount, 'rhythm', v_rhythm, 'date', v_start, 'account', v_acct,
                                   'member', COALESCE(p_v->>'member', ''));
    IF p_mode = 'accepted' THEN
        RETURN core.fn_ui_text('finance.recurring_suggest.msg_accepted', p_lang, v_params);
    ELSIF p_mode = 'declined' THEN
        RETURN core.fn_ui_text('finance.recurring_suggest.msg_declined', p_lang, v_params);
    ELSIF p_mode = 'failed' THEN
        RETURN core.fn_ui_text('finance.recurring_suggest.msg_failed', p_lang, v_params || jsonb_build_object('reason',
                   core.fn_ui_text(COALESCE(p_v->>'reason_key', 'finance.recurring_suggest.reason_failed'), p_lang)));
    ELSIF p_mode = 'owner_notice' THEN
        RETURN core.fn_ui_text('finance.recurring_suggest.owner_notice', p_lang, v_params);
    END IF;
    v_l := ARRAY[core.fn_ui_text(CASE WHEN p_v->>'entity_type' = 'recurring_transfer' THEN 'finance.recurring_suggest.title_transfer'
                                      WHEN p_v->>'direction' = 'income' THEN 'finance.recurring_suggest.title_income'
                                      ELSE 'finance.recurring_suggest.title_expense' END, p_lang),
                 '• ' || core.fn_ui_text('core.label.name', p_lang) || ': ' || v_name,
                 '• ' || core.fn_ui_text('core.label.amount', p_lang) || ': ' || v_amount,
                 '• ' || core.fn_ui_text('finance.label.rhythm', p_lang) || ': ' || v_rhythm,
                 '• ' || core.fn_ui_text('finance.label.first_payment', p_lang) || ': ' || COALESCE(v_start, ''),
                 '• ' || core.fn_ui_text('finance.label.account', p_lang) || ': ' || v_acct];
    IF NULLIF(p_v->>'recurring_kind', '') IS NOT NULL THEN
        v_l := v_l || ('• ' || core.fn_ui_text('finance.recurring_suggest.label_kind', p_lang) || ': '
                       || core.fn_ui_text('finance.enum.recurring_kind' || '.' || (p_v->>'recurring_kind'), p_lang));
    END IF;
    v_l := v_l || ''::text || core.fn_ui_text(CASE WHEN p_v->>'origin_kind' = 'export' THEN 'finance.recurring_suggest.source_export'
                                                ELSE 'finance.recurring_suggest.source_statement' END, p_lang);
    IF p_v->>'confidence' = 'confirm' THEN
        v_l := v_l || core.fn_ui_text(CASE WHEN (p_v->>'rhythm_assumed')::boolean THEN 'finance.recurring_suggest.note_assumed'
                                           ELSE 'finance.recurring_suggest.note_check' END, p_lang);
    END IF;
    RETURN array_to_string(v_l, E'\n');
END;
$$;
