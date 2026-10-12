SLANGC ?= slangc

.PHONY: test example check snippets api api-check

# Every package dir is listed explicitly: a new package without its own
# line here is a package with no tests, and that fails review.
test:
	$(SLANGC) test zokor
	$(SLANGC) test zokor/internal/path
	$(SLANGC) test zokor/internal/envfile
	$(SLANGC) test zokor/internal/validate
	$(SLANGC) test zokor/internal/multipart
	$(SLANGC) test zokor/internal/ws
	$(SLANGC) test zokor/internal/sio

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
