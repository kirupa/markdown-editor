.PHONY: app clean icons open test

app:
	@./Scripts/build-app.sh

icons:
	@swift ../macOS/Scripts/make-icons.swift ../macOS/Packaging \
		Resources/Assets.xcassets/AppIcon.appiconset

open:
	@open MarkdownEditor.xcodeproj

# The tests cover the shared package, which is where this app's Markdown
# engine lives, so there is one suite for both native builds.
test:
	@../macOS/Scripts/run-tests.sh

clean:
	@rm -rf -- "$(CURDIR)/build"
