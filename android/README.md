# VibeWake for Android

Watch and drive VibeWake on your Macs from your phone. The app:

- lists your Macs, with online / asleep / offline status, battery, and the time of the next check-in;
- shows each chat's state, as in the Agents window;
- shows Claude's last reply, rendered as Markdown;
- lets you add, edit, reorder and delete queued prompts;
- sends prompts and runs Ask for status, Continue and Resume;
- starts new chats in a project folder;
- shows notifications when a chat finishes, hits a usage limit, or waits for you.

It needs the relay from [../server](../server/README.md). Kotlin and Jetpack Compose, minimum Android 8.0 (API 26).

## Build

With Android Studio, open this folder and run the `app` configuration.

From the command line, with the Android SDK installed (`ANDROID_HOME` set) and JDK 17 or later:

```bash
./gradlew assembleDebug
adb install app/build/outputs/apk/debug/app-debug.apk
```

Without a local SDK, you can build in Docker:

```bash
docker run --rm --platform linux/amd64 -v "$PWD":/project -w /project \
  ghcr.io/cirruslabs/android-sdk:36 ./gradlew assembleDebug
```

### Release build

Create a release key once, and keep it (and its passwords) safe: updates to an installed app must be signed with the same key.

```bash
keytool -genkeypair -v -keystore vibewake-release.jks -alias vibewake -keyalg RSA -keysize 4096 -validity 10000
cat > keystore.properties <<'EOF'
storeFile=vibewake-release.jks
storePassword=<store password>
keyAlias=vibewake
keyPassword=<key password>
EOF
./gradlew assembleRelease   # → app/build/outputs/apk/release/app-release.apk
```

`keystore.properties` and `*.jks` are in `.gitignore`. Without `keystore.properties` the release build is signed with the debug key, so that you can sideload it straight away.

## Set up

1. Install the [ntfy app](https://ntfy.sh/docs/subscribe/phone/) and set its default server to your ntfy server. The ntfy app is the UnifiedPush distributor that delivers the notifications.
2. Open VibeWake, tap **Scan QR code**, and scan the code from **Pair Phone…** on your Mac. You can also scan it with the system camera; it opens the app.
3. Allow notifications. If the ntfy app isn't installed yet, choose **Notifications…** in the menu once it is.

Only `https://` relays work, except `10.0.2.2` and `localhost`, which are allowed for testing in the emulator.

## How it talks to the relay

- While the app is open, it holds a WebSocket to `/ws/app`. It shows live snapshots and sends commands. A command shows a progress bar until the Mac confirms it.
- A command sent to a sleeping Mac waits on the relay. The Mac runs it at its next check-in, and the app shows when that will be.
- In the background, the app gets nothing except notifications.

The message format is in [../protocol/PROTOCOL.md](../protocol/PROTOCOL.md).
