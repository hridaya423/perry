# Perry middle: composition before polish

Exploration, not an approved implementation plan. Generated pictures test a direction; they do not establish app capability or native UI fidelity.

## What is structurally wrong with the current composition

The hero gives Perry a home in the notch, a physical perch and a clear relationship to a Mac action. The footer gives him a destination beside familiar apps. The middle loses those relationships. The character, headings, explanatory cards and windows occupy unrelated positions. Each section feels assembled independently.

The scale is also inconsistent. Ask enlarges Finder into a near-full-screen marketing container. Learn gives almost the entire screen to a yellow concert poster. Do shrinks the task into an overlapping approval panel. Window dimensions follow the space needed for marketing copy rather than a believable desktop. A persistent wallpaper cannot provide continuity when every foreground relationship changes.

The content introduces a competing brand. After Hours has the strongest color and typography on the page. Its poster has more expression than Perry. The eye remembers the invented event instead of the assistant's behavior.

The icon mismatch is concrete: index.html:119 constructs Finder from a small hand-authored SVG. Native icon proportions and material become especially exposed when the Dock grows. The local system has a Finder.icns reference at /System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns. Implementation should use authoritative app assets or captured native UI, not generated approximations.

The same lower-section Perry SVG pose is reused in Ask, Learn, Do and the Dock. Translation and rotation of one pose do not supply character acting. The body also differs from the more compact hero character. Warmth needs directed attention, posture, timing and a consequence in the scene.

## Three directions to test

A. One continuous task. Follow the same photograph and native window through context, a guided adjustment, and an approved final organization. The photograph's color and crop make continuity visible. Each composition inherits an object from the previous one. Best starting point for a connected page; risk is becoming a narrow photo-utility story unless the supporting explanation establishes broader use.

B. Perry inhabits the desktop. Change the visual relationship between character and UI: peering around an edge, pointing at the exact control, bracing while moving a selection, resting after completion. Keep accurate native UI as a stable anchor for expressive ink. Strongest warmth and memorability; risk is character spectacle overwhelming the action. One meaningful pose per state, never idle looping everywhere.

C. One interactive stage. Replace multiple disconnected scenes with one persistent composition and three levels of help. Ask, Learn and Do change the state of the same task. Strongest simplicity and direct comparison; risk is visitors treating it as a generic tabbed feature section. The stage should remain comprehensible without requiring every mode to be clicked.

## Composition rules for the next round

- One recognizable object must survive each transition.
- One focal action per view; Perry points attention toward it.
- Headline size follows the scene's job. Copy does not become application content.
- Use a wide working view, an intimate close-up, then a quiet result. Avoid three repeated arrangements.
- Windows have consistent material, corner geometry, toolbar metrics and shadows.
- Character poses change with meaning; silhouette and anatomy stay consistent.
- Coral belongs to guidance and human/assistant handoff. It is not a decorative path through the whole page.
- Wallpaper provides a setting at the edges, with enough clear space to read the action.
- App icons are exact reference assets. Image-generated icon details are never implementation masters.
- The final result transitions into the existing footer: window recedes, Dock becomes the focal plane, Perry joins it.

## Proposed sequence for direction A

Entry: keep the hero's environment and Perry on screen. The hero task recedes as a chosen real-world example comes into focus. Do not destroy the scene and introduce a fresh unrelated layout.

Understand: a contextual question appears beside the relevant object. Perry visibly directs attention to the answer's source. The scene remains small enough that the visitor can orient themselves.

Guide: the same object opens into a close-up. Perry moves onto its edge; the action produces a visible before/after. Offer one optional interaction that can be understood by watching.

Delegate: pull back to see what remains. Show the actual proposed task and the user's go-ahead. Display the result in place so the visitor can recognize what changed.

Exit: move the finished artifact out of the focal area. The familiar Dock rises naturally into importance. Perry settles beside Finder, completing the journey into the existing footer.

Mobile should tell the same sequence in ordinary stacked flow, with a visible result and one optional interaction. Dark mode needs the same art direction, with pale ink character/annotations and appropriate native UI treatment; it must be rendered and reviewed separately before implementation is accepted.
