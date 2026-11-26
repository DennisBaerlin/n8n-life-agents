-- ============================================================
-- agent.chat_prompts + core.prompt_kinds — die offene Frage eines Chats
--   Anwenden via: db_apply.ps1 -File packages\core\db\agent.chat_prompts_init.sql
--
-- Eine Mechanik fuer alles, was der Bot per Knopf vom Nutzer wissen will (Antwort-Knoepfe, Themen-Karten, Prüfpunkte,
--   Hinweise): stellen -> Tipp oder Text -> erledigt oder ersetzt. Allgemeine Form von "Knopf statt Karte"
--   (docs/reference/packages.md): kein geparkter n8n-Lauf, keine Chat-Sperre, kein Ablauf; Text erreicht den Agenten der
--   Frage (Router-Flag open_prompt_agent, core.fn_advisor_pins). Was ein Tipp speichert, steht in payload derselben Zeile,
--   die die Karte zeigt (gespeichert wird genau das Gezeigte).
-- Bei uns anders: kein Anhalten des Laufs wie bei LangGraph-HITL (das n8n-Gate parkt die
--   Kette und sperrt den Chat); Antwort-Knoepfe kommen aus dem Text-Marker CHOICES statt aus einem Werkzeug (keine Extra-
--   Iteration, ein choice-Tipp schreibt nichts); alles Speichernde laeuft ueber Werkzeuge mit Probelauf; kein Spaeter-Knopf
--   ausser bei Hinweisen.
--
-- Lebenslauf: queued (Stapel batch_id/ord) -> open (gesendet; je Chat hoechstens eine, Partial-UNIQUE) -> answered (Tipp,
--   answer_key) | superseded (neuer Vorschlag, Textantwort auf eine choice). Senden macht immer der Orchestrator
--   (core.fn_next_chat_prompt am Lauf-Ende und im Knopf-Arm), den Tipp core.fn_answer_chat_prompt (Prefix q).
-- card = Karten-SPEZIFIKATION (Zeilen mit Katalog-Key oder Text, Fakten-Platzhalter), gerendert erst beim Senden in der
--   Sprache des Chats (core.fn_render_prompt): "Stand heute" ist so bei jeder Anzeige frisch.
-- Fluechtig wie agent.pairing_state: nicht im Backup (Gespeichertes liegt im Plan); erledigte Zeilen raeumt
--   core.fn_next_chat_prompt nach 30 Tagen je Chat weg. Frei-SQL (core_ro) sieht die Tabelle nicht (nicht auf der
--   Erlaubnisliste in util_create_core_ro.sql); Leser sind die core.fn_*-Fenster.
--
-- core.prompt_kinds: Art -> answer_fn (schema.fn(jsonb)->jsonb), die der Tipp-Handler dynamisch ausfuehrt (Muster
--   core.callback_handlers; CHECK auf den Bezeichner, Aufruf mit to_regprocedure-Guard). Die Arten des Core seedet dieses
--   Init; einen Seed-Weg ueber die Manifeste bekommt die Registry mit der ersten Paket-Art.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS agent;

CREATE TABLE IF NOT EXISTS core.prompt_kinds (
    kind       text PRIMARY KEY CHECK (kind ~ '^[a-z][a-z0-9_]*$'),
    answer_fn  text NOT NULL CHECK (answer_fn ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
    package    text NOT NULL DEFAULT 'core',
    updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO core.prompt_kinds (kind, answer_fn, package) VALUES
    ('choice',  'core.fn_prompt_answer_choice',   'core'),
    ('topic',   'agent.fn_prompt_answer_topic',   'core'),
    ('finding', 'agent.fn_prompt_answer_finding', 'core'),
    ('hint',    'core.fn_prompt_answer_hint',     'core')
ON CONFLICT (kind) DO UPDATE SET answer_fn = excluded.answer_fn, package = excluded.package, updated_at = now();

CREATE TABLE IF NOT EXISTS agent.chat_prompts (
    id          bigserial PRIMARY KEY,
    chat_id     text NOT NULL CHECK (chat_id ~ '^([0-9]{1,18}|test_[A-Za-z0-9_-]{1,60})$'),   -- Telegram-Chat oder Test-Sentinel (core.fn_chat_id_ok)
    person_id   text,                                   -- Person des Chats beim Anlegen (fn_resolve_sender, nie LLM)
    agent       text NOT NULL CHECK (agent ~ '^agent\.[a-z][a-z0-9_]*$'),   -- Agent der Frage: Textantworten und Fortsetzungen gehen dorthin
    kind        text NOT NULL REFERENCES core.prompt_kinds(kind),
    plan_id     int REFERENCES agent.advisor_plans(id) ON DELETE CASCADE,   -- Entwurf, zu dem die Frage gehoert (topic/finding/hint)
    batch_id    uuid NOT NULL DEFAULT gen_random_uuid(),
    ord         int  NOT NULL DEFAULT 1 CHECK (ord >= 0),
    card        jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(card) = 'object'),
    options     jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(options) = 'array'),
    payload     jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(payload) = 'object'),
    status      text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'open', 'answered', 'superseded')),
    answer_key  text,
    message_id  bigint,                                  -- Telegram-Nachricht der zuletzt gesendeten Karte (Knoepfe entfernen)
    created_at  timestamptz NOT NULL DEFAULT now(),
    sent_at     timestamptz,
    decided_at  timestamptz,
    CONSTRAINT chat_prompts_answer_check  CHECK ((status = 'answered') = (answer_key IS NOT NULL)),
    CONSTRAINT chat_prompts_decided_check CHECK ((status IN ('answered', 'superseded')) = (decided_at IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS chat_prompts_one_open_per_chat ON agent.chat_prompts (chat_id) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS chat_prompts_chat_status_idx ON agent.chat_prompts (chat_id, status);
CREATE INDEX IF NOT EXISTS chat_prompts_plan_idx ON agent.chat_prompts (plan_id) WHERE plan_id IS NOT NULL;
