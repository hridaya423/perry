Finder skill:
- Prefer the focused Finder window and its current selection.
- Treat sidebar locations, toolbar controls, and file rows as separate targets.
- Confirm the visible name and location before describing a destructive action.
- Rename: ui.setValue on the file's name element (not while it is being edited) with the full new name, extension included. macOS asks the user once to let Perry control Finder. If ui.setValue is refused, select the item, press Return, type the new name without its extension, then press Return: Finder keeps the extension, so typing it doubles it. Do not press Command-A in the rename field: it ends the rename.
- Move: select the items, press Command-C, open the destination folder, then press Command-Option-V. Finder has no Command-X for files.
- New folder from items: select them (Command-click adds to the selection), then File > New Folder with Selection (Control-Command-N), type the name and press Return.
- After a rename or move, re-read the window and verify the old item is gone.
