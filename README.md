# mdr


Terminal markdown reader build for security, speed, and beautiful output. For people who read markdown in their terminal all day long.

Headlines are clear and beautiful, thanks to compile time bitmap font rendering. This pre-rendering also keeps things secure since there is no font rendering engine in the application.

mdr REQUIRES kitty graphics support and 256colors (use rex, ghostty, or kitty). 


## Build and Run

```sh
zig build
zig-out/bin/mdr notes.md
zig-out/bin/mdr notes.md | less
printf '# Heading\n\n- **item**\n' | zig-out/bin/mdr -
zig build test
```

With zero arguments or a single dash, mdr reads stdin. With one path, it reads
that file. Redirected output is plain UTF-8. A read, write,
argument, or validation error produces a diagnostic on stderr and a nonzero exit.

## Terminal typography

Interactive output uses red headings (palette entry 167) and underlined link labels.
H3 begins with a dark gray `###` (entry 241) followed by an orange-red title
(entry 166 in text mode). Kitty, Ghostty, and WezTerm can display H1 through H3 in embedded
Lusitana Regular. H1 occupies three rows. H2 and H3 each occupy two rows,
with smaller lettering for H3. Each level uses a fixed baseline with more space
above the heading to group it with the paragraph below. The glyphs
have transparent backgrounds and ASCII pair kerning. Heading links retain their
underlines. Long titles and unavailable glyphs fall back to red terminal text.

The reader sends Kitty graphics to every terminal, including terminals advertising
`TERM=dumb`. Terminals that lack the protocol may omit graphical headings.
Pipes and files receive plain text. On Linux the reader uses terminal dimensions when available. Per
document, graphics are limited to 16 megapixels (16 × 1024² pixels).

The executable embeds a bitmap strike generated from the bundled Lusitana
under the [SIL Open Font License](src/fonts/OFL.txt). Font parsing happens
during asset preparation. The reader and normal Zig build use the checked-in
glyph data. To regenerate it, run `tools/bake_font.py` with Python, Pillow
and fontTools.

## Supported Markdown

- ATX headings (one to six leading hashes), unordered and numbered lists, and
  single-level quotes. Paragraph breaks, line breaks, and leading spaces are preserved.
- Simple single-line emphasis and strong spans with asterisks or underscores,
  with terminal bold for strong spans. Inline code uses a soft gray background on light or dark terminals identified by
  `COLORFGBG`, and italics on the default background otherwise. It accepts
  matching runs of one to 32 backticks, including shorter backticks inside the span.
  Inline spans have literal contents.
- Pipe tables use a header followed by a delimiter row with at least three
  hyphens per cell. Colons select left, center, or right alignment. Cells
  support inline formatting and escaped pipes (`\|`). The reader supports
  up to 32 columns and measures widths in 64 KiB batches. Padding is capped
  at 80 spaces per cell and 8 MiB across a document.
- Inline links display their labels. Images display their alt text. Destinations
  are discarded. This simple syntax uses a flat label and ends at the first closing
  parenthesis. The reader never opens document references.
- Backtick and tilde fences accept an optional opening info string and up to
  three leading spaces. Terminal output marks each code line with a colored
  gutter and preserves indentation. A matching fence or EOF ends the block.
  Four spaces or a tab can also start an indented code block after a blank line
  or at the beginning of the document.
- HTML has no special meaning. There is no HTML backend,
  image decoding, shell invocation, or network access.

## Input limits

The reader accepts up to 8 MiB per document including line endings, and 64 KiB
per line excluding LF (a CR before LF counts toward this limit). It normalizes
CRLF to LF and expands each tab to four spaces. A missing final newline is preserved.

Every line, including code and discarded link targets, must contain valid UTF-8.
The reader rejects C0 controls other than tab and accepted line endings, DEL,
C1 controls, and Unicode bidi control characters. It validates each line before
writing it. On a later error, complete earlier lines can appear in the output.
Parsing uses fixed buffers and bounded forward scans. The default build is ReleaseSafe.
