TARGET := iphone:clang:16.5:16.1
ARCHS := arm64e
THEOS_PACKAGE_SCHEME := 

# This legacy target is for object checks only. Release packaging includes
# preferences, signing and arm64e fixup validation in build-apple.py.
ifneq ($(filter package install,$(MAKECMDGOALS)),)
$(error Release packages require macOS/Xcode: run python3 build-apple.py)
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := SplitPane
SplitPane_FILES := $(wildcard Sources/*.m)
SplitPane_FRAMEWORKS := UIKit Foundation QuartzCore CoreGraphics UniformTypeIdentifiers CoreMotion
SplitPane_PRIVATE_FRAMEWORKS :=
SplitPane_CFLAGS := -isystem $(THEOS)/sdks/iPhoneOS16.5.sdk/usr/include-c++ 
SplitPane_CFLAGS += -fobjc-arc -ISources -Wno-objc-multiple-method-names -Wno-unguarded-availability-new -fno-modules -fno-module-maps -DSDK16
SplitPane_LDFLAGS := -Xlinker -undefined -Xlinker dynamic_lookup
SplitPane_INSTALL_PATH := /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk
