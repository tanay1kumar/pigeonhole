# Pigeonhole

Drop a file on your MacBook's notch and it goes to the right Google Drive folder.

https://github.com/user-attachments/assets/4bebb9ae-21a0-410f-99bd-cf43fb49a0b9

## How it works

Hover the notch and it opens. Drag a file onto it and a card suggests a folder, press Send and it uploads.

The first time it doesn't know a kind of file, you pick the folder. After that, files like it get suggested there. The suggestions are worked out on your Mac, and a file only leaves it when you send it.

That's most of it. There's also:

- Convert on the way up: HEIC to JPEG, a photo of a receipt to PDF, WAV to M4A, MOV to MP4 and a few more. Or just save the converted copy next to the original
- An Activity tile with what you sent this week, click one to open it in Drive or copy its link
- A Storage tile that shows how full your Drive is
- Real progress on big uploads, an x to stop one, and undo after it's sent. If the Wi-Fi drops mid-upload it waits up to a minute and carries on where it stopped
- No Dock icon, just a menu bar item. Return sends, Esc closes, ⌘Z undoes

The Activity list stays on your Mac in plain text (`~/Library/Application Support/DynamicIslandManager/activity.json`): file names, folders, Drive links and where Save to Mac put things, for up to 90 days or 200 files. Settings › General › Clear activity deletes it.

## How the suggestions work

Each folder starts as a profile built from its name and an optional hint. When a file lands, the app reads its name and type, what Vision sees in an image, and the text of a PDF (with OCR when there isn't any), then scores each folder by how close the file is to its profile and to the files you've sent there before.

Your picks are the training. Every send adds an example, and choosing a different folder adds a stronger one. Nothing gets retrained, so one file is enough to change the next suggestion. When it isn't sure, it says so and lets you pick.

On 36 real files (flower photos, receipts and resumes) plus 12 that fit no folder, the top suggestion was right for all 36 before it had learned anything, and it was never confident and wrong. Ranking a file takes 30 to 80 ms on an M3 MacBook Air.

## Requirements

- macOS 14 or later, made for the notch (on a screen without one, hovering the top middle opens it)
- Xcode, built with Xcode 26 (older ones might work)
- A Google account

## Build it

There's no download, you build it with your own Google client ID.

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

Debug builds have a few command line modes, run them on the built app binary:

- `--test` runs the unit tests (no UI, nothing touches your real settings)
- `--debug-scenario all` runs the on-screen checks against your real Drive test folders, every upload is deleted after
- `--eval <dir>` measures the folder suggestions on a folder of sample files

Built with SwiftUI and AppKit, the Google Drive API and the GoogleSignIn SDK. The suggestions and conversions use Vision, NaturalLanguage, ImageIO and AVFoundation, all on device.
