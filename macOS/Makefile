.PHONY: app clean icons install run test uninstall

app:
	@./Scripts/build-app.sh

icons:
	@swift Scripts/make-icons.swift Packaging

install: app
	@./Scripts/install-app.sh

uninstall:
	@./Scripts/uninstall-app.sh

run: app
	@open "$(CURDIR)/build/Markdown Editor.app"

test:
	@./Scripts/run-tests.sh

clean:
	@swift package clean
	@rm -rf -- "$(CURDIR)/build"
