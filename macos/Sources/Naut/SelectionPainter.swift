import AppKit

/// Draws a selection background that stops at the last drawn character
/// of each line. TextKit paints a selected newline to the edge of the
/// column; that blue tail looks like trailing whitespace was selected,
/// though no character is there. The selection range is untouched, so
/// copying still carries the line break.
enum SelectionPainter {
    static func draw(in layout: NSLayoutManager, glyphRange: NSRange, at origin: NSPoint) {
        // Read the live selection rather than a cached copy: a mouse drag
        // updates it continuously, but the text view's delegate is only
        // told when the drag ends.
        let selection = layout.firstTextView?.selectedRange() ?? NSRange(location: 0, length: 0)
        guard selection.length > 0, let storage = layout.textStorage else { return }
        let visible = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let all = NSIntersectionRange(selection, visible)
        guard all.length > 0 else { return }

        let text = storage.string as NSString
        let selectedGlyphs = layout.glyphRange(forCharacterRange: all, actualCharacterRange: nil)
        let color = layout.firstTextView?.window?.isKeyWindow == false
            ? NSColor.unemphasizedSelectedContentBackgroundColor
            : NSColor.selectedContentBackgroundColor
        color.setFill()

        layout.enumerateLineFragments(forGlyphRange: selectedGlyphs) { _, used, lineContainer, lineGlyphs, _ in
            let line = layout.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
            let hit = NSIntersectionRange(line, selection)
            guard hit.length > 0 else { return }
            // So does a table selected whole.
            if (layout as? LiveLayout)?.inSelectedTable(hit.location) == true { return }
            var end = NSMaxRange(hit)
            while end > hit.location {
                let c = text.character(at: end - 1)
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { end -= 1 } else { break }
            }
            guard end > hit.location else { return }
            let content = NSRange(location: hit.location, length: end - hit.location)
            // A drawn block shows its own ring when selected.
            if content.length == 1, (layout as? LiveLayout)?.blocks.contains(content.location) == true { return }
            let contentGlyphs = layout.glyphRange(forCharacterRange: content, actualCharacterRange: nil)
            let box = layout.boundingRect(forGlyphRange: contentGlyphs, in: lineContainer)
            NSRect(x: box.minX + origin.x, y: used.minY + origin.y, width: box.width, height: used.height).fill()
        }
    }
}
