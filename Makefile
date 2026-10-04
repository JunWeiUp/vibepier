SHELL := /bin/sh
MACOS := apps/macos
ANDROID := apps/android
GRADLE := ./$(ANDROID)/gradlew -p $(ANDROID)

.PHONY: all build build-macos build-android build-relay test test-macos test-android test-relay lint lint-macos lint-android lint-relay format-macos

all: build
build: build-macos build-android build-relay

build-macos:
	swift build --package-path $(MACOS) -c release

build-android:
	$(GRADLE) :app:assembleDebug --console=plain

build-relay:
	cd services/relay && go build ./...

test: test-macos test-android test-relay

test-macos:
	swift test --package-path $(MACOS)

test-android:
	$(GRADLE) :app:testReleaseUnitTest --console=plain

test-relay:
	cd services/relay && go test -race ./...

lint: lint-macos lint-android lint-relay lint-repository

lint-macos:
	swift format lint --strict -r $(MACOS)/Sources $(MACOS)/Tests $(MACOS)/Package.swift

lint-android:
	$(GRADLE) :app:lintRelease --console=plain
	python3 scripts/check/android-lint.py

lint-relay:
	cd services/relay && go vet ./...

format-macos:
	swift format -i -r $(MACOS)/Sources $(MACOS)/Tests $(MACOS)/Package.swift

.PHONY: package package-macos package-android package-relay brand-assets
package: package-macos package-android package-relay

package-macos:
	./scripts/release/macos.sh

package-android:
	./scripts/release/android.sh

package-relay:
	./scripts/release/relay.sh

brand-assets:
	swift scripts/dev/brand-assets.swift

.PHONY: lint-repository
lint-repository:
	python3 scripts/check/repository.py
	python3 scripts/check/localization.py
	python3 scripts/dev/localize-macos.py --check
	python3 scripts/check/release-provenance.py
