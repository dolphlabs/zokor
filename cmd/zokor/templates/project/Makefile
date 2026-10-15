SLANGC ?= slangc
ZOKOR ?= zokor

.PHONY: test build run check

# Every package with tests, found rather than listed, so a new one is
# never left out.
test:
	@set -e; for d in $$(find src -name '*_test.sl' | xargs -n1 dirname | sort -u); do \
		$(SLANGC) test $$d; \
	done

build:
	mkdir -p bin
	$(SLANGC) src/main.sl -o bin/__service__

run: build
	./bin/__service__

check: test build
