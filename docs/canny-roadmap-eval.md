# HeyClicky Canny board: full sweep + Perry evaluation

2026-08-26. Source: heyclicky.canny.io/feature-requests. The board renders 10
posts server-side and gates the rest behind client-only pagination, so the list
was assembled by rendering every sort view (top/new/trending) through a text
proxy and merging: **21 unique public requests**. Vote counts are as displayed.
Titles abbreviated.

| # | Votes | Request | Perry verdict |
|---|---|---|---|
| 1 | 36 | Connect your ChatGPT/Claude subscriptions | **Already our core bet.** BYOK is PRD §4's ladder. This is market validation, not a todo — we ship it day one instead of asking permission to exist. |
| 2 | 11 | Optimize for the MacBook notch | Rejected (PRD §5). Their own changelog shows notch pain in nearly every release: hover dwell fixes, jank, stuck states, files vanishing on drop. We inherit none of that failure surface by not living there. |
| 3 | 8 | Launch agents from mobile | Watch. Out of scope v1, but it validates "dispatch language" in the product name — a future companion surface, post-1.0 plugin territory. |
| 4 | 6 | Custom remote MCP support | Adopt-shaped. Our runtime already speaks MCP for computer-use; exposing user-configurable MCP servers fits the Custom tier (PRD ladder #4). P2. |
| 5 | 6 | Let me see conversations with clicky | Adopt. Conversation/transcript history is cheap locally (we already store activity logs); a History tab is P2 polish with real pull. |
| 6 | 6 | Mute spoken responses during meetings + readable response history | Adopt the second half (same as #5). Meeting-aware muting is a nice P3 idea; ties into their audio-ducking request (#16). |
| 7 | 6 | Local memory folder + teachable skills like CLAUDE.md / skills | **Already our architecture.** Local memory store ships in v1; teachable local skills are hermes-agent-format markdown. This request is users asking HeyClicky to become what Perry already is. |
| 8 | 5 | Custom AI agents/models (OpenRouter, custom endpoints) | Already shipped by design: PRD ladder #4 is any Anthropic/OpenAI-compatible base URL. |
| 9 | 5 | Shortcut to select screen area → text box chat instead of talking | Adopt. Spatial context + typed fallback. Our overlay draws user ink already; region-select-to-ask is a natural P2 Guide feature. |
| 10 | 5 | Custom MCP integration (duplicate of 4/6 cluster) | Same as #4. MCP customization demand is loud — three separate requests in the top 10. |
| 11 | 4 | Text-first mode (turn off speech, replies in cursor text) | Adopt. Cheap: gate `speak()` behind a setting, keep bubbles. Also good accessibility posture. P2. |
| 12 | 3 | Pause/redirect/resume an active agent | Adopt conceptually. Maps to our thread resume/steer semantics from their prompt contract; DoSupervisor would need a paused state. P2/P3, needs care around trust tiers mid-run. |
| 13 | 2 | Always-on mic for wake word | Partially adopted already (opt-in wake word exists), but always-listening conflicts with PRD §3 principle 2 ("no ambient watching"). Keep opt-in-per-session; document why we won't go full always-on. |
| 14 | 2 | Camera access (VR headset use case) | Reject for v1 (PRD §5 adjacent). Interesting signal that people want Perry seeing non-screen context someday; note only. |
| 15 | 2 | Chat history + live transcription | Same as #5/#6 cluster. History tab covers it. |
| 16 | 2 | Duck other audio while HeyClicky speaks | Adopt as polish (P3): AVAudioApplication/AVAudioSession ducking during TTS playback. Small, delightful. |
| 17 | 1 | Spotify/other app connectors + code-session terminal | Integrations rejected for v1 (PRD §5). Terminal sessions are effectively our CLI runtime already. |
| 18 | 1 | App hidden from Dock | Already done (`LSUIElement`, accessory activation policy). Free win — we match their most-polished behaviors by default. |
| 19 | 1 | More keys eligible for shortcut shortcuts | Adopt: our hotkey remap setting (PRD §4 Settings surface) should accept modifier combos incl. double-tap like theirs. P2. |
| 20 | 1 | More playful cursor | Cosmetic; ours already waves/runs/listens. Watch user feedback once real users exist. |
| 21 | 1 | BYOM + persistent memory | Duplicate validation of #1 and #7 — again, users begging for Perry's defaults. |

## What the board tells us strategically

The top of their board is a mirror of Perry's PRD: 4 of the top 10 requests
(#1, #7, #8, #21, ~48 combined votes) are users demanding bring-your-own-models
and local memory/skills — the exact things HeyClicky's subscription backend
can't give them without cannibalizing revenue, and the exact things Perry gives
away. That's the wedge, confirmed by their own customers.

Second cluster: MCP customization (#4, #10) and conversation visibility
(#5, #6, #15) — power-user trust and extensibility asks that fit our Custom
tier and local-logs architecture naturally.

Nothing on the board contradicts PRD scope decisions except mobile dispatch,
which stays parked.
