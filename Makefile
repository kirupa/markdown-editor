.PHONY: app clean run test

app:
	@./Scripts/build-app.sh

run: app
	@open "$(CURDIR)/build/Markdown Editor.app"

test:
	@./Scripts/run-tests.sh

clean:
	@swift package clean
	@rm -rf -- "$(CURDIR)/build"
