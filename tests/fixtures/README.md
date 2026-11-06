# Erfundene Testwerte

Das Repo ist öffentlich. Testfälle, Notizen, Kommentare und Doku-Beispiele nehmen ihre Werte aus diesem Vorrat oder erfinden neue. Nichts davon stammt aus einem echten Haushalt.

## Personas

| Rolle | Name |
|---|---|
| Owner | Erika Mustermann |
| Partnerin | Lena Beispiel |
| Kinder | Lisa Mustermann, Kim Beispiel, Tom |
| Haushalt der Mini-App-Tests (`tests/util/util_app_household.sql`) | Jonas, Mira, Lea, Tom |

## Werte

| Art | Erlaubt |
|---|---|
| Bank, Firma, Ort | Musterbank, Testbank, Beispielbank, Lindenbank, Eichenbank, Birkenbank, Testbroker, Beispiel GmbH, Beispielstadt |
| Versicherung, Krankenkasse | Lindenversicherung, Eichenversicherung, Birkenversicherung, Buchen BKK |
| Echte Anbieter | nur wo die Funktion an ihnen hängt: Import-Profile, Broker-Kalender und ihre Tests |
| IBAN | `DE02 1001 0010 0006 8201 01`, `DE89 3704 0044 0532 0130 00` |
| Domain, E-Mail | `example.com`, `.test` ([RFC 2606](https://www.rfc-editor.org/rfc/rfc2606.html)) |
| IP-Adresse | die Allowlist in `scripts/privacy_lint.ps1` |
| Betrag, Stückzahl, Kurs, Datum | frei erfunden, nie aus einem Auszug übernommen und nie „leicht verändert“ |

## Einen Befund nachbauen

1. **Nur die Eigenschaft weitergeben.** Der Auftrag an die bauende Session lautet zum Beispiel „Rundungsfall bei kleiner Stückzahl“. Der Originaltext aus dem Gespräch und der echte Wert bleiben im privaten Bericht.
2. **Werte neu erfinden,** die Eigenschaft behalten (der Rundungsfall bleibt ein Rundungsfall).
3. **Anlass neutral nennen:** „Befund <Datum>“ und die Eigenschaft. Keine Person, keine Bank, kein Betrag, kein Hinweis auf den Haushalt, kein Vermerk, dass etwas „echt“ oder „live“ so war.

`scripts/privacy_lint.ps1` findet echte Werte, `scripts/owner_fact_lint.ps1` typische Formulierungen. Umschreibungen findet erst die Modell-Prüfung vor jedem Push (`/privacy-review`).
