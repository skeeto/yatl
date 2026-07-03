# Note: yatl's indentation model vs. TOON spec §12 (strict mode)

Status as of yatl commit `be2edfe`. This note describes a structural difference
between yatl's indentation handling and what the TOON specification (v3.3)
requires of a strict-mode decoder. It is not a report of a crash or a
mis-decode of well-formed input; with one exception noted at the end, every
document produced by a conforming TOON encoder parses identically under both
models. The difference is in *which malformed or hand-written documents get
rejected*, and how. Because the model looks deliberate — it fits the parser's
streaming design and is applied consistently — this is written up as a design
observation rather than patched, pending the author's read on intent.

## What the spec requires

Spec §12 ("Indentation and Whitespace"), strict mode (the default):

- The number of leading spaces on a line MUST be an exact multiple of
  `indentSize` (default 2); otherwise the decoder MUST error.
- Tabs used as indentation MUST error.
- §13 lists `indentSize` as a decoder option, implying depth is computed as
  `leadingSpaces / indentSize` against a fixed document-wide unit.

The spec repository's test fixtures
(`tests/fixtures/decode/indentation-errors.json`) make this concrete: with
`indentSize=2` (default) and `strict=true`, `"a:\n   b: 1"` (three spaces)
must error; `"a:\n\tb: 1"` and `"\ta: 1"` (tab in indentation) must error;
four-space indentation is accepted only under `indentSize=4`.

## What yatl implements

yatl (`src/yatl_parser.c`) has no `indentSize` concept and no configuration
option for it. Indentation is validated *relationally*, per open container:

- Each container frame records the column of the line that opened it, and
  learns the column of its first child when that child arrives
  (`header_indent` / `child_indent` in `yatl_frame`).
- A container's first child must be strictly deeper than the container's
  anchor column — by any number of spaces.
- Subsequent children must align at exactly the first child's column. A line
  indented deeper errors (`"unexpected indentation"`); a shallower line closes
  containers until a recorded child column matches (`reconcile()`).
- For an object introduced on a list-item hyphen line (`- key: …`), the anchor
  column for nested structure is the hyphen column + 2, i.e. the column just
  past `"- "`.
- Only U+0020 counts as indentation. There is no explicit tab check; a line
  "indented" with a tab is parsed as if the tab were content.

## Observable differences

Accepted by yatl, rejected by a spec-strict decoder:

- Any per-container indent width, including non-multiples of 2:
  `"a:\n   b: 1"` (three spaces) parses as `{"a":{"b":1}}`.
- Different widths in different subtrees of one document (e.g. three spaces
  under one key, five under a sibling), as long as siblings within each
  container align.

Rejected by both, but with different diagnostics:

- Misaligned siblings error under both models (yatl: `"unexpected
  indentation"`, or a count/structure error when the misalignment first closes
  an open array).
- Tab-led lines error under both models, but yatl reports a content-level
  error (e.g. `"expected object key"`, `"unquoted value requires quoting"`)
  rather than an indentation error, because the tab is treated as content.

Not available:

- The `indentSize` decoder option (§13) does not exist; there is no fixed unit
  to configure.

## Why this looks intentional

- yatl is a streaming, line-oriented pushdown parser (see the README and
  `src/yatl_parser.h`); the relational model needs no configuration, keeps all
  indentation state inside the per-container frames it already maintains, and
  accepts any self-consistent style.
- Output of a conforming encoder — fixed indent unit, spaces only — is always
  column-consistent, so both models accept it and derive the same structure.
  The divergence is limited to hand-authored or malformed input.
- §12's *non-strict* mode explicitly grants latitude of roughly this kind
  (depth MAY be computed as `floor(spaces/indentSize)`; tab policy is
  implementation-defined but must be documented). yatl's model resembles a
  documented non-strict policy, although yatl otherwise behaves as a strict
  decoder (length, quoting, escape, header, and blank-line validation).

## Related observation: hyphen-line anchoring rejects one conforming shape

This one is a concrete parse failure rather than a style-leniency question,
and it is unclear whether it is intended. It is a direct consequence of the
anchor-column rule for hyphen lines.

When a list-item object's first field is a **list-form** array
(`- key[N]:`), the spec places the nested array's items one level below the
hyphen line — i.e. at hyphen column + 2 with the default unit (§9.4 decoding:
items at "depth +1"; the shape appears in the spec fixture
`tests/fixtures/decode/blank-lines.json`, "throws on blank line in nested list
array"). yatl anchors the nested array at hyphen column + 2 and requires its
first child strictly deeper, so the spec placement fails:

```
outer[1]:
  - inner[2]:
    - a
    - b
```

yatl: `parse error: array length does not match declared count` (the `inner`
array closes with zero items when `- a` at column 4 is not deeper than the
anchor at column 4). Encoders following §9.4/§10 emit exactly this shape, so
this is the one known case where conforming encoder output is rejected.

The disagreement runs both ways: yatl instead accepts the items at column 6
(`      - a`), which a spec-strict decoder would reject as a depth jump. Note
that the analogous **tabular** first field (`- key[N]{f,g}:` with rows at
hyphen + 4 columns) is unaffected, because §10 explicitly places rows at depth
+2, which clears yatl's anchor.

A follow-up field of the same list-item object at hyphen + 2 columns after the
nested items (e.g. `status: done` directly below `- b` at the same column) is
likewise rejected by yatl (`"expected list item ('- ')"`), while §10 decodes
it as a sibling field that terminates the nested array.
