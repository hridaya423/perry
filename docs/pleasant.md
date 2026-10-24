# What "pleasant" means for Perry

Perry is judged against this list. Each rule names its source and how Perry checks it.

Sources: Craig Mod, [Fast Software, the Best Software](https://craigmod.com/essays/fast_software/);
Rauno Freiberg, [Invisible Details of Interaction Design](https://rauno.me/craft/interaction-design);
Jakob Nielsen, [Response Times: The 3 Important Limits](https://www.nngroup.com/articles/response-times-3-important-limits/);
Amber Case, [Calm Technology](https://calmtech.com/); Emil Kowalski's design engineering notes.

## Speed

1. Every input shows a result or an acknowledgement within 100 ms. (Nielsen)
2. A wait over 1 s says what Perry is doing. A wait over 10 s shows progress and a way to stop. (Nielsen)
3. Typing never redraws more than the field and what depends on it. (Mod: Ulysses redrawing the document)
4. Perry gets faster with use: warm what the next action needs. (Mod)

## Motion

5. Keyboard-initiated open and close do not animate. Pointer-initiated ones may, under 300 ms. (Kowalski, Raycast)
6. Every animation is interruptible and retargets from where it is. (Freiberg)
7. Motion starts from its source: the panel grows from the notch it lives in. (Freiberg: launch from the source)
8. Exits are faster than entrances. Nothing pops out of existence or appears from nothing. (Kowalski)

## Attention

9. Perry needs the least attention possible. It informs at the periphery (the notch) and moves to the centre only when the user must act. (Case)
10. One instruction at a time. Never two hints for the same moment. (Case: minimum needed)
11. Perry never takes keyboard focus the user did not hand it. (Mod: do not break flow)
12. When something fails, Perry stays usable and says what happened and what to do next, with one action. (Case: works when it fails)

## Trust

13. Plain words. No jargon, no ambiguous buttons. (Mod: "Don't Save")
14. Destructive actions wait for explicit confirmation; reversible ones do not ask. (Freiberg)
15. Escape always backs out one level, and the cursor is where the user expects on return. (Mod: nvALT)
16. Edge cases are handled invisibly: no stale drafts, no test data, no surprises after sleep or display changes. (Kowalski: Sonner)
