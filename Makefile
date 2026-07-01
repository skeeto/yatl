# yatl - build libyatl (the TOON SAX parser) and the yatl CLI demo.
#
# Quick start (run `make help` for the full list):
#   make build         build the library + CLI into a per-target build dir
#   make test          build and run the test suite
#   make install       copy the built artifacts under $(PREFIX)
#   make clean         remove all build output
#
# Artifacts never land in the source tree. They go under a directory keyed by
# the target triple, the compiler, and the build variant:
#
#   $(BUILDROOT)/<target-triple>/<cc>-<version>/<variant>/
#
# so release/debug/asan builds and different toolchains (native, mingw64,
# emscripten, cross gcc) coexist without clobbering one another. `make install`
# is the only step that writes outside the build tree.
#
# Flags: ASAN=1 (AddressSanitizer + UBSan), DEBUG=1 (debug build). Environment
# CC/AR/RANLIB/CFLAGS/LDFLAGS and CONFIGFILE are honoured.

CONFIGFILE ?= config.mk
-include $(CONFIGFILE)

CC      ?= cc
AR      ?= ar
RANLIB  ?= ranlib
PREFIX  ?= /usr/local
EXE_EXT ?=

# --------------------------------------------- target / compiler / variant id
# Derived from the compiler's own configuration so it is correct when cross-
# compiling: -dumpmachine prints the *target* triple, -dumpversion the version.
TARGET_TRIPLE := $(shell $(CC) -dumpmachine 2>/dev/null)
ifeq ($(TARGET_TRIPLE),)
  TARGET_TRIPLE := unknown-target
endif
CC_NAME := $(notdir $(CC))
CC_VERSION := $(shell $(CC) -dumpversion 2>/dev/null)
ifeq ($(CC_VERSION),)
  CC_VERSION := 0
endif

ifeq ($(ASAN),1)
  VARIANT := asan
else ifeq ($(DEBUG),1)
  VARIANT := debug
else ifeq ($(DEBUG_DEFAULT),1)
  VARIANT := debug
else
  VARIANT := release
endif

BUILDROOT ?= build
BUILDID   := $(TARGET_TRIPLE)/$(CC_NAME)-$(CC_VERSION)/$(VARIANT)
BUILDDIR  := $(BUILDROOT)/$(BUILDID)
OBJDIR    := $(BUILDDIR)/obj

# ------------------------------------------------ shared-library conventions
UNAME_S := $(shell uname -s 2>/dev/null)

# Library version (single source of truth: the public header).
VERSION := $(shell sed -n 's/.*YATL_VERSION "\([^"]*\)".*/\1/p' include/yatl/yatl_version.h | head -1)
VERSION := $(if $(VERSION),$(VERSION),0.0.0)
SOVERSION := $(firstword $(subst ., ,$(VERSION)))

# Default link flags when ./configure did not provide them (standalone make).
ifeq ($(SHLIB_EXT),)
  ifeq ($(UNAME_S),Darwin)
    SHLIB_EXT := dylib
    SHLIB_LDFLAGS := -dynamiclib \
        -install_name $(PREFIX)/lib/libyatl.$(SOVERSION).dylib \
        -compatibility_version $(SOVERSION) -current_version $(VERSION)
  else
    SHLIB_EXT := so
    SHLIB_LDFLAGS := -shared -Wl,-soname,libyatl.so.$(SOVERSION)
  endif
endif

ENABLE_SHARED ?= 1
ifneq ($(STATIC_BUILD),)
  ifneq ($(STATIC_BUILD),0)
    ENABLE_SHARED := 0
  endif
endif

# Restrict the shared object's exports to the public API: symbol glob on macOS,
# version script on ELF, nothing on Windows.
ifeq ($(SHLIB_EXT),dylib)
  SHLIB_EXPORT := -Wl,-exported_symbol,_yatl_*
else ifeq ($(SHLIB_EXT),so)
  SHLIB_EXPORT := -Wl,--version-script=yatl.map
else
  SHLIB_EXPORT :=
endif

# ------------------------------------------------------------------- flags
WARN := -Wall -Wextra
BASE_CFLAGS := -std=c11 $(WARN) -Iinclude -Isrc -fPIC
OPT_CFLAGS := -O2

ifeq ($(DEBUG),1)
  OPT_CFLAGS := -O0 -g -DDEBUG
