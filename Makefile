
.DEFAULT_GOAL := all

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)

APP_BUNDLE := MillenniaControlApp.app
APP_EXECUTABLE := $(APP_BUNDLE)/Contents/MacOS/MillenniaControlApp
SIMULATOR_EXECUTABLE := build/millennia-simulator

MACOS_VERSION := 13.0
MACOS_TARGET := $(shell uname -m)-apple-macosx$(MACOS_VERSION)
MACOS_SDK := $(shell xcrun --sdk macosx --show-sdk-path)

SWIFTC := xcrun --sdk macosx swiftc
SWIFT_FLAGS := -sdk $(MACOS_SDK) -target $(MACOS_TARGET) -O

.PHONY: all clean run simulator

all: $(APP_EXECUTABLE)

simulator: $(SIMULATOR_EXECUTABLE)

$(APP_EXECUTABLE): MillenniaLaserControlApp.swift Info.plist
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	$(SWIFTC) $(SWIFT_FLAGS) -parse-as-library MillenniaLaserControlApp.swift -o $(APP_EXECUTABLE)
	@cp Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@echo "Application built: $(APP_BUNDLE)"

$(SIMULATOR_EXECUTABLE): MillenniaSimulator.swift
	@mkdir -p build
	$(SWIFTC) $(SWIFT_FLAGS) MillenniaSimulator.swift -o $(SIMULATOR_EXECUTABLE)
	@echo "Simulator built: $(SIMULATOR_EXECUTABLE)"

run: $(APP_EXECUTABLE)
	open $(APP_BUNDLE)

clean:
	rm -rf build
	rm -rf $(APP_BUNDLE)
	rm -f main.o

else

.PHONY: all clean run simulator

all simulator run:
	@echo "Error: This Makefile supports macOS only."
	@exit 1

clean:
	rm -rf build MillenniaControlApp.app
	rm -f main.o

endif
