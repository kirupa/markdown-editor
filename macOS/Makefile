.PHONY: app check-critique check-editor-clicks check-image-cursors check-image-handles check-image-layout check-scroll check-session clean icons install run test uninstall

app:
	@./Scripts/build-app.sh

check-image-cursors:
	@./Scripts/run-image-cursor-checks.sh

check-image-handles:
	@swift Scripts/check-image-handles.swift

check-editor-clicks:
	@./Scripts/run-editor-click-checks.sh

check-critique:
	@./Scripts/run-critique-checks.sh

check-image-layout:
	@./Scripts/run-image-layout-checks.sh

check-session:
	@./Scripts/run-session-checks.sh

check-scroll:
	@swift Scripts/check-scroll.swift

icons:
	@swift Scripts/make-icons.swift Packaging

install: app
	@./Scripts/install-app.sh

uninstall:
	@./Scripts/uninstall-app.sh

run: app
	@open "$(CURDIR)/build/KONVO.app"

test:
	@./Scripts/run-tests.sh

clean:
	@swift package clean
	@rm -rf -- "$(CURDIR)/build"