endif
ifeq ($(DEBUG_DEFAULT),1)
  OPT_CFLAGS := -O0 -g -DDEBUG
endif

SAN_CFLAGS :=
SAN_LDFLAGS :=
ifeq ($(ASAN),1)
  SAN_CFLAGS := -fsanitize=address,undefined -fno-omit-frame-pointer -g
  SAN_LDFLAGS := -fsanitize=address,undefined
  OPT_CFLAGS := -O1
endif

ALL_CFLAGS := $(BASE_CFLAGS) $(OPT_CFLAGS) $(SAN_CFLAGS) $(EXTRA_CFLAGS) $(CFLAGS)
ALL_LDFLAGS := $(SAN_LDFLAGS) $(EXTRA_LDFLAGS) $(LDFLAGS)

# Applied only to the library's own translation units: hide every symbol not
# annotated YATL_API from the shared object's dynamic table.
LIB_CFLAGS := -fvisibility=hidden

# ----------------------------------------------------- sources / artifacts
LIB_SRCS := src/yatl.c src/yatl_parser.c src/yatl_buf.c src/yatl_encode.c \
            src/yatl_alloc.c src/yatl_version.c
LIB_OBJS := $(LIB_SRCS:src/%.c=$(OBJDIR)/%.o)

STATIC_LIB := $(BUILDDIR)/libyatl.a

ifeq ($(SHLIB_EXT),dll)
  SHARED_LIB_REAL := $(BUILDDIR)/libyatl.dll
  SHARED_LIB := $(SHARED_LIB_REAL)
  SHLIB_NAMES := libyatl.dll
else ifeq ($(SHLIB_EXT),dylib)
  SHARED_LIB_REAL := $(BUILDDIR)/libyatl.$(SOVERSION).dylib
  SHARED_LIB := $(BUILDDIR)/libyatl.dylib
  SHLIB_NAMES := libyatl.$(SOVERSION).dylib libyatl.dylib
else
  SHARED_LIB_REAL := $(BUILDDIR)/libyatl.so.$(VERSION)
  SHARED_LIB := $(BUILDDIR)/libyatl.so
  SHLIB_NAMES := libyatl.so.$(VERSION) libyatl.so.$(SOVERSION) libyatl.so
endif

APP := $(BUILDDIR)/yatl$(EXE_EXT)
TESTBIN := $(BUILDDIR)/test$(EXE_EXT)

LIBS := $(STATIC_LIB)
ifeq ($(ENABLE_SHARED),1)
  LIBS += $(SHARED_LIB)
endif

.PHONY: help all build lib app test check test-leaks strict fuzz fuzz-standalone \
        install install-lib install-app uninstall uninstall-lib uninstall-app \
        clean distclean print-builddir
.DEFAULT_GOAL := help

help:
	@echo 'yatl - available make targets:'
	@echo ''
	@echo '  help          show this list (default target)'
	@echo '  build         build libyatl (static + shared) and the yatl CLI'
	@echo '  lib           build the libraries only'
	@echo '  app           build the yatl CLI only'
	@echo '  test          build and run the unit test suite'
	@echo '  check         alias for test'
	@echo '  test-leaks    run the test suite under a leak checker'
	@echo '  strict        strict-warnings compile of the library TUs (-Werror +)'
	@echo '  fuzz          build the libFuzzer target (needs an LLVM clang)'
	@echo '  fuzz-standalone  build the portable replay driver (any toolchain)'
	@echo '  docker-fuzz   run libFuzzer in a Linux container (needs only Docker;'
	@echo '                works on hosts that cannot link libFuzzer natively)'
	@echo '  install       install lib + CLI under PREFIX (default /usr/local)'
	@echo '  install-lib   install only the library, headers and .pc'
	@echo '  install-app   install only the CLI'
	@echo '  uninstall     remove everything install put under PREFIX'
	@echo '  clean         remove the entire build tree (all targets/variants)'
	@echo '  distclean     clean + remove ./configure output'
	@echo '  print-builddir  print the resolved build directory for this config'
	@echo ''
	@echo 'Flags:  ASAN=1 (AddressSanitizer+UBSan)   DEBUG=1 (debug build)'
	@echo 'Vars:   CC, AR, RANLIB, CFLAGS, LDFLAGS, PREFIX, BUILDROOT'
	@echo ''
	@echo 'This config builds into: $(BUILDDIR)'

