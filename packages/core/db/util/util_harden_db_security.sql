-- ============================================================
-- util_harden_db_security.sql — operatives DB-Hardening (idempotent)
--   Anwenden via: db_apply.ps1 -File packages/core/db/util/util_harden_db_security.sql
--
--   Adressiert die search_path-/CVE-2018-1058-Klasse fuer dieses SINGLE-ROLE-Deployment:
--   1. Niemand (PUBLIC) darf in schema public Objekte anlegen -> entfernt die Flaeche, auf der ein
--      Angreifer ein shadowendes public.round()/public.= o.ae. platzieren koennte (PG15+ ist das
--      Default; aelter initialisierte Cluster brauchen das explizit).
--   2. Deterministischer search_path fuer die n8n-DB-Rolle: Tabellen sind ohnehin agent./core.-
--      qualifiziert; das fixiert zusaetzlich die Aufloesung von Operatoren/Casts/Builtins (pg_catalog
--      zuerst), die in den fn_* unqualifiziert sind.
--
--   HINWEIS: dieses `ALTER ROLE current_user` pinnt den search_path der APPLIZIERENDEN Superuser-Rolle
--   (postgres — beide Apply-Pfade verbinden als postgres: provisioning `runuser -u postgres`, dev PGUSER=postgres),
--   NICHT die Agent-Rollen. Die HOST-WEITEN Rollen (n8n-Owner + core_ro) tragen ihren Paket-Tail generisch ueber
--   core.fn_sync_role_search_paths (Desired-State aus core.package_registry, B); die ENGEN <pkg>_ro/_rw setzen
--   ihren eigenen Pfad in fn_provision_package_roles. per-function "SET search_path" bleibt der Belt fuer die
--   SECURITY-DEFINER-fns (CVE-2018-1058).
-- ============================================================

DO $$ BEGIN
    REVOKE CREATE ON SCHEMA public FROM PUBLIC;
    RAISE NOTICE 'REVOKE CREATE ON SCHEMA public FROM PUBLIC: ok';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'REVOKE CREATE ON public skipped (insufficient privilege as %): %', current_user, SQLERRM;
END $$;

DO $$ BEGIN
    EXECUTE format('ALTER ROLE %I SET search_path = pg_catalog, agent, core', current_user);
    RAISE NOTICE 'search_path default fuer Rolle % gesetzt: pg_catalog, agent, core', current_user;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'ALTER ROLE search_path skipped (insufficient privilege): %', SQLERRM;
END $$;
