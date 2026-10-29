# reopen-closed-buffer: reopen killed buffers through terra-emacs.
#
#   make test      byte-compile (warnings as errors), then every ERT suite
#   make compile   byte-compile only
#   make clean     remove byte-compiled files
#
# The engine comes from TERRA_EMACS_DIR (default: ../terra-emacs.el), the
# exporter from TERRA_EMACS_CAPTURE_DIR (default: ../terra-emacs-capture.el).

EMACS ?= emacs
TERRA_EMACS_DIR ?= ../terra-emacs.el
TERRA_EMACS_CAPTURE_DIR ?= ../terra-emacs-capture.el
export EMACS TERRA_EMACS_DIR TERRA_EMACS_CAPTURE_DIR

.PHONY: all test compile clean

all: test

test:
	bash test/test_reopen_closed_buffer.sh

compile:
	$(EMACS) -Q --batch -L . -L $(TERRA_EMACS_DIR) -L $(TERRA_EMACS_CAPTURE_DIR) \
	  --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile reopen-closed-buffer*.el

clean:
	rm -f *.elc
