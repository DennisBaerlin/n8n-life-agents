#!/usr/bin/env bash
# roundtrip_cases.sh — Schritte des Roundtrip-Tests „alles wie vorher“ (scripts/dev/backup_roundtrip_test.ps1), laeuft IM master eines
#   Docker-Verbunds mit der CLI dieses Abbilds (oder, Gegenlauf, mit einem aelteren Baum ueber LIFEAGENTS_CLI).
#   seed      erfundene Daten in jeden Teil der Sicherung: geaenderte Einstellungen, ein Gespraech (Tabelle als n8n-Rolle, wie der
#             Chat-Memory-Knoten sie anlegt), KI-Kosten, ein "schon gezeigt"-Merker, die Sperrliste, ein Paperless-Zugang.
#             Dazu Wechselkurse (Feed + EZB) ueber finance.fn_upsert_fx_rates, damit der Kurs-Abruf nicht faellig ist.
#   fx        "<Kurse>/<Waehrungen>" der geseedeten Kurse mit genauem Wert (Soll 3/2); backup_fingerprint zaehlt dort nur Zeilen.
#   fxdue     "<Feed faellig>/<EZB-Nachlauf faellig>" (Soll false/false): nur dann holt der Cron keine Netz-Kurse in den Vergleich.
#   export    Sicherung + Notfallblatt nach /tmp/rt (Blatt = Schluessel der Quelle; das frische Ziel hat einen eigenen).
#   restore   die Sicherung aus /tmp/rt mit dem Blatt einspielen (wie die Start-App ohne Terminal).
#   fp <datei> Fingerabdruck (lifeagents backup fingerprint) in die Datei; immer mit der CLI dieses Abbilds.
#   subset    Anzahl der geseedeten KI-Kosten- und Merker-Zeilen auf dem Ziel (Soll 2; backup_fingerprint laesst beide Tabellen
#             aus, weil das Ziel dort eigene Zeilen schreibt).
# Testdaten erfunden (tests/fixtures/README.md). Ausgabe "PASS <fall>" / "FAIL <fall>: <grund>"; Exit = Anzahl FAIL.
# real-path-test: dieser Test ist der echte Weg (Docker-Verbund, echtes PostgreSQL und n8n, Attrappen nur fuer Telegram/KI/Paperless).
# shellcheck disable=SC2016,SC2015  # SQL-Literale in einfachen Quotes; "a && pass || fail" ist das Fall-Muster (fail zaehlt nur)
set -uo pipefail
CLI="${LIFEAGENTS_CLI:-lifeagents}"
D=/tmp/rt; mkdir -p "$D"; chmod 0700 "$D"
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
LIB=/usr/local/lib/lifeagents; [ -r "$LIB/provisioning/lib/common.sh" ] || LIB=/opt/lifeagents
# shellcheck source=/dev/null
. "$LIB/provisioning/lib/common.sh"
lifeagents_db_name >/dev/null
sql() { pg_su_psql -X -tA -v ON_ERROR_STOP=1 -d "$N8N_DB_NAME" -c "$1"; }
MEM=agent.rtzz_chat_memory

