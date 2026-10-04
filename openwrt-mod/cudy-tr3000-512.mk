define Device/cudy_tr3000-v1
  DEVICE_VENDOR := Cudy
  DEVICE_MODEL := TR3000 (512MB Flash)
  DEVICE_DTS := mt7981b-cudy-tr3000-v1
  DEVICE_DTS_DIR := $(DTS_DIR)
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 499712k
  KERNEL_IN_UBI := 1
  IMAGES += factory.bin
  IMAGE/factory.bin := append-kernel | pad-to $$(BLOCKSIZE) | append-ubi | check-size
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  $(Device/mediatek_filogic)
endef
TARGET_DEVICES += cudy_tr3000-v1
