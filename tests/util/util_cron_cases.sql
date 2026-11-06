-- tests/util/util_cron_cases.sql
-- Gemeinsame Cron-Fallliste (EINE Quelle fuer beide Cron-Pruefer):
--   * DB:  tests/db/core/test_config_value_checks.sql bindet die Datei per \ir ein und prueft
--          core.fn_config_cron_valid gegen jeden Fall (die DB-Pruefung hinter `lifeagents config set schedule`).
--   * PS:  scripts/config_test.ps1 liest das JSON zwischen den $cases$-Markern und prueft seinen eigenen
--          Validator (Manifest-Defaults, vor dem Commit) gegen dieselben Faelle -> beide Pruefer koennen nicht
--          auseinanderlaufen.
--   WARUM JSON in einer SQL-Datei (statt reiner .json wie tests/fixtures/fixtures.json): der db_test-Batch-Treiber
--   kann eine Datei nur per \ir einbinden — ein portables Einlesen einer JSON-Datei gibt es in psql nicht (\copy haengt
--   am Arbeitsverzeichnis, Backticks an der Shell); PowerShell liest das JSON per Regex zwischen den Markern.
-- Regeln (beide Pruefer): 5 Felder (Minute Stunde Tag Monat Wochentag) oder 6 Felder mit FESTER Sekunde vorn
-- (n8n-Form; `* * * * * *` = jede Sekunde -> ungueltig). Je Feld: *, n, a-b, Liste mit ',', Schritt /s (s >= 1);
-- keine Namen (MON/JAN). Wochentag 0-7 (0 und 7 = Sonntag).
DO $do$
BEGIN
  PERFORM set_config('lifeagents.cron_cases', $cases$
[
  {"cron": "0 7 * * 1-5",        "valid": true},
  {"cron": "10 * * * *",         "valid": true},
  {"cron": "0 9 1 1,4,7,10 *",   "valid": true},
  {"cron": "*/15 * * * *",       "valid": true},
  {"cron": "0 0 1-31/2 * *",     "valid": true},
  {"cron": "30 9 * * *",         "valid": true},
  {"cron": "0 6 * * 0",          "valid": true},
  {"cron": "0 6 * * 7",          "valid": true},
  {"cron": "5/10 * * * *",       "valid": true},
  {"cron": "0 30 7 * * *",       "valid": true},
  {"cron": "59 59 23 31 12 7",   "valid": true},
  {"cron": "",                   "valid": false},
  {"cron": "abc",                "valid": false},
  {"cron": "0 7 * *",            "valid": false},
  {"cron": "0 0 7 * * * *",      "valid": false},
  {"cron": "60 * * * *",         "valid": false},
  {"cron": "0 24 * * *",         "valid": false},
  {"cron": "0 0 0 * *",          "valid": false},
  {"cron": "0 0 1 13 *",         "valid": false},
  {"cron": "0 0 * * 8",          "valid": false},
  {"cron": "* * * * * *",        "valid": false},
  {"cron": "*/5 0 7 * * *",      "valid": false},
  {"cron": "60 0 7 * * *",       "valid": false},
  {"cron": "0 7 * * MON",        "valid": false},
  {"cron": "5-1 * * * *",        "valid": false},
  {"cron": "*/0 * * * *",        "valid": false},
  {"cron": "1,,2 * * * *",       "valid": false},
  {"cron": "0 7 * * 1-5;",       "valid": false},
  {"cron": "-1 * * * *",         "valid": false}
]
$cases$, true);
END
$do$;
