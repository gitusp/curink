PREFIX ?= $(HOME)/.local
BIN_DIR := $(PREFIX)/bin
BIN := $(BIN_DIR)/curink
SRC := curink.swift

.PHONY: all build install uninstall clean run

all: build

build: curink

curink: $(SRC)
	swiftc -O $(SRC) -o curink

install: build
	install -d $(BIN_DIR)
	install -m 0755 curink $(BIN)
	@echo "Installed: $(BIN)"

uninstall:
	rm -f $(BIN)

run: build
	./curink

clean:
	rm -f curink
