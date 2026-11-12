-- finance:V041 — die finance-Kopie der Regel "sieht der Absender den Haushalt?" entfaellt; die eine Adresse ist
--   core.fn_sender_sees_household (Tor im Vermittler agent.sub_dispatch_agent, Paket C "Kinder-Sicht").
DROP FUNCTION IF EXISTS finance.fn_sender_sees_household(text);
