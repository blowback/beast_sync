# Makefile for sync
BEAST_DIR = /home/ant/src/microbeast
BEASTEM_DIR = $(BEAST_DIR)/beastem
SJASMPLUS_DIR = $(BEAST_DIR)/sjasmplus
IZCPM_DIR = $(BEAST_DIR)/iz-cpm
CPMTOOLS_DIR = $(BEAST_DIR)/cpmtools-2.23

SJASMPLUS = $(SJASMPLUS_DIR)/sjasmplus
BEASTEM = $(BEASTEM_DIR)/beastem
IZCPM = $(IZCPM_DIR)/target/release/iz-cpm

# CP/M stuff
CPM_DISK_TYPE = -f memotech-type50
CPM_IMAGE = nvaders_p25.img 
MKFS = $(CPMTOOLS_DIR)/mkfs.cpm 
MKFS_OPTS = $(CPM_DISK_TYPE) -b cpm22.bin 
CP = $(CPMTOOLS_DIR)/cpmcp 
CP_OPTS = $(CPM_DISK_TYPE)
LS = $(CPMTOOLS_DIR)/cpmls 
LS_OPTS = $(CPM_DISK_TYPE)

# Default to the newest firmware. Override to check another version:
#   make run FIRMWARE=$(BEAST_DIR)/flash_v1.6.bin
FIRMWARE ?= $(BEAST_DIR)/flash_v1.8.bin

TARGET = sync.com
LISTING = sync.lst

all: $(TARGET)

build: all

$(TARGET): sync.asm 
	$(SJASMPLUS) --nologo --lst=$(LISTING) sync.asm

clean:
	rm -f $(TARGET) $(LISTING) nvtest.com nvtest.lst nvgame.com nvgame.lst
	rm -f invaders.com invaders.lst	# stale artifact from the old output name


.PHONY: all build clean 