all: build
build: $(LIBS) $(APP)
lib: $(LIBS)
app: $(APP)

$(OBJDIR):
	mkdir -p $(OBJDIR)

$(OBJDIR)/%.o: src/%.c | $(OBJDIR)
	$(CC) $(ALL_CFLAGS) $(LIB_CFLAGS) -c $< -o $@

$(OBJDIR)/main.o: app/main.c | $(OBJDIR)
	$(CC) $(ALL_CFLAGS) -c $< -o $@

$(OBJDIR)/test.o: tests/test.c | $(OBJDIR)
	$(CC) $(ALL_CFLAGS) -c $< -o $@

$(STATIC_LIB): $(LIB_OBJS)
	$(AR) rcs $@ $(LIB_OBJS)
	$(RANLIB) $@ 2>/dev/null || true

$(SHARED_LIB_REAL): $(LIB_OBJS)
	$(CC) $(ALL_LDFLAGS) $(SHLIB_LDFLAGS) $(SHLIB_EXPORT) -o $@ $(LIB_OBJS)

# Dev/linker symlink -> real versioned object (ELF/macOS). On Windows
# SHARED_LIB == SHARED_LIB_REAL, so this rule is omitted.
ifneq ($(SHARED_LIB),$(SHARED_LIB_REAL))
$(SHARED_LIB): $(SHARED_LIB_REAL)
	ln -sf $(notdir $(SHARED_LIB_REAL)) $@
endif

$(APP): $(OBJDIR)/main.o $(STATIC_LIB)
	$(CC) $(ALL_LDFLAGS) -o $@ $(OBJDIR)/main.o $(STATIC_LIB)

$(TESTBIN): $(OBJDIR)/test.o $(STATIC_LIB)
	$(CC) $(ALL_LDFLAGS) -o $@ $(OBJDIR)/test.o $(STATIC_LIB)

test check: $(TESTBIN)
	$(TESTBIN)

# Strict-warnings lane (not part of the default build): syntax-check the
# library's translation units under an explicit standard with extra diagnostics
# promoted to errors. Run across compilers, e.g. `make strict CC=gcc`.
STRICT_WARN := -std=c11 -pedantic -Wall -Wextra -Werror \
               -Wconversion -Wshadow -Wstrict-prototypes -Wvla
strict:
	@for f in $(LIB_SRCS); do \
	  echo "  STRICT $$f"; \
	  $(CC) $(STRICT_WARN) -Iinclude -Isrc -fsyntax-only $$f || exit 1; \
	done
	@echo "strict: clean ($(CC))"

# Leak check: macOS 'leaks' when available, else run the suite directly
# (sanitizer/Valgrind cover leaks on other platforms).
test-leaks: $(TESTBIN)
	@if command -v leaks >/dev/null 2>&1; then \
	  echo "leaks: $(TESTBIN)"; \
	  MallocStackLogging=1 leaks --atExit -- $(TESTBIN); \
	else \
	  echo "leaks(1) not found; running suite directly"; \
	  $(TESTBIN); \
	fi

# ------------------------------------------------------------------- fuzzing
# libFuzzer build. Compiles the library sources together with the harness in one
# clang invocation so coverage/sanitizer instrumentation reaches the parser.
# Needs an LLVM clang with libFuzzer (Apple clang lacks it -- use the Linux CI
# or a real clang). Override the compiler with FUZZ_CC=...
FUZZ_CC ?= clang
FUZZBIN := $(BUILDDIR)/fuzz$(EXE_EXT)
FUZZSTANDALONE := $(BUILDDIR)/fuzz-standalone$(EXE_EXT)

$(FUZZBIN): $(LIB_SRCS) tests/fuzz.c | $(OBJDIR)
	$(FUZZ_CC) $(BASE_CFLAGS) -g -O1 -fno-omit-frame-pointer \
	  -fsanitize=fuzzer,address,undefined -o $@ $(LIB_SRCS) tests/fuzz.c

fuzz: $(FUZZBIN)
	@echo "built $(FUZZBIN)"
	@echo "run e.g.: $(FUZZBIN) -max_total_time=60 tests/corpus"

