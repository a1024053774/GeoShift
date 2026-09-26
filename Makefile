APP_NAME = DongbaAppearance
APP = build/$(APP_NAME).app
BIN = $(APP)/Contents/MacOS/$(APP_NAME)
SRC = Sources/Schedule.swift Sources/ZoneCatalog.swift Sources/Solar.swift Sources/App.swift

.PHONY: all test run status clean

all: $(APP)

$(APP): $(SRC) Info.plist
	mkdir -p $(APP)/Contents/MacOS
	swiftc -O -framework AppKit -framework ServiceManagement -o $(BIN) $(SRC)
	cp Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)

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
