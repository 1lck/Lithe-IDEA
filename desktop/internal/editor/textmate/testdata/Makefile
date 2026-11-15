# A sample Makefile with the constructs the grammar knows.
SHELL := /bin/bash
PREFIX ?= /usr/local
CFLAGS += -O2 -Wall
SOURCES = $(wildcard src/*.c) $(shell ls lib/*.c)
OBJECTS := $(SOURCES:.c=.o)
VERSION = $(shell git describe --tags 2>/dev/null || echo unknown)
override DEBUG = 1
export PATH := $(PREFIX)/bin:$(PATH)
define MULTI
line one $(PREFIX)
line two ${CFLAGS}
endef

.PHONY: all clean install
.DEFAULT_GOAL := all

all: build/app ## Build everything

build/%.o: src/%.c | build
	@echo "compiling $< -> $@"
	$(CC) $(CFLAGS) -c $< -o $@

build/app: $(OBJECTS)
	$(CC) $^ -o $@ $(LDLIBS)
	@printf '%s\n' "built $(notdir $@)"

ifeq ($(DEBUG),1)
CFLAGS += -g
else ifneq ($(origin CC),default)
$(info using $(CC))
endif

ifdef VERBOSE
  Q :=
else
  Q := @
endif

clean:
	rm -rf build $(wildcard *.tmp) # remove outputs
	-$(MAKE) -C sub clean

install: all
	install -d $(DESTDIR)$(PREFIX)/bin
	for f in $(OBJECTS); do \
		echo "$$f"; \
	done

include config.mk
-include $(OBJECTS:.o=.d)
vpath %.c src
$(foreach dir,$(DIRS),$(eval $(call RULE,$(dir))))
