BIN := remote-pointer
APP := RemotePointer.app
# A stable signing identity keeps Accessibility/Input Monitoring grants across rebuilds (ad-hoc signing loses them).
SIGN_ID ?= $(shell security find-identity -v -p codesigning | awk '/Apple Development/ {print $$2; exit}')
INSTALL_DIR := $(HOME)/Applications
SWIFTFLAGS := -O -swift-version 5 -import-objc-header mt.h
FRAMEWORKS := -framework IOKit -framework AppKit -framework CoreGraphics -framework ApplicationServices -framework QuartzCore -framework ServiceManagement -framework Speech -framework AVFoundation

SOURCES := main.swift Dictation.swift

# Info.plist is embedded in the binary too, so `make run` has usage strings for the mic/speech prompts.
$(BIN): $(SOURCES) mt.h Info.plist
	swiftc $(SWIFTFLAGS) $(SOURCES) -o $(BIN) $(FRAMEWORKS) -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist

run: $(BIN)
	./$(BIN) --debug

app: $(BIN)
	rm -rf $(APP) && mkdir -p $(APP)/Contents/MacOS
	cp $(BIN) $(APP)/Contents/MacOS/$(BIN)
	cp Info.plist $(APP)/Contents/Info.plist
	codesign --force --options runtime --entitlements RemotePointer.entitlements --sign "$(if $(SIGN_ID),$(SIGN_ID),-)" $(APP)

# Install to ~/Applications and (re)launch.
install: app
	-pkill -x $(BIN)
	mkdir -p $(INSTALL_DIR) && rm -rf $(INSTALL_DIR)/$(APP) && cp -R $(APP) $(INSTALL_DIR)/
	open $(INSTALL_DIR)/$(APP)

clean:
	rm -rf $(BIN) $(APP)

.PHONY: run app install clean
