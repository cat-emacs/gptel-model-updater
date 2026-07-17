EMACS ?= emacs
BATCH = $(EMACS) --batch --quick
LOAD_PATH = -L .

# Package archives setup
ARCHIVES = --eval "(require 'package)" \
           --eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t)" \
           --eval "(package-initialize)"

.PHONY: help install-deps lint build test clean

help:
	@echo "Targets:"
	@echo "  install-deps  - Install gptel and package-lint"
	@echo "  lint          - Run package-lint and checkdoc"
	@echo "  build         - Byte-compile the package"
	@echo "  test          - Run ERT tests"
	@echo "  clean         - Remove .elc files"

# The melpa transient requires compat 31 for `static-when'.  Emacs ships a
# built-in compat that satisfies a version-less `package-install', so install
# compat from its archive descriptor to force the newer version; otherwise
# transient byte-compiles without the macro and fails to load.
install-deps:
	$(BATCH) $(ARCHIVES) \
	  --eval "(package-refresh-contents)" \
	  --eval "(package-install 'package-lint)" \
	  --eval "(package-install (cadr (assq 'compat package-archive-contents)))" \
	  --eval "(package-install 'transient)" \
	  --eval "(package-install 'gptel)"

lint:
	$(BATCH) $(ARCHIVES) $(LOAD_PATH) \
	  --eval "(require 'package-lint)" \
	  --eval "(package-lint-batch-and-exit)" \
	  gptel-model-updater.el
	$(BATCH) $(LOAD_PATH) \
	  --eval "(checkdoc-file \"gptel-model-updater.el\")"

build:
	$(BATCH) $(ARCHIVES) $(LOAD_PATH) \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  --eval "(byte-compile-file \"gptel-model-updater-metadata.el\")" \
	  --eval "(byte-compile-file \"gptel-model-updater-ui.el\")" \
	  --eval "(byte-compile-file \"gptel-model-updater.el\")" \
	  --eval "(byte-compile-file \"gptel-model-updater-transient.el\")"

test:
	$(BATCH) $(ARCHIVES) $(LOAD_PATH) \
	  -l gptel-model-updater.el \
	  -l gptel-model-updater-tests.el \
	  --eval "(ert-run-tests-batch-and-exit)"

clean:
	rm -f *.elc
