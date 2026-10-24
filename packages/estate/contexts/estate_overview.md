---
description: The ONE living read context of the estate package - the full household emergency register rendered fresh from the estate tables at every fetch (Vorsorge documents, provider contracts, digital estate WITHOUT passwords, key contacts, personal records, funeral wishes, storage places, special assets) plus the finance-owned registers (active insurances/accounts/liabilities) when the finance package is installed. LOAD THIS FIRST for any register or event question.
agent_name: estate_advisor
load_strategy: lazy
---

The facts header above this line IS the live household emergency register — it is rendered fresh from the `estate.*` tables (and the finance package's read functions) every time this context is fetched. Nothing here is stored prose; the register tables are the single source of truth, and this document is never a publish target.

How to read it:

- Entries marked `OFFEN` are open gaps the household has not decided yet (e.g. a contract without a death action) — name them proactively when relevant.
- The `Lücken (Gap-Report)` block at the end summarises what is still missing: the expected Vorsorge documents per adult (essential + recommended; children are never nudged), open death actions, key accounts without an access reference, missing personal records, and — when finance is installed — the concrete finance fields still open (a policy's beneficiary/claim deadline, an account's ownership/transmortale Vollmacht). Use it to steer the next capture step.
- `SCHLUESSELKONTO` marks a key digital account (usually e-mail) whose loss blocks password resets everywhere else — in an event, secure these first.
- All access fields are **location references only** (where a password manager/backup lives) — the register never contains passwords, PINs or seed phrases.
- The `Finanz-Register` section mirrors the finance package (active insurances, accounts, open liabilities). When it reports the finance package as absent, financial data is NOT visible here — recommend installing finance instead of capturing financial data anywhere else.
