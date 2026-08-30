.PHONY: app check-image-cursors check-image-handles check-image-layout check-scroll check-session clean icons install run test uninstall

app:
	@./Scripts/build-app.sh

check-image-cursors:
	@./Scripts/run-image-cursor-checks.sh

check-image-handles:
	@swift Scripts/check-image-handles.swift

check-image-layout:
	@./Scripts/run-image-layout-checks.sh

check-scroll:
	@swift Scripts/check-scroll.swift

check-session:
	@./Scripts/run-session-checks.sh

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
