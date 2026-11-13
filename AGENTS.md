# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

## Commands

- **Build:** `zig build`
  - If you're on macOS and don't need to build the macOS app, use
    `-Demit-macos-app=false` to skip building the app bundle and speed up
    compilation.
- **Test (Zig):** `zig build test`
  - Prefer to run targeted tests with `-Dtest-filter` because the full
    test suite is slow to run.
- **Test filter (Zig)**: `zig build test -Dtest-filter=<test name>`
- **Snapshot (macOS app)**: `zig-out/Naut.app/Contents/MacOS/Naut --snapshot out.png [--note Name] [--light] [--publish-popover] [--focus-editor [--caret N | --select A,B]] [--split same|empty|picker]`
  - Renders the window, including the web preview and toolbar, to a PNG
    and quits. `--publish-popover` captures the publish popover instead.
    `--focus-editor` focuses the editor body first, so its cursor and
    selection are in the picture; `--caret N` puts the caret at display
    position N, and `--select A,B` selects that display range.
    `--split` splits right first, the new pane showing that.
    `--hover-block N [--hover-button K]` shows the Nth block's chrome
    (handle, button bar, a picture's resize handles) as if the pointer
    were on it, and the name of its Kth button.
    Needs no Screen Recording permission. Look at a snapshot after every
    UI change; "it builds" is not "it looks right".
- **Editor regression (macOS app)**: `zig-out/Naut.app/Contents/MacOS/Naut --editor-test [--shots dir]`
  - Drives a Live Preview editor of its own (no note is opened) through
    typing, an input method, Backspace, Return, Tab, the arrows, ⌘A, undo,
    an equation edited in place and Helix's keys, and fails unless each
    leaves the Markdown and the selection where a block editor would. A
    case is a line in `EditorTest.cases`: the note before, the keys, the
    note after, with `‸` for the caret and `«…»` for the selection. Add
    one for every editing bug. `--shots dir` also saves the window with
    each kind of block selected.
- **Caret regression (macOS app)**: `zig-out/Naut.app/Contents/MacOS/Naut --caret-test`
  - Focuses the Live Preview body, moves focus to the title, and fails if
    the body caret survives the hand-off or does not return.
- **Title switch regression (macOS app)**: `zig-out/Naut.app/Contents/MacOS/Naut --title-switch-test`
  - Focuses the Live Preview title, switches to another note, and fails
    if that note was renamed with the old note's title.
- **Equation regression (macOS app)**: `zig-out/Naut.app/Contents/MacOS/Naut --math-edit-test --note Name`
  - Types into the note's first `$$` block in place, and fails unless the
    source follows, the editor stays over its block, and Esc returns to
    the text. It edits the note: use a scratch one with a `$$` block.
  - `--snapshot out.png --edit-math` shows the in-place editor.
- **Equation scroll regression (macOS app)**: `zig-out/Naut.app/Contents/MacOS/Naut --math-scroll-test --note Name`
  - Opens the note's `$$` block at the bottom of the window, types spaces,
    and fails if the page moves at any moment. Use a scratch note long
    enough to scroll that ends in a `$$` block.
- **Code scroll regression (macOS app)**: `zig-out/Naut.app/Contents/MacOS/Naut --code-scroll-test --note Name`
  - With the caret on the last line of a code block that ends the note,
    scrolled to the bottom, types spaces and fails if the page moves at
    any moment. Use a scratch note long enough to scroll that ends in a
    fenced code block.
- **Dollar regression (macOS app)**: `zig-out/Naut.app/Contents/MacOS/Naut --dollar-test --note Name`
  - Types a second `$` after a line's lone `$`, and fails unless that
    makes a closed, empty equation, open for editing, above the text that
    follows. Use a scratch note with a `$` line followed by more text.
- **Modal regression (macOS app)**: `zig-out/Naut.app/Contents/MacOS/Naut --modal-test [--keymap helix] [--note Name]`
  - Runs motions, selection, linewise delete and undo in the Live Preview
    body, and checks the cursor shape each mode asks for. Use a scratch
    note: it deletes and undoes, so the file is restored only by undo.
- **Split regression (macOS app)**: `zig-out/Naut.app/Contents/MacOS/Naut --split-test [--frames dir]`
  - Splits right, down and right again inside the stack, moves a divider,
    floats and maximizes a pane, walks the panes and closes them. Fails unless each pane has an editor,
    the new or the next pane takes the keyboard, the nested split stays in
    its stack, the resized pane keeps its size through later splits, and
    the note's text is unchanged. `--frames dir` saves the window through
    each animation, to look at the motion.
- **Formatting (Zig)**: `zig fmt .`
- **Lint (Swift)**: `swiftlint lint --strict` (`--fix` to correct)
- **Formatting (Swift)**: `swiftformat macos/Sources macos/Tests`
  - Both come from the dev shell (`nix develop`, or direnv); their
    settings are `.swiftlint.yml` and `.swiftformat`.
- **Formatting (other)**: `prettier -w .`

## Directory Structure

- Shared Zig core: `src/`
- macOS app: `macos/`
