SLANGC ?= slangc
TESTFLAGS ?=

.PHONY: test example check snippets api api-check

# Every package dir is listed explicitly: a new package without its own
# line here is a package with no tests, and that fails review.
# TESTFLAGS: CI passes `-v --keep`, so a crash names the last test that
# passed and leaves the runner binary to resolve its pc against.
test:
	$(SLANGC) test zokor $(TESTFLAGS)
	$(SLANGC) test zokor/internal/path $(TESTFLAGS)
	$(SLANGC) test zokor/internal/envfile $(TESTFLAGS)
	$(SLANGC) test zokor/internal/validate $(TESTFLAGS)
	$(SLANGC) test zokor/internal/multipart $(TESTFLAGS)
	$(SLANGC) test zokor/internal/ws $(TESTFLAGS)
	$(SLANGC) test zokor/internal/sio $(TESTFLAGS)

example:
	$(SLANGC) examples/hello/main.sl --run

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

# Everything CI runs.
check: test example example-chat snippets api-check
