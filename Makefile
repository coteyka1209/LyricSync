# LyricSync — synchronized (LRC) lyrics highlighting for the iOS 6 Music app
#
# Tested on: iPhone 4S (iPhone4,1), iOS 6.1.3 (10B329), ARMv7

export ARCHS = armv7
export TARGET = iphone:clang:6.1:6.0
export DEBUG = 0
# Can be overridden from the environment: THEOS_DEVICE_IP=192.168.x.x make install
export THEOS_DEVICE_IP ?= 192.168.31.179

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LyricSync

LyricSync_FILES = Tweak.xm
LyricSync_CFLAGS = -fobjc-arc
LyricSync_LIBRARIES = substrate
LyricSync_LDFLAGS = -framework MediaPlayer -framework UIKit -framework WebCore

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 Music~iphone 2>/dev/null; true"
