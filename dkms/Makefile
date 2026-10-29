# Build wrapper used by dkms.conf (and usable by hand: `make KVER=...`).
# Extracts + patches sound/usb, then builds only snd-usb-audio and
# snd-usbmidi-lib (not the other USB audio drivers in sound/usb).

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

all:
	sh ./prepare-sources.sh $(KVER)
	$(MAKE) -C $(KDIR) M=$(CURDIR)/src/sound/usb modules

clean:
	rm -rf src

.PHONY: all clean
