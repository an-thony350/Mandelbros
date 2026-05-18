#   make build    Compile the C renderer.
#   make test     Build and run the C unit tests.
#   make study    Run the full study; populates data/study.npz and plots/error_table.csv.
#   make plots    Generate all figures from data/study.npz.
#   make all      build + test + study + plots.
#   make ci       Fast variant for CI: build + test + smoke study + plots.
#   make clean    Remove build artefacts, data/, and plots/.

CC      ?= cc
CFLAGS  ?= -O3 -Wall -Wextra -std=c11
LDFLAGS ?= -lm

SRC_DIR := src
BUILD   := build
PY      ?= python3

LIB_SRC := $(SRC_DIR)/fixed_mandelbrot.c $(SRC_DIR)/fixed_mandelbrot.h
RENDER  := $(BUILD)/fixed_mandelbrot
TESTBIN := $(BUILD)/test_fixed_mandelbrot

.PHONY: all compile test study plots ci clean
.DEFAULT_GOAL := all

all: compile test study plots

# C build 

$(BUILD):
	mkdir -p $(BUILD)

$(RENDER): $(SRC_DIR)/main.c $(LIB_SRC) | $(BUILD)
	$(CC) $(CFLAGS) -I$(SRC_DIR) -o $@ $(SRC_DIR)/main.c $(SRC_DIR)/fixed_mandelbrot.c $(LDFLAGS)

$(TESTBIN): $(SRC_DIR)/test.c $(LIB_SRC) | $(BUILD)
	$(CC) $(CFLAGS) -I$(SRC_DIR) -o $@ $(SRC_DIR)/test.c $(SRC_DIR)/fixed_mandelbrot.c $(LDFLAGS)

compile: $(RENDER)

# Tests 

test: $(TESTBIN)
	./$(TESTBIN)

# Study & plots

study: $(RENDER)
	$(PY) scripts/study.py

plots:
	$(PY) scripts/plot.py

# CI: smoke study so the workflow finishes in seconds, not minutes.
ci: $(RENDER) $(TESTBIN)
	./$(TESTBIN)
	$(PY) scripts/study.py --smoke
	$(PY) scripts/plot.py

# Housekeeping

clean:
	rm -rf $(BUILD) data plots/*.png plots/*.csv