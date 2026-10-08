<p align="center">
  <img src="DynamicIslandManager/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="Pigeonhole app icon">
</p>

<h1 align="center">Pigeonhole</h1>

<p align="center">A small macOS app with one job: drop a file on your MacBook's notch and it goes to the right Google Drive folder.</p>

https://github.com/user-attachments/assets/4bebb9ae-21a0-410f-99bd-cf43fb49a0b9

## How it works

- Hover over the notch to open it, drag a file onto it, and it suggests a Google Drive folder. Press Send to upload.
- The more you use it, the better its suggestions get. It learns from the folders you pick, using machine learning that runs entirely on your Mac.
- Convert files before sending, like an iPhone photo (HEIC) to JPEG or a photo of a receipt to PDF.
- See what you sent this week and how much Drive storage you have left.
- Undo a send or stop a big upload partway. Big uploads also pick up where they left off if your Wi-Fi drops for under a minute.

Your list of recent uploads is saved only on your Mac, as a plain text file (`~/Library/Application Support/DynamicIslandManager/activity.json`). It's kept for up to 90 days, and you can clear it in Settings.

## How the suggestions work (technical)

Pigeonhole uses the Vision and NaturalLanguage models that ship with macOS, plus some vector math. Nothing is downloaded, and there's no training step up front.

When you drop a file, it reads a few things from it: words in the file name, the file type, what Vision sees in an image, the text in a PDF (with OCR for scans), and a sentence embedding of that text. These become one hashed sparse vector. Each folder has a profile made from its name, an optional hint, and the files you've sent there. The file gets a score for every folder, based on cosine similarity to that folder's profile and to its three most similar past files.

Learning is bookkeeping, with no retraining. Each send saves the file as an example for that folder. If you pick a different folder than the one suggested, it saves a stronger example and lowers the score of the folder it got wrong. The next drop already uses this. I tried Create ML, but each update took seconds. A contextual embedding model wasn't more accurate and took up to 630 ms to load. When two folders score close, it says "Not sure", and when nothing fits it asks you.

On a test set of 36 real files (flower photos, scanned receipts and resumes) and 12 files that fit none of the folders, its top suggestion was right for all 36 before it had learned anything, and it was never confidently wrong. It was confident on 64% of them at the start, and on about 97% after three examples per folder. Ranking a file takes 30 to 80 ms on an M3 MacBook Air.

## Requirements

- macOS 14 or later
- Made for MacBooks with a notch, but it works on other screens too
- Xcode 26 (older versions might work)
- A Google account

## Build it

There's no download. You build it yourself, with your own Google client ID.

1. **Get a Google OAuth client ID**
   - Go to https://console.cloud.google.com and create a project
   - Enable the Google Drive API
   - Create an OAuth 2.0 client ID (macOS app type)

2. **Configure the project**
   - Copy `DynamicIslandManager/Info.plist.template` to `DynamicIslandManager/Info.plist` (it's gitignored, never commit it)
   - Replace `YOUR_CLIENT_ID_HERE` (it's in there twice) with everything before .apps.googleusercontent.com in your client ID, dash and letters included (like `1234567890-abc123def456`)
   - To pick existing Drive folders: enable the Google Picker API, create an API key restricted to the Picker API only (no app or referrer restriction), and put it in `GooglePickerAPIKey`

3. **Build and run**
   - Open `DynamicIslandManager.xcodeproj` and pick your development team in Signing & Capabilities
   - Build and run, sign in with Google, then pick the folders your files usually go to

## For development

It has 273 unit tests and 37 on-screen scenarios that drive the real app. Debug builds run them from the command line, on the built app binary:

- `--test` runs the unit tests (no UI, nothing touches your real settings)
- `--debug-scenario all` runs the on-screen checks against your real Drive test folders, every upload is deleted after
- `--eval <dir>` measures the folder suggestions on a folder of sample files

Built with SwiftUI and AppKit, the Google Drive API and the GoogleSignIn SDK. The suggestions and conversions use Vision, NaturalLanguage, ImageIO and AVFoundation, all on device.
