# Makefile
CLANG ?= clang
BPFTOOL := bpftool
CC := gcc
AR := ar

ARCH := $(shell uname -m | sed 's/x86_64/x86/' | sed 's/aarch64/arm64/')
UNAME_M := $(shell uname -m)

# Directories
EBPF_PROGRAMS_DIR := ebpf/programs
EBPF_INCLUDE_DIR := ebpf/include
EBPF_SHARED_DIR := ebpf/shared
EBPF_IMPL_DIR := ebpf/impl
SRC_DIR := src
INCLUDE_DIR := include
TEST_DIR := test
GENERATED_DIR := generated
OUTPUT_DIR := output
OUTPUT_EHPROBE_DIR := $(OUTPUT_DIR)/ehprobe
OUTPUT_TEST_DIR := $(OUTPUT_DIR)/test
BUILD_DIR := build

# Create output directories
$(shell mkdir -p $(OUTPUT_EHPROBE_DIR) $(OUTPUT_TEST_DIR) $(BUILD_DIR) $(GENERATED_DIR))

# Compiler flags
CFLAGS := -g -O2 -Wall -D_GNU_SOURCE
INCLUDES := -I/usr/include/bpf -I$(INCLUDE_DIR) -I$(EBPF_SHARED_DIR) -I$(BUILD_DIR) -I$(TEST_DIR) -I$(SRC_DIR)
BPF_INCLUDES := -I$(EBPF_INCLUDE_DIR) -I$(EBPF_SHARED_DIR) -I$(EBPF_IMPL_DIR) -I$(BUILD_DIR)
BPF_CFLAGS := -target bpf -D__TARGET_ARCH_$(ARCH) -g -O2

LIB_CFLAGS := $(CFLAGS) -fPIC

