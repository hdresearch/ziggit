# libgit2 test server Makefile
# Uses zig cc as the C compiler and a locally-built static libgit2

# libgit2 paths (built from source with zig cc)
LIBGIT2_SRC   ?= /tmp/libgit2
LIBGIT2_BUILD ?= /tmp/libgit2/build
LIBGIT2_INC    = $(LIBGIT2_SRC)/include
LIBGIT2_LIB    = $(LIBGIT2_BUILD)/libgit2.a

CC      = zig cc -target x86_64-linux-gnu
CFLAGS  = -Wall -Wextra -Wno-missing-field-initializers -O2 -I$(LIBGIT2_INC)
# libgit2 static lib + its bundled dependencies (zlib, pcre, etc.)
LDFLAGS = $(LIBGIT2_LIB) -lpthread

.PHONY: all clean check check-libgit2

all: check-libgit2 server

check-libgit2:
	@if [ ! -f "$(LIBGIT2_LIB)" ]; then \
		echo "ERROR: libgit2 not found at $(LIBGIT2_LIB)"; \
		echo "Build it first: see test/libgit2_server/README or run build_libgit2.sh"; \
		exit 1; \
	fi
	@echo "Found libgit2 at $(LIBGIT2_LIB)"

server: server.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)
	@echo "Built: server"

check: server
	./server /tmp/libgit2_test_repo.git
	@echo ""
	@echo "Server test complete. Repo at /tmp/libgit2_test_repo.git"

clean:
	rm -f server
