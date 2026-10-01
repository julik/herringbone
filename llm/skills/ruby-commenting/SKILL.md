---
name: ruby-commenting
description: Writing or editing Ruby code, in any repo. Governs whether a comment gets written at all, and how it must sound when it does. Applies julik's terse hand-written comment style. Covers implementation comments only, not YARD/doc comments.
---

# Ruby comments in julik's style

The default is **no comment**. Ordinary Ruby - CRUD, validations, guard clauses,
Enumerable chains, plain method calls - runs uncommented for long stretches. A
comment exists only where the code cannot say the thing itself. Verbatim examples
in [exemplars.md](exemplars.md); read them before writing.

## When a comment is allowed

- **Why, not what**: a framework quirk, spec constraint, or workaround - and name
  the guilty party. "Have to use the old-fashioned heredocs because ZipKit aims to
  be compatible with MRI 2.1+ syntax, and squiggly heredoc is only available
  starting 2.3+"
- **Trap warnings** for the next reader: "the schema define block is run via
  instance_exec so it does not retain scope". Repeat the warning verbatim wherever
  the trap recurs.
- **Magic values and units**, as trailing fragments: `# pixel count`, `# Max35Text`,
  `# in tests`, `# always return 0!`
- **Provenance**: a bare URL when the URL is the evidence -
  "See https://stackoverflow.com/questions/73184531/..." closing a paragraph that
  explains the trap it documents.
- **Test intent**: what the assertion proves, one clause, often trailing -
  "Oversized fillup must be refused outright".
- **Step narration only in long sequential methods** (binary formats, multi-phase
  jobs): short imperative beats - "Parse out the extra fields" - with continuation
  lines chained by ellipsis: "...and then ask for a new one".

## Form

- Median 6-9 words per line, 1-2 lines per block. A 4-8 line paragraph is allowed
  only for a genuinely hairy mechanism, and is rare.
- Sentence case first letter; **no trailing period on one-liners**. Continuation
  lines start lowercase or with "...".
- Wrap by breath at 90-115 chars, not at a hard column.
- Spaced hyphen " - " as the dash. Never an em-dash.
- Trailing comments are welcome: lowercase fragments, no period.
- `_underscore_` emphasis; backticks or quotes around identifiers.
- Never "fix" spelling or restyle existing comments unless asked.

## Voice

- "We" for design decisions ("We conceal that the account does not exist");
  imperative for steps; "I" essentially never.
- Hedge honestly: "apparently", "roughly", "just yet", "weird-ish", "not 100% sure
  if this is the way to do this yet".
- Dry wink allowed but sparse - aimed at specs and libraries, never people:
  "For security™", "Bah.", ":-(", "but hey!". At most one per file you touch, and
  only when the frustration is real.
- The stack may be anthropomorphized: "the DB will complain if passed a negative".

## Never

- Narrating the next line: "Create the...", "Loop over...", "Clean up",
  "Verify that...", "Should be...".
- "Step 1:" scaffolds, section banners, dividers, "Note:"/"Important:"/ALL-CAPS
  labels ("KEY ASSERTION").
- Param/return prose or restated method names - that is YARD's job.
- The same stock phrase pasted at several sites (write it once where it matters).
- TODO farms. A TODO must be specific and actionable; about one per change, tops.
- Author/date/ticket tags; third person about the project itself ("Once Pecorino
  is fixed...").
- Comments that explain your change to a reviewer instead of the code to a reader.

## Self-check before finishing

Reread every comment you added. If the code beneath it says the same thing, delete
it. If a method reads fine without its comments, they go. When in doubt, the
comment loses.