case "${1:-}" in
  seed)
    "$CLI" config set cron_enable learn_context true >/dev/null 2>&1 && pass seed.einstellung || fail seed.einstellung "config set"
    "$CLI" config set general reminders_from 9 >/dev/null 2>&1 || true
    owner="$(read_env_value "${N8N_ENV_FILE:-/etc/n8n/n8n.env}" DB_POSTGRESDB_USER 2>/dev/null || true)"
    sql "DROP TABLE IF EXISTS ${MEM}; SET ROLE ${owner};
         CREATE TABLE ${MEM} (id SERIAL PRIMARY KEY, session_id VARCHAR(255) NOT NULL, message JSONB NOT NULL); RESET ROLE;
         INSERT INTO ${MEM} (session_id, message) SELECT 'rt-' || g, jsonb_build_object('type', 'human', 'data', jsonb_build_object('content', 'Erfundene Frage ' || g)) FROM generate_series(1, 4) g;
         INSERT INTO core.llm_usage (id, ts, model, input_tokens, output_tokens) VALUES ('1762000000000-abcdef-000001', now() - interval '3 days', 'rt', 120, 30) ON CONFLICT DO NOTHING;
         INSERT INTO core.notification_state (source, key, state) VALUES ('plan_news', 'rt-erfunden', 'fired') ON CONFLICT DO NOTHING;
         INSERT INTO agent.access_blocks (telegram_user_id, reason) VALUES (912345, 'erfunden') ON CONFLICT DO NOTHING" >/dev/null \
      && pass seed.teile || fail seed.teile "SQL"
    # Wechselkurse ueber die echte fn (Tages-Modus: Feed-Zeilen von heute; Zeilen-Modus: ein EZB-Tag). Zwei Gruende: Die Tabellen sollen
    # die Sicherung nachweislich ueberleben (ohne Zeilen verglichen 0 mit 0), und ohne Kurse ist der Abruf des Wechselkurs-Crons
    # faellig: sein n8n-Start-Eingang holt dann 30 s nach dem Start Feed + 5 Jahre EZB aus dem Netz (165 + 38000 Zeilen), im Ziel zu einem
    # anderen Zeitpunkt als in der Quelle; der Restore raeumt sie je nach Reihenfolge wieder weg oder nicht.
    sql "SELECT finance.fn_upsert_fx_rates('{\"rates\": {\"USD\": 1.23456, \"CLP\": 987.65}}'::jsonb);
         SELECT finance.fn_upsert_fx_rates(jsonb_build_object('source', 'ecb', 'rows', jsonb_build_array(
           jsonb_build_object('date', (now() AT TIME ZONE 'UTC')::date - 3, 'base', 'EUR', 'quote', 'USD', 'rate', 1.11111))))" >/dev/null \
      && pass seed.kurse || fail seed.kurse "SQL"
    # Ein Zugang, den eine frische Installation nicht hat (die Testinstallation gibt keine Karriere-Schluessel ein): er muss aus der
    # Sicherung kommen. Ein Schluessel, den das Ziel schon hat, bliebe dort (gewollt) und zaehlte hier als Abweichung.
    if [ -r "$(lifeagents_env_file career)" ]; then
      ( umask 077; env_upsert "$(lifeagents_env_file career)" JSEARCH_API_KEY 'rt-erfundener-token-0001' ) && pass seed.zugang || fail seed.zugang "env"
    else
      printf 'SKIP seed.zugang: Karriere nicht installiert\n'
    fi
    ;;
  export)
    rm -f "$D"/*.nla.enc
    "$CLI" backup export "$D/rt.nla.enc" > "$D/export.log" 2>&1 && pass export.ok || fail export.ok "$(tail -n3 "$D/export.log")"
    "$CLI" backup key --file - > "$D/rt.key" 2>/dev/null && [ -s "$D/rt.key" ] && pass export.blatt || fail export.blatt "kein Blatt"
    ;;
  restore)
    "$CLI" backup restore "$D/rt.nla.enc" --yes --key-stdin < "$D/rt.key" > "$D/restore.log" 2>&1 && pass restore.ok || fail restore.ok "$(tail -n5 "$D/restore.log")"
    if grep -qF 'rt-erfundener-token-0001' "$D/restore.log"; then fail restore.kein-zugang-im-protokoll "Wert im Protokoll"; else pass restore.kein-zugang-im-protokoll; fi
    ;;
  fp)
    lifeagents backup fingerprint > "$2" 2> "$D/fp.err" && [ -s "$2" ] && pass "fp.$(basename "$2")" || fail "fp.$(basename "$2")" "$(tail -n3 "$D/fp.err")"
    ;;
  subset)
    sql "SELECT (SELECT count(*) FROM core.llm_usage WHERE id = '1762000000000-abcdef-000001')
              + (SELECT count(*) FROM core.notification_state WHERE source = 'plan_news' AND key = 'rt-erfunden')"
    ;;
  fx)
    # Die geseedeten Kurse mit genauem Wert (Soll 3: USD und CLP vom Feed, USD von der EZB) und ihre Waehrungen (Soll 2: USD, CLP).
    sql "SELECT (SELECT count(*) FROM finance.fx_rates WHERE (quote_currency, rate, source) IN (('USD', 1.23456, 'open.er-api.com'), ('CLP', 987.65, 'open.er-api.com'), ('USD', 1.11111, 'ecb')))
              || '/' || (SELECT count(*) FROM finance.currencies WHERE code IN ('USD', 'CLP'))"
    ;;
  fxdue)
    # Faelligkeit des Kurs-Abrufs, so wie der Cron sie fragt (Feed: fn_feed_refresh_due, EZB-Nachlauf: fn_fx_history_due). Soll
    # "false/false": ist einer faellig, schreibt der n8n-Start-Eingang des Crons Netz-Kurse in diese Datenbank, wann er will.
    sql "SELECT finance.fn_feed_refresh_due('fx') || '/' || (finance.fn_fx_history_due()->>'due')"
    ;;
  *) printf 'Usage: roundtrip_cases.sh seed|export|restore|fp <datei>|subset|fx|fxdue\n' >&2; exit 2 ;;
esac
exit "$fails"
