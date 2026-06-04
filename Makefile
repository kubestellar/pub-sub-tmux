PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
LIBDIR ?= $(PREFIX)/lib/pub-sub-tmux
CONFDIR ?= $(PREFIX)/etc/pub-sub-tmux

.PHONY: install uninstall test test-patterns test-integration

install:
	@mkdir -p $(BINDIR) $(LIBDIR) $(CONFDIR)/patterns.d
	@install -m 755 bin/pst-publish $(BINDIR)/pst-publish
	@install -m 755 bin/pst-subscribe $(BINDIR)/pst-subscribe
	@install -m 755 bin/pst-send $(BINDIR)/pst-send
	@install -m 644 lib/pst-common.sh $(LIBDIR)/pst-common.sh
	@install -m 644 lib/pst-json.sh $(LIBDIR)/pst-json.sh
	@install -m 644 lib/pst-patterns.sh $(LIBDIR)/pst-patterns.sh
	@cp -n config/patterns.d/*.patterns $(CONFDIR)/patterns.d/ 2>/dev/null || true
	@echo "pub-sub-tmux installed to $(BINDIR)"

uninstall:
	@rm -f $(BINDIR)/pst-publish $(BINDIR)/pst-subscribe $(BINDIR)/pst-send
	@rm -rf $(LIBDIR)
	@echo "pub-sub-tmux removed from $(BINDIR)"

test: test-patterns test-integration

test-patterns:
	@bash tests/test-patterns.sh

test-integration:
	@bash tests/test-publish-subscribe.sh
