# How yatl differs from yajl in what it accepts

yatl's public API and number-handling model are deliberately modeled on
[yajl](https://lloyd.github.io/yajl/) (see `README.md`). The two libraries parse
*different grammars* — yajl reads JSON, yatl reads TOON — so at the surface they
accept entirely different text. That grammar difference is the point of the
library and is **not** what this document is about.

This document lists the places where, on the **shared, yajl-derived number
model**, yatl accepts input that yajl rejects (or parses differently). After the
changes described below there is exactly one such topic: **integer out-of-range
handling**. Everything else about numeric lexing — the JSON number grammar (no
leading zeros, required integer part, optional fraction/exponent), the
integer-vs-double classification, the verbatim `yatl_number` override, and
UTF-8 string validation — behaves exactly as in yajl.

## Integer out-of-range handling

yajl treats any integer it cannot fit in a `long long` as a hard error unless a
verbatim `yajl_number` callback is installed. yatl instead treats the numeric
lexeme as the fact and the typed conversion as a lossy convenience, so an
out-of-range integer degrades through a ladder of delivery channels and only
fails the parse when *none* of them exists:

    yatl_number (verbatim)  →  yatl_error hook  →  widen to yatl_double  →  parse error

Concretely, yatl differs from yajl in two ways:

1. **`LLONG_MIN` is accepted.** `-9223372036854775808` is a valid `long long`,
   but both libraries historically accumulated a *positive* magnitude that
   overflows `LLONG_MAX` and so flagged it as out of range. yatl now accumulates
   the magnitude in `unsigned long long` and accepts the whole two's-complement
   range, delivering `LLONG_MIN` to `yatl_integer`. yajl reports it as overflow.

2. **An integer beyond `long long` widens to a double** instead of aborting,
   *when* a `yatl_double` callback is present and no `yatl_error` hook is
   installed. The value is delivered (lossily) via `yatl_double`. yajl has no
   such fallback: without `yajl_number` it fails the parse.

The `yatl_error` callback itself is a yatl addition with no yajl equivalent: when
installed it receives the verbatim bytes and `ERANGE` for any out-of-range
number, so a client can accept and handle such numbers without the parse
aborting. An explicitly installed `yatl_error` hook takes precedence over the
double-widening fallback (an explicit range handler is never silently
preempted).

### Outcome matrix

Callback set is abbreviated by which of `yatl_number` (N), `yatl_integer` (I),
`yatl_double` (D), `yatl_error` (E) are installed.

| input | callbacks | yajl (JSON equivalent) | yatl |
|---|---|---|---|
| `-9223372036854775808` | I | overflow → parse error | `yatl_integer(LLONG_MIN)` |
| `9223372036854775807`  | I | `integer(LLONG_MAX)` | `yatl_integer(LLONG_MAX)` |
| `10000000000000000000` | I + D | overflow → parse error | widen → `yatl_double(1e19)` |
| `10000000000000000000` | I only | overflow → parse error | parse error |
| `10000000000000000000` | N | verbatim | verbatim |
| `10000000000000000000` | I + E | overflow → parse error \* | `yatl_error(bytes, ERANGE)` |
| `1e999` (→ ±inf)       | D | overflow → parse error | parse error |
| `1e999`                | N | verbatim | verbatim |

\* yajl has no `yajl_error` callback, so the `E` channel does not exist there;
the effective set is just `I`, which overflows to a parse error.

In short: yatl accepts a strict superset of yajl's numeric input. It never
rejects a number yajl would accept, it correctly accepts `LLONG_MIN`, and it
turns "integer too large for `long long`" from an unconditional failure into a
recoverable event whenever the callback set provides a channel for it.
