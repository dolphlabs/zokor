SLANGC ?= slangc

.PHONY: test example check fmt-check

# Every package dir is listed explicitly: a new package without its own
# line here is a package with no tests, and that fails review.
test:
	$(SLANGC) test .
	$(SLANGC) test internal/path
	$(SLANGC) test internal/envfile
	$(SLANGC) test internal/validate

example:
	$(SLANGC) examples/hello/main.sl --run

# Everything the CI would run.
check: test example
