SLANGC ?= slangc

.PHONY: test example check

# Every package dir is listed explicitly: a new package without its own
# line here is a package with no tests, and that fails review.
test:
	$(SLANGC) test src
	$(SLANGC) test src/internal/path
	$(SLANGC) test src/internal/envfile
	$(SLANGC) test src/internal/validate
	$(SLANGC) test src/internal/multipart

example:
	$(SLANGC) examples/hello/main.sl --run

# Everything CI runs.
check: test example
