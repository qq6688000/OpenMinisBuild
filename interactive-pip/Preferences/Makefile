export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64e
export DEB_ARCH = iphoneos-arm64e
export THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = DualPanePrefs

DualPanePrefs_FILES = DPRootListController.m DPAppListController.m
DualPanePrefs_FRAMEWORKS = UIKit
# Preferences.framework is private and missing from public SDKs.
# Compile against vendored stubs; resolve the real framework at runtime in Settings.
DualPanePrefs_CFLAGS = -fobjc-arc -Wno-unused-variable -Ivendor/include
DualPanePrefs_LDFLAGS = -undefined dynamic_lookup
DualPanePrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/DualPane.plist$(ECHO_END)
