/*
 * Copyright (c) 2026 Liquidaty. MIT License.
 *
 * yatl - command-line demo of the TOON SAX parser. Reads TOON from a file
 * argument (or stdin) and prints the event stream, one event per line. This
 * mirrors yajl's example driver and doubles as a smoke test.
 *
 *   yatl [FILE]
 */
#include <yatl/yatl_parse.h>
#include <yatl/yatl_version.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int depth = 0;
static void indent(void) { int i; for (i = 0; i < depth; i++) fputs("  ", stdout); }

static int cb_null(void *c)  { (void)c; indent(); puts("null"); return 1; }
static int cb_bool(void *c, int b) { (void)c; indent(); printf("bool: %s\n", b ? "true" : "false"); return 1; }
static int cb_int(void *c, long long v) { (void)c; indent(); printf("integer: %lld\n", v); return 1; }
static int cb_double(void *c, double v) { (void)c; indent(); printf("double: %g\n", v); return 1; }
static int cb_string(void *c, const unsigned char *s, size_t n) {
    (void)c; indent(); printf("string: \"%.*s\"\n", (int)n, s); return 1;
}
static int cb_map_key(void *c, const unsigned char *s, size_t n) {
    (void)c; indent(); printf("key: \"%.*s\"\n", (int)n, s); return 1;
}
static int cb_start_map(void *c)   { (void)c; indent(); puts("{"); depth++; return 1; }
static int cb_end_map(void *c)     { (void)c; depth--; indent(); puts("}"); return 1; }
static int cb_start_array(void *c) { (void)c; indent(); puts("["); depth++; return 1; }
static int cb_end_array(void *c)   { (void)c; depth--; indent(); puts("]"); return 1; }

static const yatl_callbacks callbacks = {
    cb_null, cb_bool, cb_int, cb_double, NULL /* number */, cb_string,
    cb_start_map, cb_map_key, cb_end_map, cb_start_array, cb_end_array,
    NULL /* error */
};

static void usage(FILE *out) {
    fputs(
        "Usage: yatl [FILE]\n"
        "\n"
        "Parse TOON (Token-Oriented Object Notation) from FILE -- or from standard\n"
        "input if FILE is omitted or \"-\" -- and print the event stream, one event\n"
        "per line, indented by container depth.\n"
        "\n"
        "Options:\n"
        "  -h, --help     show this help and exit\n"
        "      --version  print the yatl version and exit\n"
        "\n"
        "Exit status: 0 valid parse, 1 parse error, 2 usage or I/O error.\n"
        "Example:  echo 'port: 8080' | yatl\n",
        out);
}

int main(int argc, char **argv) {
    FILE *in = stdin;
    yatl_handle h;
    yatl_status st;
    unsigned char buf[65536];
    size_t rd;

    if (argc > 1) {
        const char *arg = argv[1];
        if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
            usage(stdout);
            return 0;
        }
        if (strcmp(arg, "--version") == 0) {
            printf("yatl %d.%d.%d\n", yatl_version() / 10000,
                   (yatl_version() / 100) % 100, yatl_version() % 100);
            return 0;
        }
        if (arg[0] == '-' && strcmp(arg, "-") != 0) {   /* "-" means stdin */
            fprintf(stderr, "yatl: unknown option '%s'\n", arg);
            usage(stderr);
            return 2;
        }
        if (strcmp(arg, "-") != 0) {
            in = fopen(arg, "rb");
            if (!in) { fprintf(stderr, "yatl: cannot open %s\n", arg); return 2; }
        }
    }

    h = yatl_alloc(&callbacks, NULL, NULL);
    if (!h) { fprintf(stderr, "yatl: out of memory\n"); if (in != stdin) fclose(in); return 2; }

    st = yatl_status_ok;
    while ((rd = fread(buf, 1, sizeof buf, in)) > 0) {
        st = yatl_parse(h, buf, rd);
        if (st != yatl_status_ok)
            break;
    }
    if (st == yatl_status_ok)
        st = yatl_complete_parse(h);

    if (st != yatl_status_ok) {
        unsigned char *err = yatl_get_error(h, 0, NULL, 0);
        fprintf(stderr, "yatl: %s", err ? (char *)err : "error\n");
        yatl_free_error(h, err);
    }
    yatl_free(h);
    if (in != stdin) fclose(in);
    return st == yatl_status_ok ? 0 : 1;
}
