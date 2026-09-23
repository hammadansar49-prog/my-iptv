# MY IPTV – announcement push (Firebase)

Optional. Without it the Android app still shows announcements as a notification
via its ~15-minute background poll; this makes it instant.

1. Firebase console → project **theottdeals-reviews** → Project settings → *Add app* →
   Android, package name **`com.theottdeals.theottdeals`** (no SHA needed).
2. Download `google-services.json` into `android_app/android/app/`
   (Gradle only applies the google-services plugin when this file exists).
   Rebuild and install the APK.
3. Upgrade the project to the **Blaze** plan (Cloud Functions requires it; this usage is within the free tier).
4. Deploy the function (Node 20, Firebase CLI):
   ```
   npm i -g firebase-tools
   firebase login
   cd firebase/functions && npm install && cd ..
   firebase deploy --only functions
   ```
   The function is `myiptvAnnouncementPush` (codebase `myiptv`, so deploying won't
   delete any other functions in the project). If the RTDB isn't in `us-central1`,
   change `region` in `functions/index.js`.
5. Test: publish an announcement from the admin panel with the app closed →
   "MY IPTV" notification → tap → the app opens with the announcement popup.

Nothing here changes the admin panel or the database rules.
