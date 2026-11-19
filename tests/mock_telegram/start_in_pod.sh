#!/usr/bin/env bash
# start_in_pod.sh — Huelle fuer genericity.yml: startet nur die Telegram-Attrappe; Mechanik und Etiketten stehen in
# tests/mock_pod/start_mocks.sh.
# Aufruf: bash tests/mock_telegram/start_in_pod.sh <projekt> <logordner>      Exit 0 = die Attrappe antwortet auf /__health.
set -euo pipefail
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../mock_pod/start_mocks.sh" "${1:?projekt}" "${2:?logordner}" tg
