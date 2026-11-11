THEOS ?= $(HOME)/theos
TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = WeChat

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WeChatPlugin
WeChatPlugin_FILES = Tweak.x
WeChatPlugin_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/tweak.mk
