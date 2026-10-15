SLANGC ?= slangc
TESTFLAGS ?=

.PHONY: test example example-ports check snippets api api-check docs docs-check cli cli-test templates templates-check

# Every package dir is listed explicitly: a new package without its own
# line here is a package with no tests, and that fails review.
# TESTFLAGS: CI passes `-v --keep`, so a crash names the last test that
# passed and leaves the runner binary to resolve its pc against.
test:
	-$(SLANGC) test zokor --run test_ws_ $(TESTFLAGS)
	-$(SLANGC) test zokor --run test_sio_ $(TESTFLAGS)
	-$(SLANGC) test zokor --run tls $(TESTFLAGS)
	-SLANG_GC_VERIFY_MINOR=1 SLANG_GC_NURSERY_KB=16 $(SLANGC) test zokor --run test_ws_ $(TESTFLAGS)
	$(SLANGC) test zokor $(TESTFLAGS)
	$(SLANGC) test zokor/internal/path $(TESTFLAGS)
	$(SLANGC) test zokor/internal/envfile $(TESTFLAGS)
	$(SLANGC) test zokor/internal/validate $(TESTFLAGS)
	$(SLANGC) test zokor/internal/multipart $(TESTFLAGS)
	$(SLANGC) test zokor/internal/ws $(TESTFLAGS)
	$(SLANGC) test zokor/internal/sio $(TESTFLAGS)
	$(SLANGC) test zokor/internal/migration $(TESTFLAGS)
	$(SLANGC) test zokor/internal/trace $(TESTFLAGS)
	$(SLANGC) test zokor/internal/openapi $(TESTFLAGS)
	$(SLANGC) test zokor/internal/accept $(TESTFLAGS)
	$(SLANGC) test zokor/internal/location $(TESTFLAGS)
	$(SLANGC) test examples/ports/src/domain/inventory $(TESTFLAGS)
	$(SLANGC) test examples/ports/src/application/inventory $(TESTFLAGS)
	$(SLANGC) test examples/ports/src/infrastructure/memory $(TESTFLAGS)
	$(SLANGC) test examples/ports/src/interfaces/web $(TESTFLAGS)

cli:
	mkdir -p bin
	$(SLANGC) cmd/zokor/main.sl -o bin/zokor

# cmd/zokor/templates.sl embeds cmd/zokor/templates/ for `zokor new` and
# `zokor add`; templates-check fails when someone edited a template and
# did not regenerate it.
templates:
	sh cmd/zokor/gen_templates.sh

templates-check:
	sh cmd/zokor/gen_templates.sh --check

cli-test: cli
	sh tests/cli.sh
	SLANGC="$(SLANGC)" sh tests/scaffold.sh

example:
	$(SLANGC) examples/hello/main.sl --run

example-ports:
	$(SLANGC) examples/ports/src/main.sl --run

example-chat:
	$(SLANGC) examples/chat/main.sl --run

# docs/ is not a package (`slangc test` cannot run it), so its line here
# is the guide's drift check: every ```slang block in llms-small.txt
# must still compile and run.
snippets:
	SLANGC="$(SLANGC)" docs/check_snippets.sh

# docs/api.txt is generated from the doc comments in zokor/*.sl; api-check
# fails when someone changed a public symbol and did not regenerate it.
api:
	docs/gen_api.sh

api-check:
	docs/gen_api.sh --check

docs: api
	python3 www/build.py

docs-check: api-check
	python3 www/build.py --check

# Everything CI runs.
check: test example example-chat example-ports snippets api-check docs-check templates-check cli-test
