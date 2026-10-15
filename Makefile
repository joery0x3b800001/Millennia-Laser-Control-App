.DEFAULT_GOAL := all

ifeq ($(shell uname -s),Darwin)
APP_BUNDLE = MillenniaControlApp.app
APP_EXECUTABLE = $(APP_BUNDLE)/Contents/MacOS/MillenniaControlApp
SIMULATOR_EXECUTABLE = build/millennia-simulator
MACOS_TARGET = $(shell uname -m)-apple-macosx13.0

.PHONY: all clean run simulator

all: $(APP_EXECUTABLE)

simulator: $(SIMULATOR_EXECUTABLE)

$(SIMULATOR_EXECUTABLE): MillenniaSimulator.swift
	@mkdir -p build
	swiftc -target $(MACOS_TARGET) -O MillenniaSimulator.swift -o $(SIMULATOR_EXECUTABLE)

$(APP_EXECUTABLE): MillenniaLaserControlApp.swift Info.plist
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	swiftc -target $(MACOS_TARGET) -O -parse-as-library MillenniaLaserControlApp.swift -o $(APP_EXECUTABLE)
	@cp Info.plist $(APP_BUNDLE)/Contents/Info.plist

run: $(APP_EXECUTABLE)
	@open $(APP_BUNDLE)

clean:
	rm -f main.o
	rm -rf build
	rm -rf $(APP_BUNDLE)
endif