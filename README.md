This project was developed initially in a local repository before being uploaded here

# dynamic island file manager

macOS app that turns the notch into a dynamic island for sending files to google drive

## what it does

- hover the notch and the island opens, move away and it closes
- drop files on it and it suggests which drive folder each one goes in, and learns from what you pick
- send one file or a whole batch, with real upload progress, an x to stop any of them, and undo
- big files go up in chunks, and if the wifi drops it waits up to a minute for it to come back and carries on where it stopped (quit the app mid-upload and that file starts over)
- convert before sending: heic to jpeg, wav to m4a, mov to mp4 and a few more, or just save the converted file next to the original
- activity: what you sent this week, click one to open it in drive or copy its link
  - the list stays on this mac in plain text (~/Library/Application Support/DynamicIslandManager/activity.json): file names, folders, drive links and where save to mac put things, for up to 90 days or 200 files. settings > general > clear activity deletes it
- storage: how full your drive is, without opening the drive website
- settings for convert defaults, haptics, launch at login and your destination folders
- lives in the menu bar, no dock icon, and the keyboard works while you hover a card (return sends, esc closes, ⌘z undoes)

## requirements

- macOS 14.0+
- Xcode (built with Xcode 26, older ones might work)
- a google account

## setup

1. **get google oauth credentials**
   - go to https://console.cloud.google.com
   - create a new project
   - enable google drive api
   - create oauth 2.0 client id (macos app type)
   - download your client id

2. **configure the project**
   - copy `DynamicIslandManager/Info.plist.template` to `DynamicIslandManager/Info.plist` (it's gitignored, never commit it)
   - replace `YOUR_CLIENT_ID_HERE` (it's in there twice) with everything before .apps.googleusercontent.com in your client id, dash and letters included (like `1234567890-abc123def456`)
   - for picking existing drive folders: enable the **Google Picker API**, create an **API key** (restrict it to Picker API only, no app/referrer restriction), and put it in `GooglePickerAPIKey`
   - open the project in xcode

3. **build and run**
   - select your development team in signing & capabilities
   - build and run, sign in with google, then pick the folders files usually go to

## for development

debug builds have a few command line modes, run them on the built app binary:

- `--test` runs the unit tests (no ui, nothing touches your real settings)
- `--debug-scenario all` runs the on-screen checks against your real drive test folders, every upload is deleted after
- `--eval <dir>` measures the folder suggestions on a folder of sample files

## tech stack

- SwiftUI and AppKit
- Google Drive API
- GoogleSignIn SDK
- Vision, NaturalLanguage, ImageIO and AVFoundation, all on device

---

*this is a student project, expect bugs and incomplete features*
