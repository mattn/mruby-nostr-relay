MRUBY_DIR := $(CURDIR)/mruby
MRUBY_CONFIG := $(CURDIR)/my-config.rb
MRUBY_BIN := $(MRUBY_DIR)/build/host/bin/mruby

.PHONY: all clean run

all: $(MRUBY_BIN)

$(MRUBY_DIR):
	git clone --depth=1 https://github.com/mruby/mruby.git $(MRUBY_DIR)

$(MRUBY_BIN): $(MRUBY_DIR)
	cd $(MRUBY_DIR) && MRUBY_CONFIG=$(MRUBY_CONFIG) rake -j8

clean:
	cd $(MRUBY_DIR) && MRUBY_CONFIG=$(MRUBY_CONFIG) rake clean

run: $(MRUBY_BIN)
	$(MRUBY_BIN) nostr-relay.rb
