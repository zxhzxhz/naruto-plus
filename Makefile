TARGET = iphone:clang:15.6:14.0
# 游戏主程序 narutoNext1 是 arm64 thin（已实测），其进程可正常加载 arm64 映像，
# 因此补丁只编 arm64 即可（GitHub 上默认走 arm64，失败时自动降级 arm64+arm64e）。
ARCHS = arm64

PACKAGE_VERSION = 1.0.0

include $(THEOS)/makefiles/common.mk

# 用 library.mk（不是 tweak.mk）：不链接 CydiaSubstrate / 不使用 Logos，
# C 函数 hook 走运行时 dlsym("MSHookFunction")（ellekit / substrate 都提供）。
LIBRARY_NAME = NarutoPlus
NarutoPlus_FILES = NarutoPlus.m
NarutoPlus_CFLAGS = -fobjc-arc -O2 -w -Wno-error
NarutoPlus_FRAMEWORKS = Foundation UIKit QuartzCore

include $(THEOS_MAKE_PATH)/library.mk
