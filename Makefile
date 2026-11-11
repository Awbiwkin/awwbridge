TARGET = iphone:clang:latest:15.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TOOL_NAME = wifibridge-diag
wifibridge-diag_FILES = src/main.m
wifibridge-diag_FRAMEWORKS = Foundation SystemConfiguration
wifibridge-diag_CFLAGS = -fobjc-arc
wifibridge-diag_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk

include $(THEOS_MAKE_PATH)/package.mk
