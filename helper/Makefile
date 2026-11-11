# Builds rp-hid-helper against the Karabiner DriverKit VirtualHIDDevice client headers.
# The helper's protocol version must match the installed driver package, so both come from the same tag.
KVHID_TAG := v8.7.0
DEPS := .deps/kvhid

rp-hid-helper: rp-hid-helper.cpp $(DEPS)/vendor/vendor/include
	clang++ -std=c++23 -O2 -isystem $(DEPS)/include -isystem $(DEPS)/vendor/vendor/include $< -o $@ -framework IOKit -framework CoreFoundation

$(DEPS)/vendor/vendor/include:
	rm -rf $(DEPS) && git clone -q --depth 1 -b $(KVHID_TAG) https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice.git $(DEPS)
	git -C $(DEPS) submodule update --init --depth 1 vendor/cpm-cmake-package-lock
	$(MAKE) -C $(DEPS)/vendor   # needs cmake

pkg: $(DEPS)/vendor/vendor/include
	@echo $(DEPS)/dist/Karabiner-DriverKit-VirtualHIDDevice-$(subst v,,$(KVHID_TAG)).pkg

clean:
	rm -rf rp-hid-helper .deps

.PHONY: pkg clean
