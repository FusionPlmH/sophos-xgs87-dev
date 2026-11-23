# Out-of-tree modules for the XGS 87 NPU side (CN9130).
#
# Upstream code plus the patches in ntb/; the NPU has no working in-tree
# equivalents because Debian arm64 does not build PCI_ENDPOINT_CONFIGFS,
# PCIE_DW_PLAT_EP, NTB or SPI_ORION at all.
KDIR ?= /lib/modules/$(shell uname -r)/build

obj-m := ntb_core.o ntb_transport.o ntb_netdev.o \
	 pci_ep_cfs.o pci_epf_vntb.o pcie_dw_plat.o \
	 spi-orion.o clkfix.o

# The two DesignWare/EPF files are compiled as modules that upstream normally
# builds into the kernel, so the feature macros have to be forced on the
# command line.
ccflags-y := -DCONFIG_PCIE_DW_PLAT_EP=1 -DCONFIG_PCI_ENDPOINT_CONFIGFS=1

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

.PHONY: all clean
