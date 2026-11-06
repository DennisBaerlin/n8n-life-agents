-- tests/db/core/test_fn_split_learned_block.sql
-- Phase A: core.fn_split_learned_block(text) — trennt den system-verwalteten "## Gelernt"-Block (bis vor die
-- naechste '## '-Ueberschrift, Leerzeilen + '### ' gehoeren dazu) vom restlichen Prosa-Text.
DO $$
DECLARE
  r RECORD;
BEGIN
  -- kein Block
  r := core.fn_split_learned_block(E'# Plan\nText');
  IF r.block IS NOT NULL OR r.body IS DISTINCT FROM E'# Plan\nText' THEN
    RAISE EXCEPTION 'FAIL [kein Block]: got body=% block=%', r.body, r.block; END IF;

  -- Block am Ende, mit Leerzeile zwischen den Notizen (Append-Layout)
  r := core.fn_split_learned_block(E'# Plan\nText\n\n## Gelernt\n- neu (gelernt am 2026-10-01 aus Chat)\n\n- alt (gelernt am 2026-01-01 aus Chat)\n');
  IF r.block IS DISTINCT FROM E'## Gelernt\n- neu (gelernt am 2026-10-01 aus Chat)\n\n- alt (gelernt am 2026-01-01 aus Chat)'
     OR r.body IS DISTINCT FROM E'# Plan\nText' THEN
    RAISE EXCEPTION 'FAIL [Block am Ende]: got body=% block=%', r.body, r.block; END IF;

  -- Block in der Mitte: endet vor der naechsten '## '-Ueberschrift, '### ' gehoert dazu
  r := core.fn_split_learned_block(E'# Plan\n## Gelernt\n- a\n### Detail\n- b\n## Massnahmen\n- c');
  IF r.block IS DISTINCT FROM E'## Gelernt\n- a\n### Detail\n- b'
     OR r.body IS DISTINCT FROM E'# Plan\n## Massnahmen\n- c' THEN
    RAISE EXCEPTION 'FAIL [Block in der Mitte]: got body=% block=%', r.body, r.block; END IF;

  -- "## Gelerntes" ist NICHT der verwaltete Block (exakter Anker)
  r := core.fn_split_learned_block(E'# Plan\n## Gelerntes aus dem Gespraech\n- x');
  IF r.block IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [exakter Anker]: "## Gelerntes" faelschlich als Block erkannt'; END IF;
  RAISE NOTICE 'PASS fn_split_learned_block [kein Block / am Ende / Mitte + ### / exakter Anker]';
END $$;
