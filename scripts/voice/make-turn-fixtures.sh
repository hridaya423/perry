#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=Packages/PerryCore/Tests/PerryCoreTests/Fixtures/turns
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

fixture() {
    local name=$1 say_text=$2 phrases=$3 noise=$4 snr=$5
    if [ -n "$say_text" ]; then
        say -o "$WORK/$name.aiff" "$say_text"
        swift scripts/voice/turn-fixture.swift "$name" "$WORK/$name.aiff" "$phrases" "$noise" "$snr" "$OUT/$name.json"
    else
        swift scripts/voice/turn-fixture.swift "$name" - "" "$noise" "$snr" "$OUT/$name.json"
    fi
}

fixture short-question "What time is it in Tokyo?" "What time is it in Tokyo?" none 0
fixture short-command "Open my calendar." "Open my calendar." none 0
fixture weather "What's the weather like in Paris tomorrow?" "What's the weather like in Paris tomorrow?" none 0
fixture um-pause "I want to [[slnc 450]] um [[slnc 900]] book a table for two." "I want to|um|book a table for two." none 0
fixture commas "First, open Safari, [[slnc 650]] then go to the news site, [[slnc 650]] and read me the headlines." "First, open Safari,|then go to the news site,|and read me the headlines." none 0
fixture trailing-so "Summarize this page so [[slnc 1000]] I can share it." "Summarize this page so|I can share it." none 0
fixture thinking-pause "Remind me to call [[slnc 800]] Maya at five." "Remind me to call|Maya at five." none 0
fixture fan-command "Turn on do not disturb." "Turn on do not disturb." fan 15
fixture fan-question "How many unread emails do I have?" "How many unread emails do I have?" fan 12
fixture fan-pause "Draft a reply and [[slnc 900]] keep it short." "Draft a reply and|keep it short." fan 15
fixture two-words "Stop reading." "Stop reading." none 0
fixture long-request "Find the spreadsheet I edited yesterday, [[slnc 600]] copy the totals into a new note, [[slnc 600]] and title it budget." "Find the spreadsheet I edited yesterday,|copy the totals into a new note,|and title it budget." none 0
fixture silence-only "" "" none 0
fixture fan-only "" "" fan 15
