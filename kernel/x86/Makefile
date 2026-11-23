# Out-of-tree modules for the XGS 87 x86 side.
#
# Everything here is upstream code plus the patches in ntb/, so a DKMS rebuild
# against a new kernel is all that is needed after an upgrade.
KDIR ?= /lib/modules/$(shell uname -r)/build

obj-m := ntb_core.o ntb_transport.o ntb_netdev.o ntb_hw_epf.o

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

.PHONY: all clean