# BPF source files (all handlers)
BPF_SRCS := $(wildcard $(EBPF_PROGRAMS_DIR)/*.bpf.c)

# BPF object files
BPF_OBJS := $(patsubst $(EBPF_PROGRAMS_DIR)/%.bpf.c,$(BUILD_DIR)/%.bpf.o,$(BPF_SRCS))

# Combined BPF object
COMBINED_BPF_OBJ := $(BUILD_DIR)/ehprobe.bpf.o

# Test source files
TEST_SRCS := $(TEST_DIR)/ehprobe_test.c \
             $(TEST_DIR)/event_handlers.c \
             $(TEST_DIR)/allowlist.c \
             $(TEST_DIR)/container_tracker.c \
             $(TEST_DIR)/utils.c

TEST_OBJS := $(patsubst $(TEST_DIR)/%.c,$(BUILD_DIR)/%.o,$(TEST_SRCS))

# Library source files
LIB_SRCS := $(SRC_DIR)/ehprobe_lib.c \
            $(SRC_DIR)/ehprobe_log.c \
            $(SRC_DIR)/ehprobe_bpf.c \
            $(SRC_DIR)/ehprobe_event.c \
            $(SRC_DIR)/ehprobe_container.c \
            $(SRC_DIR)/ehprobe_allowlist.c \
            $(SRC_DIR)/ehprobe_file_path_filter.c

LIB_OBJS := $(patsubst $(SRC_DIR)/%.c,$(BUILD_DIR)/%.o,$(LIB_SRCS))

HEADER_FILE := $(INCLUDE_DIR)/ehprobe.h

# Output files
SKEL_HEADER := $(BUILD_DIR)/ehprobe.skel.h
STATIC_LIB := $(OUTPUT_EHPROBE_DIR)/ehprobe.a
TEST_BIN := $(OUTPUT_TEST_DIR)/ehprobe_test

# Architecture-specific vmlinux.h
# Cached in generated/ with arch suffix, symlinked/copied to build dir
VMLINUX_H_ARCH := $(GENERATED_DIR)/vmlinux_$(UNAME_M).h
VMLINUX_H := $(BUILD_DIR)/vmlinux.h

# Header dependencies
BPF_HEADERS := $(EBPF_INCLUDE_DIR)/ehprobe_common.h \
               $(EBPF_INCLUDE_DIR)/dynamic_events.h \
               $(EBPF_INCLUDE_DIR)/helpers.h \
               $(EBPF_SHARED_DIR)/events.h \
               $(VMLINUX_H)

LIB_HEADERS := $(INCLUDE_DIR)/ehprobe.h \
               $(INCLUDE_DIR)/ehprobe_internal.h \
               $(EBPF_SHARED_DIR)/events.h \
               $(EBPF_SHARED_DIR)/data.h

TEST_HEADERS := $(TEST_DIR)/utils.h \
                $(TEST_DIR)/event_handlers.h \
                $(TEST_DIR)/allowlist.h \
                $(TEST_DIR)/container_tracker.h

# Default target
all: lint-license $(STATIC_LIB) $(TEST_BIN)
	@echo "Build complete!"
	@echo "  Architecture: $(UNAME_M) ($(ARCH))"
	@echo "  Library: $(STATIC_LIB)"
	@echo "  Header:  $(OUTPUT_EHPROBE_DIR)/ehprobe.h"
	@echo "  Test:    $(TEST_BIN)"

# Generate architecture-specific vmlinux.h if it doesn't exist
$(VMLINUX_H_ARCH):
	@echo "Generating vmlinux.h for $(UNAME_M) (first time only)..."
	@echo "Running: bpftool btf dump file /sys/kernel/btf/vmlinux format c > $(VMLINUX_H_ARCH)"
	@mkdir -p $(GENERATED_DIR)
	$(BPFTOOL) btf dump file /sys/kernel/btf/vmlinux format c > $(VMLINUX_H_ARCH)
	@echo "vmlinux.h generated at $(VMLINUX_H_ARCH)"

# Create symlink/copy to build directory for current architecture
$(VMLINUX_H): $(VMLINUX_H_ARCH)
	@echo "Using vmlinux.h for $(UNAME_M)..."
	@mkdir -p $(BUILD_DIR)
	@rm -f $(VMLINUX_H)
	@ln -sf $(abspath $(VMLINUX_H_ARCH)) $(VMLINUX_H) || cp $(VMLINUX_H_ARCH) $(VMLINUX_H)

# Build individual BPF objects
$(BUILD_DIR)/%.bpf.o: $(EBPF_PROGRAMS_DIR)/%.bpf.c $(BPF_HEADERS)
	@echo "Compiling BPF program: $< (arch: $(ARCH))"
	$(CLANG) $(BPF_CFLAGS) $(BPF_INCLUDES) -c $< -o $@

# Combine all BPF objects into one
$(COMBINED_BPF_OBJ): $(BPF_OBJS)
	@echo "Linking BPF objects..."
	$(BPFTOOL) gen object $@ $(BPF_OBJS)

# Generate skeleton header
$(SKEL_HEADER): $(COMBINED_BPF_OBJ)
	@echo "Generating BPF skeleton..."
	$(BPFTOOL) gen skeleton $(COMBINED_BPF_OBJ) > $(SKEL_HEADER)

# Build library objects
$(BUILD_DIR)/ehprobe_lib.o: $(SRC_DIR)/ehprobe_lib.c $(SKEL_HEADER) $(LIB_HEADERS)
	@echo "Compiling: $<"
	$(CC) $(LIB_CFLAGS) $(INCLUDES) -c $< -o $@

$(BUILD_DIR)/ehprobe_log.o: $(SRC_DIR)/ehprobe_log.c $(SKEL_HEADER) $(LIB_HEADERS)
	@echo "Compiling: $<"
	$(CC) $(LIB_CFLAGS) $(INCLUDES) -c $< -o $@

$(BUILD_DIR)/ehprobe_bpf.o: $(SRC_DIR)/ehprobe_bpf.c $(SKEL_HEADER) $(LIB_HEADERS)
	@echo "Compiling: $<"
	$(CC) $(LIB_CFLAGS) $(INCLUDES) -c $< -o $@

$(BUILD_DIR)/ehprobe_event.o: $(SRC_DIR)/ehprobe_event.c $(SKEL_HEADER) $(LIB_HEADERS)
	@echo "Compiling: $<"
	$(CC) $(LIB_CFLAGS) $(INCLUDES) -c $< -o $@

$(BUILD_DIR)/ehprobe_container.o: $(SRC_DIR)/ehprobe_container.c $(SKEL_HEADER) $(LIB_HEADERS)
	@echo "Compiling: $<"
	$(CC) $(LIB_CFLAGS) $(INCLUDES) -c $< -o $@

$(BUILD_DIR)/ehprobe_allowlist.o: $(SRC_DIR)/ehprobe_allowlist.c $(SKEL_HEADER) $(LIB_HEADERS)
	@echo "Compiling: $<"
	$(CC) $(LIB_CFLAGS) $(INCLUDES) -c $< -o $@

$(BUILD_DIR)/ehprobe_file_path_filter.o: $(SRC_DIR)/ehprobe_file_path_filter.c $(SKEL_HEADER) $(LIB_HEADERS)
	@echo "Compiling: $<"
	$(CC) $(LIB_CFLAGS) $(INCLUDES) -c $< -o $@

# Build static library and copy header
$(STATIC_LIB): $(LIB_OBJS)
	@echo "Creating static library..."
	$(AR) rcs $(STATIC_LIB) $(LIB_OBJS)
	@echo "Copying library header..."
	cp $(HEADER_FILE) $(OUTPUT_EHPROBE_DIR)/

# Build test objects
$(BUILD_DIR)/%.o: $(TEST_DIR)/%.c $(TEST_HEADERS) $(STATIC_LIB)
	@echo "Compiling test module: $<"
	$(CC) $(CFLAGS) $(INCLUDES) -c $< -o $@

# Build test executable
$(TEST_BIN): $(TEST_OBJS) $(STATIC_LIB)
	@echo "Building test executable..."
	$(CC) $(CFLAGS) $(TEST_OBJS) $(STATIC_LIB) -lbpf -lcrypto -o $(TEST_BIN)

# Clean build artifacts (keeps arch-specific vmlinux.h files)
clean:
	@echo "Cleaning build artifacts..."
	rm -rf $(BUILD_DIR)
	rm -rf $(OUTPUT_DIR)
	@echo "Clean complete (architecture-specific vmlinux.h files preserved)"

# Deep clean - removes everything including all vmlinux.h variants
distclean: clean
	@echo "Removing all vmlinux.h variants..."
	rm -rf $(GENERATED_DIR)
	@echo "Deep clean complete"

# Force regeneration of vmlinux.h for current architecture
vmlinux:
	@echo "Regenerating vmlinux.h for $(UNAME_M)..."
	@echo "Running: bpftool btf dump file /sys/kernel/btf/vmlinux format c > $(VMLINUX_H_ARCH)"
	rm -f $(VMLINUX_H_ARCH) $(VMLINUX_H)
	mkdir -p $(GENERATED_DIR) $(BUILD_DIR)
	$(BPFTOOL) btf dump file /sys/kernel/btf/vmlinux format c > $(VMLINUX_H_ARCH)
	ln -sf $(abspath $(VMLINUX_H_ARCH)) $(VMLINUX_H) || cp $(VMLINUX_H_ARCH) $(VMLINUX_H)
	@echo "vmlinux.h regenerated at $(VMLINUX_H_ARCH)"

# Show current architecture info
info:
	@echo "Build Information:"
	@echo "  Machine:     $(UNAME_M)"
	@echo "  BPF Arch:    $(ARCH)"
	@echo "  vmlinux.h:   $(VMLINUX_H_ARCH)"
	@echo ""
	@echo "Library source files:"
	@for src in $(LIB_SRCS); do echo "  $$src"; done
	@echo ""
	@echo "Available vmlinux.h files:"
	@ls -la $(GENERATED_DIR)/vmlinux_*.h 2>/dev/null || echo "  (none generated yet)"

# Show help
help:
	@echo "Available targets:"
	@echo "  all          - Build library and test executable (default)"
	@echo "  clean        - Remove build artifacts (preserves vmlinux.h files)"
	@echo "  distclean    - Remove all artifacts including all vmlinux.h variants"
	@echo "  vmlinux      - Force regeneration of vmlinux.h for current architecture"
	@echo "  verify-ebpf  - Load each BPF .o through the kernel verifier (fast sanity check)"
	@echo "  lint-license - Check SPDX license headers on all BPF source files"
	@echo "  musl-lib     - Cross-compile libehprobe.a (override CC, MUSL_OUTPUT_DIR, EXTRA_INCLUDES)"
	@echo "  info         - Show build information and available vmlinux.h files"
	@echo "  help         - Show this help message"
	@echo ""
	@echo "Current architecture: $(UNAME_M) (BPF target: $(ARCH))"

# Verify all compiled BPF programs pass the kernel verifier.
# Loads each .bpf.o into the kernel via bpftool and immediately removes it.
# Faster than running the full integration test suite.
verify-ebpf: $(BPF_OBJS)
	@echo "Verifying BPF programs against the kernel verifier..."
	@pass=0; fail=0; \
	for obj in $(BPF_OBJS); do \
		pin=/sys/fs/bpf/ehprobe_verify_$$(basename $$obj .bpf.o); \
		if $(BPFTOOL) prog load $$obj $$pin 2>/dev/null; then \
			echo "  PASS: $$obj"; \
			rm -f $$pin; \
			pass=$$((pass+1)); \
		else \
			echo "  FAIL: $$obj"; \
			$(BPFTOOL) prog load $$obj $$pin 2>&1 | grep -E 'infinite|limit|error|failed' | head -5; \
			fail=$$((fail+1)); \
		fi; \
	done; \
	echo ""; \
	echo "Results: $$pass passed, $$fail failed"; \
	test $$fail -eq 0

# Musl cross-compilation target - reuses LIB_SRCS/INCLUDES with overridable CC/output dir.
# Usage: make musl-lib CC=<musl-clang-wrapper> MUSL_OUTPUT_DIR=<dir> EXTRA_INCLUDES="-I<prefix>/include"
MUSL_OUTPUT_DIR ?= $(BUILD_DIR)/musl
EXTRA_INCLUDES ?=

MUSL_LIB_OBJS := $(patsubst $(SRC_DIR)/%.c,$(MUSL_OUTPUT_DIR)/%.o,$(LIB_SRCS))

$(MUSL_OUTPUT_DIR)/%.o: $(SRC_DIR)/%.c $(SKEL_HEADER) $(LIB_HEADERS)
	@mkdir -p $(MUSL_OUTPUT_DIR)
	@echo "Compiling (musl): $<"
	$(CC) $(LIB_CFLAGS) $(INCLUDES) $(EXTRA_INCLUDES) -c $< -o $@

.PHONY: musl-lib
musl-lib: $(MUSL_LIB_OBJS)
	@mkdir -p $(MUSL_OUTPUT_DIR)
	$(AR) rcs $(MUSL_OUTPUT_DIR)/libehprobe.a $(MUSL_LIB_OBJS)
	@echo "Built musl libehprobe.a at $(MUSL_OUTPUT_DIR)/libehprobe.a"

# Verify all BPF source files have the correct SPDX license header on line 1.
SPDX_EXPECTED := // SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
BPF_LICENSE_FILES := $(wildcard $(EBPF_PROGRAMS_DIR)/*.bpf.c) \
                     $(wildcard $(EBPF_IMPL_DIR)/*.h) \
                     $(wildcard $(EBPF_INCLUDE_DIR)/*.h) \
                     $(wildcard $(EBPF_SHARED_DIR)/*.h)

lint-license:
	@fail=0; \
	for f in $(BPF_LICENSE_FILES); do \
		first=$$(head -1 "$$f"); \
		if [ "$$first" != "$(SPDX_EXPECTED)" ]; then \
			echo "FAIL: $$f"; \
			echo "  expected: $(SPDX_EXPECTED)"; \
			echo "  got:      $$first"; \
			fail=$$((fail+1)); \
		fi; \
	done; \
	if [ $$fail -eq 0 ]; then \
		echo "All $$(echo $(BPF_LICENSE_FILES) | wc -w | tr -d ' ') BPF source files have correct SPDX headers."; \
	else \
		echo ""; \
		echo "$$fail file(s) missing or incorrect SPDX header."; \
		exit 1; \
	fi

.PHONY: all clean distclean vmlinux info help verify-ebpf musl-lib lint-license