# Portable replay driver: runs each input file (or stdin) through the harness
# once. Buildable/runnable with any toolchain (no libFuzzer) -- used for CI
# smoke coverage and for replaying a crash file found by `make fuzz`.
$(OBJDIR)/fuzz-standalone.o: tests/fuzz.c | $(OBJDIR)
	$(CC) $(ALL_CFLAGS) -DYATL_FUZZ_STANDALONE -c $< -o $@

$(FUZZSTANDALONE): $(OBJDIR)/fuzz-standalone.o $(STATIC_LIB)
	$(CC) $(ALL_LDFLAGS) -o $@ $(OBJDIR)/fuzz-standalone.o $(STATIC_LIB)

fuzz-standalone: $(FUZZSTANDALONE)
	@echo "built $(FUZZSTANDALONE)"

# Run the libFuzzer harness inside a Linux clang container, so fuzzing works on
# hosts that can't link libFuzzer natively (e.g. Apple-Silicon macOS). Needs
# only Docker -- no external repo, yq, or compose. The repo is bind-mounted;
# `make fuzz` runs inside the container, so build output and crash artifacts land
# under build/ on the host (a per-target dir, so Linux objects never collide with
# a native build), and the host's config.mk is never touched. New corpus finds
# go to build/fuzz/corpus and crashes to build/fuzz/artifacts (both gitignored);
# seeds are read from tests/corpus. Override the session length with
# FUZZ_SECONDS=N, the image name with DOCKER_FUZZ_IMAGE=...
DOCKER_FUZZ_IMAGE ?= yatl-fuzz
FUZZ_SECONDS ?= 60
.PHONY: docker-fuzz
docker-fuzz:
	docker build -t $(DOCKER_FUZZ_IMAGE) -f infra/docker/Dockerfile.fuzz .
	docker run --rm -v "$(CURDIR):/src" -w /src \
	  --user "$$(id -u):$$(id -g)" $(DOCKER_FUZZ_IMAGE) bash -c '\
	    set -e; \
	    mkdir -p build/fuzz/corpus build/fuzz/artifacts; \
	    make fuzz FUZZ_CC=clang; \
	    bin="$$(make print-builddir | tail -1)/fuzz"; \
	    "$$bin" -max_total_time=$(FUZZ_SECONDS) -print_final_stats=1 \
	      -artifact_prefix=build/fuzz/artifacts/ build/fuzz/corpus tests/corpus'

# Runtime symlinks beside the installed shared object.
ifeq ($(SHLIB_EXT),dylib)
  INSTALL_SHLIB_LINKS = cd $(PREFIX)/lib && ln -sf libyatl.$(SOVERSION).dylib libyatl.dylib
else ifeq ($(SHLIB_EXT),so)
  INSTALL_SHLIB_LINKS = cd $(PREFIX)/lib && ln -sf libyatl.so.$(VERSION) libyatl.so.$(SOVERSION) && ln -sf libyatl.so.$(SOVERSION) libyatl.so
else
  INSTALL_SHLIB_LINKS = :
endif

install: install-lib install-app

install-lib: lib
	mkdir -p $(PREFIX)/lib $(PREFIX)/include/yatl $(PREFIX)/lib/pkgconfig
	cp $(STATIC_LIB) $(PREFIX)/lib/
	cp include/yatl/*.h $(PREFIX)/include/yatl/
	[ -f yatl.pc ] && cp yatl.pc $(PREFIX)/lib/pkgconfig/ || true
ifeq ($(ENABLE_SHARED),1)
	cp $(SHARED_LIB_REAL) $(PREFIX)/lib/
	$(INSTALL_SHLIB_LINKS)
endif

install-app: app
	mkdir -p $(PREFIX)/bin
	cp $(APP) $(PREFIX)/bin/

uninstall: uninstall-lib uninstall-app

uninstall-lib:
	rm -f $(PREFIX)/lib/libyatl.a $(PREFIX)/lib/pkgconfig/yatl.pc \
	      $(addprefix $(PREFIX)/lib/,$(SHLIB_NAMES))
	rm -rf $(PREFIX)/include/yatl

uninstall-app:
	rm -f $(PREFIX)/bin/yatl$(EXE_EXT)

print-builddir:
	@echo $(BUILDDIR)

clean:
	rm -rf $(BUILDROOT)

distclean: clean
	rm -f config.mk yatl.pc
