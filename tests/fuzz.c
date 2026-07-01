/* yatl - fuzz harness.
 *
 * One libFuzzer entry point drives the TOON SAX parser over arbitrary bytes.
 * The main oracle is chunk-independence: because the parser is line-oriented,
 * feeding an input whole and feeding it in arbitrary chunks MUST yield the
 * identical event stream and final status. A divergence is a chunk-boundary
 * state bug -- exactly the silent class this exists to pin. Event streams are
 * compared by a bounded rolling hash, so peak memory is independent of input.
 *
 * Build (see the Makefile): `make fuzz` (libFuzzer/clang), or `make
 * fuzz-standalone` for a portable driver that replays argv files / stdin once
 * each through the same entry point (smoke-buildable with any compiler).
 */
#include <yatl/yatl_parse.h>

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------- event digest (FNV-1a) */

typedef struct { uint64_t h; } digest;

static void mix(digest *d, const void *p, size_t n) {
    const unsigned char *b = (const unsigned char *)p;
    size_t i;
    for (i = 0; i < n; i++) {
        d->h ^= b[i];
        d->h *= 1099511628211ULL;
    }
}
static void tag(digest *d, char t) { mix(d, &t, 1); }

static int d_null(void *c)               { tag((digest *)c, 'n'); return 1; }
static int d_bool(void *c, int b)        { digest *d = c; tag(d, 'b'); mix(d, &b, sizeof b); return 1; }
static int d_int(void *c, long long v)   { digest *d = c; tag(d, 'i'); mix(d, &v, sizeof v); return 1; }
static int d_dbl(void *c, double v)      { digest *d = c; tag(d, 'd'); mix(d, &v, sizeof v); return 1; }
static int d_str(void *c, const unsigned char *s, size_t n) { digest *d = c; tag(d, 's'); mix(d, &n, sizeof n); mix(d, s, n); return 1; }
static int d_key(void *c, const unsigned char *s, size_t n) { digest *d = c; tag(d, 'k'); mix(d, &n, sizeof n); mix(d, s, n); return 1; }
static int d_smap(void *c)  { tag((digest *)c, 'M'); return 1; }
static int d_emap(void *c)  { tag((digest *)c, 'm'); return 1; }
static int d_sarr(void *c)  { tag((digest *)c, 'A'); return 1; }
static int d_earr(void *c)  { tag((digest *)c, 'a'); return 1; }

static const yatl_callbacks CB = {
    d_null, d_bool, d_int, d_dbl, NULL, d_str,
    d_smap, d_key, d_emap, d_sarr, d_earr, NULL
};

/* Parse [data,len) and fold the event stream into *out. `chunk_seed` of 0 feeds
 * the whole buffer at once; otherwise chunks are 1..17 bytes, sized from the
 * input itself so different inputs probe different boundaries. Returns the final
 * status. A poisoned (errored) handle makes post-error feeds no-ops, so feeding
 * all bytes regardless of an early error keeps whole and chunked comparable. */
static yatl_status run(const uint8_t *data, size_t len, int chunked,
                       unsigned int flags, digest *out) {
    yatl_handle h = yatl_alloc(&CB, NULL, out);
    yatl_status st;
    size_t off = 0;
    out->h = 14695981039346656037ULL;    /* FNV-1a offset basis */
    if (!h) { out->h = 0; return yatl_status_error; }
    if (flags) {
        if (flags & yatl_dont_validate_strings)  yatl_config(h, yatl_dont_validate_strings, 1);
        if (flags & yatl_allow_trailing_garbage) yatl_config(h, yatl_allow_trailing_garbage, 1);
        if (flags & yatl_lenient_scalars)        yatl_config(h, yatl_lenient_scalars, 1);
        if (flags & yatl_dont_validate_length)   yatl_config(h, yatl_dont_validate_length, 1);
    }
    while (off < len) {
        size_t n = len - off;
        if (chunked) {
            n = (size_t)(data[off] % 17) + 1;
            if (n > len - off) n = len - off;
        }
        yatl_parse(h, data + off, n);
        off += n;
    }
    st = yatl_complete_parse(h);
    yatl_free(h);
    return st;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t len) {
    digest whole, chunked;
    yatl_status sw, sc;

    /* primary oracle: whole-feed must equal chunked-feed, events and status */
    sw = run(data, len, 0, 0, &whole);
    sc = run(data, len, 1, 0, &chunked);
    if (sw != sc || whole.h != chunked.h)
        abort();                          /* chunk-boundary divergence */

    /* branch coverage for the option paths (lenient / validation-off); no
     * differential, just exercise those branches for crashes. */
    {
        digest d;
        run(data, len, 0, yatl_lenient_scalars | yatl_dont_validate_strings |
                          yatl_dont_validate_length | yatl_allow_trailing_garbage, &d);
        (void)d;
    }
    return 0;
}

#ifdef YATL_FUZZ_STANDALONE
/* Minimal libFuzzer-compatible standalone driver: run each argv file (or stdin
 * if none) through LLVMFuzzerTestOneInput exactly once. Lets the harness be
 * built and exercised with any compiler, no libFuzzer required. */
#include <stdio.h>

static int run_stream(FILE *f) {
    size_t cap = 4096, len = 0;
    unsigned char *buf = (unsigned char *)malloc(cap);
    if (!buf)
        return -1;
    for (;;) {
        size_t got;
        if (len == cap) {
            unsigned char *nb = (unsigned char *)realloc(buf, cap * 2);
            if (!nb) { free(buf); return -1; }
            buf = nb;
            cap *= 2;
        }
        got = fread(buf + len, 1, cap - len, f);
        len += got;
        if (got == 0)
            break;
    }
    LLVMFuzzerTestOneInput(buf, len);
    free(buf);
    return 0;
}

int main(int argc, char **argv) {
    int i;
    if (argc < 2)
        return run_stream(stdin) == 0 ? 0 : 1;
    for (i = 1; i < argc; i++) {
        FILE *f = fopen(argv[i], "rb");
        if (!f) { fprintf(stderr, "fuzz: cannot open '%s'\n", argv[i]); return 1; }
        if (run_stream(f) != 0) { fclose(f); return 1; }
        fclose(f);
    }
    return 0;
}
#endif /* YATL_FUZZ_STANDALONE */
