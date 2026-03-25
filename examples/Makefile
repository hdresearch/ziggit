# Makefile for Ziggit C API examples
# Demonstrates how to link against libziggit for Bun integration

ZIGGIT_LIB = ../zig-out/lib
ZIGGIT_INCLUDE = ../zig-out/include

CC = gcc
CFLAGS = -Wall -Wextra -std=c99 -I$(ZIGGIT_INCLUDE)
LDFLAGS = -L$(ZIGGIT_LIB) -lziggit -lc

all: c_integration_example

c_integration_example: c_integration_example.c
	@echo "Building C integration example..."
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)
	@echo "Built successfully! Run with: ./c_integration_example"

test: c_integration_example
	@echo "Running C integration example..."
	@./c_integration_example

clean:
	rm -f c_integration_example

install-deps:
	@echo "Ensuring ziggit library is built..."
	cd .. && zig build lib

.PHONY: all test clean install-deps

# Usage examples for Bun developers:
#
# 1. Build the library:
#    make install-deps
#
# 2. Build the example:
#    make
#    
# 3. Run the example:
#    make test
#    # or directly: ./c_integration_example
#
# 4. For Bun integration, link similarly:
#    gcc -I../ziggit/zig-out/include -L../ziggit/zig-out/lib -lziggit your_bun_files.c