# ANTARVANI — commands

## Before anything: fix the Drive folder names

Your screenshot shows `PO8` and `PO9` with the **letter O**, while `P17`–`P20`
use digits. The folder name is the training label, so rename every one of them:

```
PO1 -> P01    PO4 -> P04    PO7 -> P07
PO2 -> P02    PO5 -> P05    PO8 -> P08
PO3 -> P03    PO6 -> P06    PO9 -> P09
```

Digit zero, not letter O. The pipeline refuses to run until this is clean —
deliberately, because the alternative is silently mislabelled training data.

---

## The app

Unzip, then from inside the project folder:

```
flutter create --org com.silentvoice --project-name silent_voice_recorder .
flutter pub get
dart fix --apply
flutter analyze
flutter run
```

Build for the other three phones:

```
flutter build apk --release
```

APK lands at `build/app/outputs/flutter-apk/app-release.apk`.

If `flutter analyze` complains about a package API, paste the output to me and
I will fix it — I have no Flutter toolchain here, so the code is written but
not compiled.

### Android config, before the first run

`android/app/src/main/AndroidManifest.xml`, above `<application>`:

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-feature android:name="android.hardware.camera" android:required="true" />
```

`android/app/build.gradle`:

```gradle
defaultConfig {
    minSdkVersion 23
    multiDexEnabled true
}
```

### First launch on each phone

The app asks **"Which phone is this?"** once. Agree the numbers with the team
first — phone 1, 2, 3, 4 — because everything else follows from it:

| Phone | Speaker IDs | Form numbers |
|---|---|---|
| 1 | S001 – S099 | F001 – F099 |
| 2 | S101 – S199 | F101 – F199 |
| 3 | S201 – S299 | F201 – F299 |
| 4 | S301 – S399 | F301 – F399 |

No server involved, so this works with no signal and cannot collide.

---

## The pipeline

Upload `ANTARVANI_pipeline.ipynb` to [Colab](https://colab.research.google.com),
then:

1. **Runtime → Change runtime type → T4 GPU**
2. Run the cells top to bottom
3. Cell 1 asks permission to mount Drive — allow it

Check `RAW_DIR` in the config cell matches your folder:

```python
RAW_DIR = '/content/drive/MyDrive/Silent_Voice'
```

Outputs land in `MyDrive/ANTARVANI_work/`:

| File | What it is |
|---|---|
| `ckpt.keras` | Training checkpoint — survives a Colab disconnect |
| `antarvani.tflite` | The model for the Android app |
| `labels.json` | Phrase list in label order |

---

## Running the preprocessing locally instead

If you would rather preprocess on the laptop than in Colab:

```
pip install opencv-python mediapipe numpy
python preprocess.py --raw ./Silent_Voice --out ./npz
```

One clip per phrase only, for a quick check:

```
python preprocess.py --raw ./Silent_Voice --out ./npz --limit-per-class 1
```

---

## What one clip per phrase actually gets you

It runs the whole pipeline end to end and proves the plumbing works. It does
**not** train a usable model, and the notebook says so rather than printing a
flattering accuracy number.

With 20 clips across 20 classes there is nothing to hold out, so train and
validation are the same data. Any accuracy you see is memorisation. The
notebook detects this and prints `SMOKE TEST MODE`.

The model starts to mean something at roughly 30 speakers. Nothing in the
notebook changes when you get there — re-run it and the honest metrics appear
on their own.


---

## Releasing a new APK to the team

The app keeps every phone on the same build. Anyone on an older build is
locked out until they install the new one, so results are never collected by
two different versions of the recorder.

**1. Bump the build number.** In `pubspec.yaml`, the line is:

```
version: 1.0.0+1
```

The number after `+` is the build number. Raise it by one for every APK you
share: `1.0.0+2`, then `+3`. The app compares only that number.

**2. Build it.**

```
flutter build apk --release
copy build\app\outputs\flutter-apk\app-release.apk ANTARVANI_build2.apk
```

**3. Upload it** to a GitHub release or Drive, and copy the link. For Drive,
share it as **Anyone with the link → Viewer**.

**4. Publish it in the app**, signed in as the master admin:
Collect data → Progress & uploads → Overview → **Publish an app update**.
Enter the build number, the link, and a line about what changed. Press
Publish.

Every other phone shows the update screen within seconds and stays locked
until it installs the new APK.

**If you typed the wrong number** and locked yourself out, sign in on the
update screen as the master admin and tap *"I published this by mistake —
undo"*. That is the only way back, so no one else can do it.
