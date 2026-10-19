.PHONY: build test install clean

build:
	./gradlew assembleDebug

test:
	./gradlew testDebugUnitTest

install: build
	adb install -r app/build/outputs/apk/debug/app-debug.apk

clean:
	./gradlew clean
