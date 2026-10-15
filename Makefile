APP_NAME = GeoShift
APP = build/$(APP_NAME).app
BIN = $(APP)/Contents/MacOS/$(APP_NAME)
SRC = Sources/Schedule.swift Sources/ZoneCatalog.swift Sources/Solar.swift Sources/Location.swift Sources/Window.swift Sources/App.swift
PRIVILEGE = build/Privilege.o

.PHONY: all test run status clean

all: $(APP)

$(APP): $(SRC) Sources/Privilege.c Sources/Privilege.h Sources/system_location.py Info.plist
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	clang -c Sources/Privilege.c -o $(PRIVILEGE)
	swiftc -O -import-objc-header Sources/Privilege.h -framework AppKit -framework ServiceManagement -framework Security -o $(BIN) $(SRC) $(PRIVILEGE)
	cp Info.plist $(APP)/Contents/Info.plist
	cp Sources/system_location.py $(APP)/Contents/Resources/system_location.py
	codesign --force --sign - $(APP)
	codesign --verify --strict $(APP)

test:
	mkdir -p build
	swiftc -o build/schedule-tests Sources/Schedule.swift Sources/ZoneCatalog.swift Sources/Solar.swift Tests/ScheduleTests.swift
	build/schedule-tests

status: all
	$(BIN) --status

run: all
	open $(APP)

clean:
	rm -rf build
