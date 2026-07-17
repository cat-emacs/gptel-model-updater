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

install-deps:
	$(BATCH) $(ARCHIVES) \
	  --eval "(package-refresh-contents)" \
	  --eval "(package-install 'package-lint)" \
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
