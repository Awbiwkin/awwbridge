TARGET = iphone:clang:latest:15.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TOOL_NAME = wifibridge

wifibridge_FILES = src/main.m
wifibridge_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
wifibridge_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/package.mk
