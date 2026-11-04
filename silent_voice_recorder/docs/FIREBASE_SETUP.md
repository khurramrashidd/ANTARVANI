# ANTARVANI — Firebase setup from the CLI

> **Easiest:** run `setup` in this folder. It does every step below that a
> command can do, checks the rest, and opens the console pages that need a
> click. This file is the manual reference.

Master admin: **khurramrashid0786@gmail.com**

Run every command from inside `silent_voice_recorder`.

---

## 1. The project (already created)

Project ID **antarvaani-the-voice** exists, owned by **khurramrashid6893@gmail.com**.
Make sure the CLI is logged in as that account:

```
firebase logout
firebase login
firebase projects:list
```

Give the 0786 account full console access too:
[IAM page](https://console.cloud.google.com/iam-admin/iam?project=antarvaani-the-voice)
→ **Grant access** → `khurramrashid0786@gmail.com` → role **Owner** → Save.

---

## 2. Enable the APIs, then create the database

The earlier 403 means the Firestore API is switched off. Open each link while
signed in as 6893 and press **Enable**:

- [Cloud Firestore API](https://console.developers.google.com/apis/api/firestore.googleapis.com/overview?project=antarvaani-the-voice)
- [Google Drive API](https://console.developers.google.com/apis/api/drive.googleapis.com/overview?project=antarvaani-the-voice)

Wait one minute, then (one line):

```
firebase firestore:databases:create "(default)" --location=asia-south1 --project=antarvaani-the-voice
```

`asia-south1` is Mumbai — lowest latency and keeps the data in India.

---

## 3. Enable Google sign-in — console only

**This one cannot be done from the CLI.** There is no firebase-tools command
for enabling an auth provider.

[Console](https://console.firebase.google.com) → **Build → Authentication →
Get started → Sign-in method → Google → Enable → Save**.

Set the project support email to khurramrashid0786@gmail.com when it asks.

Without this step, sign-in fails and both the chat and the shared dashboard
stay empty.

---

## 4. Connect the app

```
flutterfire configure --project=antarvaani-the-voice
```

Select **android** only. This registers the Android app, downloads
`google-services.json`, and writes `lib/firebase_options.dart` — which the zip
deliberately does not contain, so unzipping can never overwrite your real
config with a stub.

```
flutter pub get
flutter analyze
```

The `firebase_options.dart` error should now be gone.

---

## 5. Security rules

```
firebase init firestore
```

Accept the defaults, then replace `firestore.rules` with:

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    function signedIn()  { return request.auth != null; }
    function email()     { return request.auth.token.email; }

    // The one account that can never be locked out.
    function isMaster()  { return signedIn() &&
                           email() == 'khurramrashid0786@gmail.com'; }

    function userDoc()   { return /databases/$(database)/documents/users/$(email()); }
    function role()      { return get(userDoc()).data.role; }
    function hasProfile(){ return signedIn() && exists(userDoc()); }

    function isAdmin()   { return isMaster() || (hasProfile() && role() == 'admin'); }
    function isMember()  { return isAdmin() || (hasProfile() && role() == 'member'); }

    // Everyone who signs in. New people may only create themselves as a
    // patient; they may refresh their own name/photo but never their role.
    // Admins set patient/member; only the master grants or removes admin.
    match /users/{userEmail} {
      allow read: if signedIn() && (email() == userEmail || isAdmin());
      allow create: if signedIn() && email() == userEmail &&
        (request.resource.data.role == 'patient' ||
         (isMaster() && request.resource.data.role == 'admin'));
      allow update: if signedIn() && (
        (email() == userEmail &&
           request.resource.data.role == resource.data.role) ||
        (isAdmin() && userEmail != 'khurramrashid0786@gmail.com' &&
           (isMaster() || (resource.data.role != 'admin' &&
                           request.resource.data.role != 'admin')))
      );
      allow delete: if isMaster() && userEmail != 'khurramrashid0786@gmail.com';
    }

    // Shared speaker counter: S001, S002 ... for every collector.
    match /counters/{id} {
      allow read, write: if isMember();
    }

    // A volunteer linking their own account to the session they took part in.
    // They never read the row first — they write the form number they typed
    // as claimProof, and this rule accepts the write only if it matches the
    // one already stored. A wrong guess is refused by the server, so nobody
    // can walk through S001, S002, S003 looking at names.
    function claimsOwnRow() {
      return signedIn()
        && request.resource.data.diff(resource.data).affectedKeys()
             .hasOnly(['claimedBy', 'claimedAt', 'claimProof'])
        && request.resource.data.claimedBy == email()
        && request.resource.data.claimProof == resource.data.consentFormId
        && (!('claimedBy' in resource.data) ||
            resource.data.claimedBy == null ||
            resource.data.claimedBy == email());
    }
    function isClaimant() {
      return signedIn() && 'claimedBy' in resource.data
        && resource.data.claimedBy == email();
    }
    function claimedSpeaker(sid) {
      return signedIn()
        && exists(/databases/$(database)/documents/speakers/$(sid))
        && get(/databases/$(database)/documents/speakers/$(sid))
             .data.claimedBy == email();
    }

    // Collected data. Collectors record; only admins delete.
    match /clips/{id} {
      // A volunteer may read their own clips once their account is linked.
      allow read:          if isMember() || claimedSpeaker(resource.data.speakerId);
      allow create, update: if isMember();
      allow delete:         if isAdmin();
    }
    match /speakers/{id} {
      allow read:          if isMember() || isClaimant();
      allow create:        if isMember();
      allow update:        if isMember();
      // The volunteer's own two writes: linking their account, and asking for
      // their clips to be deleted. Nothing else on the row may change.
      allow update: if claimsOwnRow();
      allow update: if isClaimant()
        && request.resource.data.diff(resource.data).affectedKeys()
             .hasOnly(['deletionRequested', 'deletionRequestedAt']);
      // A collector may delete a speaker row they created and that produced
      // nothing, so the number returns to the pool. Admins may delete any.
      allow delete: if isAdmin() ||
        (isMember() && resource.data.collectorEmail == email());
    }
    match /devices/{id} {
      allow read, write: if isMember();
    }

    // Team chat.
    match /messages/{id} {
      allow read, create: if isMember();
      allow delete:       if isAdmin();
    }

    // A patient's own data (history, personalisation) — theirs alone.
    match /patients/{ownerEmail}/{rest=**} {
      allow read, write: if signedIn() && email() == ownerEmail;
    }

    // Anything not named above is denied.
    match /{document=**} {
      allow read, write: if false;
    }
  }
}
```

Deploy:

```
firebase deploy --only firestore:rules
```

**Do not skip this.** Default test-mode rules let anyone holding your API key
— which ships inside the APK — read and delete everything.

---

## 6. Roles

There is no list to fill in by hand any more. Everyone who signs in gets a
`users/{email}` document with role `patient`. Sign in as
khurramrashid0786@gmail.com → sidebar → **Admin → Users & roles** → tap a
person's role → **Collector** (or **Admin**, master only).

---

## 7. OAuth fingerprints

Google sign-in fails **silently** without these.

```
cd android
gradlew signingReport
```

Copy the SHA-1 under `Variant: debug` into **Console → Project settings → Your
apps → Android → Add fingerprint**, then re-download `google-services.json`
into `android/app/`.

**Repeat for the release SHA-1 before building the APK** for the other three
phones. Debug and release are different keys — register only the debug one and
sign-in works under `flutter run` but fails on the installed APK.

---

## 8. Run

```
flutter pub get
flutter analyze
flutter test
flutter run
```

Then for the team:

```
flutter build apk --release
```

APK: `build/app/outputs/flutter-apk/app-release.apk`

---

## Drive — who owns what

- Firebase project (database, chat, sign-in): **khurramrashid6893**.
- Video clips: the corpus folder in **khurramrashid0786**'s Drive,
  `P01..P20/Sxxx_Pyy_tzz.mp4`.
- Every phone uploads as the person signed in on it, so 0786 shares the
  corpus folder with each member as **Editor**. Uploaded files count against
  the uploader's own 15 GB (a few GB each for this corpus).
- If the OAuth audience is in **Testing**, all four Gmails must be test users.

## What each person does on first launch

1. Open the app, **sign in with the Google account the admin added**.
2. Answer **"Which phone is this?"** — 1, 2, 3 or 4, agreed with the team.
3. Enter their first name as operator.

From then on the app issues their speaker IDs and form numbers automatically
from their own block, so nothing can collide.
