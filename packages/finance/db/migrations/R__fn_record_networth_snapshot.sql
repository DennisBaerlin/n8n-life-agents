-- fn_record_networth_snapshot (WRITE) -- Vermoegens-Tagesstand des Haushalts festhalten
--   Ersetzt alle Zeilen von finance.networth_snapshots fuer den heutigen Tag (core.fn_today) durch den aktuellen Stand
--   aus finance.networth_items, je (Objekt, bucket, Klasse, Person) summiert. Frueherer Tage schreibt sie nie (kein
--   Nachholen: ein spaeterer Lauf kennt den damaligen Stand nicht). Mehrfach am Tag aufgerufen bleibt der letzte Stand.
--   Eingabe: keine. Aufrufer: agent.finance.cron_networth_snapshot (stuendlich, finance_rw).
--   Rueckgabe: {ok:true, snapshot_date, net_worth_eur (Summe von networth_by_asset_class.value_eur, Kredite negativ),
--     has_fx_gap (mind. ein Wert ohne Wechselkurs)}. Keine ok:false-Zweige.
--   Seiteneffekte: DELETE + INSERT auf finance.networth_snapshots (nur snapshot_date = heute), in einer Transaktion.
--     Ein Advisory-Lock je Transaktion serialisiert gleichzeitige Laeufe (Stunden-Plan + Test run), sonst liefe der
--     zweite INSERT nach dem eigenen DELETE in die UNIQUE des ersten.
--   plpgsql, VOLATILE, SECURITY INVOKER (finance_rw liest/schreibt nur finance.*, core.fn_today ist PUBLIC).
--   Tests: tests/db/finance/test_fn_record_networth_snapshot.sql
CREATE OR REPLACE FUNCTION finance.fn_record_networth_snapshot()
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_day date := core.fn_today();
  v_net numeric;
  v_gap boolean;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('finance.fn_record_networth_snapshot'));

  DELETE FROM finance.networth_snapshots WHERE snapshot_date = v_day;

  INSERT INTO finance.networth_snapshots
         (snapshot_date, item_kind, item_id, bucket, asset_class, owner_person_id, value_eur, has_fx_gap)
  SELECT v_day, item_kind, item_id, bucket, asset_class, owner_person_id,
         sum(value_eur),
         COALESCE(bool_or(value_native <> 0 AND value_eur IS NULL), false)   -- Praedikat wie networth_by_asset_class
  FROM finance.networth_items
  GROUP BY item_kind, item_id, bucket, asset_class, owner_person_id
  -- Ohne Wert und ohne Luecke (Fremdwaehrungs-Konto mit Saldo 0 ohne Kurs, Position ohne Kurs und ohne Einstand):
  -- traegt in networth_by_asset_class nichts bei und verletzte den Wert-CHECK -> weglassen statt 0 zu erfinden.
  HAVING sum(value_eur) IS NOT NULL OR bool_or(value_native <> 0 AND value_eur IS NULL);

  SELECT COALESCE(sum(value_eur), 0), COALESCE(bool_or(has_fx_gap), false) INTO v_net, v_gap
  FROM finance.networth_by_asset_class;

  RETURN jsonb_build_object('ok', true, 'snapshot_date', v_day, 'net_worth_eur', v_net, 'has_fx_gap', v_gap);
END $$;
