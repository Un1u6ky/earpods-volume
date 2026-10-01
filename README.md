# EarPods Volume

macOS sets USB-C EarPods to 100% on every reconnect. Settings can still show the previous volume, but playback stays at maximum until the slider moves. This user agent remembers the last volume for these EarPods and writes it back when they connect and when audio starts.

It only touches Apple USB-C EarPods (model `EarPods :05AC:110B`, output UID ending in `:1`). Built-in speakers, the EarPods microphone, Bluetooth, and HDMI are left alone.

## Install

Requires Xcode Command Line Tools (`swiftc`).

```sh
./install.sh
```

The script builds the binary, copies it to `~/Library/Application Support/EarPodsVolume/`, and loads a LaunchAgent for the current user. It starts at login.

## Uninstall

```sh
./uninstall.sh
```

The saved volume stays in `~/Library/Preferences/com.earpods-volume.plist`.

## Check

```sh
log show --last 5m --predicate 'subsystem == "com.earpods-volume"' --style compact
```

A copy of the same lines is appended to `~/Library/Logs/EarPodsVolume.log`.
