# Tab Manager

A small native macOS app for browsing and bulk-editing the song info (title, artist,
album, etc.) stored inside Guitar Pro files.

## Build & run

    ./build-app.sh             # builds build/TabManager.app
    ./build-app.sh --install   # also copies it to /Applications

Needs only the Xcode Command Line Tools (Swift 6).

The app icon is drawn in code by `Icon/make-icon.swift`; the build re-renders it whenever that script changes.

## Using it

- The first folder you open (**⌘O**) becomes the default and opens at every launch.
  Change or clear it in **Settings (⌘,)**; opening other folders later doesn't change it.
- Search matches every field plus the file path; space-separated words must all match.
- Select several rows (⇧/⌘-click, ⌘A) and edit in the right-hand panel. A field showing
  *Multiple values* sets every selected file once you type into it.
- Edits are staged (orange) until **⌘S**. Revert from the panel or the File menu.
- Right-click → *Fill Artist/Title from Filename* guesses from names like
  `Artist - Title.gp5`, `Artist-Title-09-06-2026.gp`, or `song_title_2.gp4` in an artist folder.
- Double-click opens the file in Guitar Pro.
- **File → Organize Files by Metadata… (⇧⌘O)** moves tabs to `<artist>/<title>.<ext>` inside the
  open folder, e.g. `smAsHing_pUmkins/thru_ruby.gp5` → `the_smashing_pumpkins/thru_the_eyes_of_ruby.gp5`.
  It acts on the selection, or on everything when nothing is selected, and shows every planned move
  for confirmation first. **It can't be undone**; a record of each run is kept in
  `~/Library/Application Support/TabManager/Organize Logs/`. Name clashes get `_2`, `_3`…, nothing
  is ever overwritten, files without an artist and title are left alone, and running it again on an
  organized folder changes nothing.

## Formats

| Format | Files | Notes |
| --- | --- | --- |
| GP3 / GP4 / GP5 | `.gp3 .gp4 .gp5` | Only the header is rewritten; the rest of the file is copied byte-for-byte. Text is Windows-1252, max 255 bytes per field. GP3/4 have no *Music* field. |
| GP6 | `.gpx` | Decompressed, `score.gpif` patched, re-compressed. Other embedded files are untouched. |
| GP7+ | `.gp` | Zip; only `Content/score.gpif` is rewritten. |

Read-only: GP1/2 `.gtp` files and `.gp` files encrypted by their publisher (`editLocked`).

## Safety

Every save re-reads the new file in memory and checks that the edited fields read back
correctly and that nothing else changed, before anything touches disk. The original
is then copied to `~/Library/Application Support/TabManager/Backups/<timestamp>/`
(File → Show Backups in Finder) and replaced atomically.

`swift run -c release tabcheck <folder> --edit` runs this edit/verify/restore cycle
in memory over a whole folder without writing anything. `--organize` really moves files
(then checks nothing was lost), so only use it on a scratch copy.
