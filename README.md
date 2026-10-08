# Bypass Copyright Engine - Flutter Android App

A production-ready offline Android application built with Flutter and **FFmpegKit (Full GPL)** that modifies video and audio streams using cryptographic and perceptual anti-fingerprinting filters.

---

## ⚡ Core Architecture

This application translates the core `video_processor.py` engine into an offline on-device native Flutter workflow:

1. **Video Filters**:
   - `crop=trunc(iw*0.96/2)*2:trunc(ih*0.96/2)*2` : 4% center zoom/crop breaks bounding edge hash coordinates.
   - `eq=contrast=1.04:saturation=1.03:brightness=0.01` : Shifts global color histogram and perceptual dHash/pHash values.
   - `vignette=PI/5` : Adds subtle corner darkening to break border spatial signatures.
   - `noise=alls=3:allf=t+u` : Injects dynamic spatio-temporal pseudo-random dither noise into every frame.

2. **Audio Filters**:
   - `asetrate=44100*1.025,aresample=44100` : Pitch shifted up by +2.5% to alter acoustic Chromaprint & Shazam audio peak bins.
   - `atempo=1.015` : Micro-tempo speed modification (+1.5%) to desynchronize automated alignment windows.
   - `equalizer=f=300:t=q:w=1:g=-2,equalizer=f=3000:t=q:w=1:g=1` : Dual harmonic EQ shifting.
   - `acompressor=threshold=-12dB:ratio=3:attack=10:release=100` : Normalizes dynamic loudness range.

3. **GPL Encoding**:
   - `-c:v libx264 -pix_fmt yuv420p -preset ultrafast`
   - `-c:a aac -b:a 192k -movflags +faststart`

---

## 🚀 Quick Setup & Run Instructions

### Step 1: Create Flutter Project
```bash
flutter create --org com.example bypass_copyright_app
cd bypass_copyright_app
```

### Step 2: Replace Dependencies
Paste the contents of `pubspec.yaml` into your project's `pubspec.yaml`:
```bash
flutter pub get
```

### Step 3: Configure Android Gradle
In `android/app/build.gradle`:
- Set `minSdk = 24` (Strict requirement for FFmpegKit Full GPL).
- Add `packaging` resolution for `libc++_shared.so` as detailed in `android/app/build.gradle`.

### Step 4: Configure Android Permissions
In `android/app/src/main/AndroidManifest.xml`:
- Add `READ_MEDIA_VIDEO` and storage permissions.

### Step 5: Replace `lib/main.dart`
Replace `lib/main.dart` with the full production code provided.

### Step 6: Run on Android Device / Emulator
```bash
flutter run
```
*(Tip: Test on a physical device or an x86_64 / arm64 emulator with API level >= 24).*
