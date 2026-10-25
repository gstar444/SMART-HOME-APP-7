# Android release signing

Release builds are **never** signed with the debug key any more, and the build fails (by design) if no keystore is configured.

1. Create a keystore once and **back it up** (losing it means you can no longer update installed apps):
   ```
   keytool -genkey -v -keystore android/app/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
   ```
2. Create `android/key.properties` (already git-ignored together with `*.jks`):
   ```
   storePassword=<password>
   keyPassword=<password>
   keyAlias=upload
   storeFile=upload-keystore.jks
   ```
   (`storeFile` is relative to `android/app/`, or an absolute path.)
3. `flutter build apk --release --split-per-abi`
4. GitHub Actions: add repository secrets `ANDROID_KEYSTORE_BASE64` (`base64 -w0 upload-keystore.jks`),
   `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. Without them the workflow builds an
   **unsigned-for-release debug APK** instead (useful for forks), never a debug-signed "release".

`applicationId` / `namespace` stay `com.example.esp32_controller` as requested. Ids starting with `com.example` are
rejected by Google Play: change both in `android/app/build.gradle.kts` (and the Kotlin package folder) if you publish there.
Debug and profile builds (`flutter run`) are unaffected.
