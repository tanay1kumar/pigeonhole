This project was developed initially in a local repository before being uploaded here

# dynamic island file manager

native macOS app that adds a dynamic island-like interface for managing google drive files

## what it does

- drag and drop files to upload to google drive
- animated UI that expands/collapses kinda like iphone's dynamic island
- shows file previews in a 3d cube grid thing
- converts images and audio files before uploading

## requirements

- macOS 14.0+
- Xcode 15+
- google account

## current status

work in progress! currently at step 28 of development. still need to add:
- better file management
- lots of other stuff
- revamp local AI for organizing files (consuming too much runtime)

## setup

1. **get google oauth credentials**
   - go to https://console.cloud.google.com
   - create a new project
   - enable google drive api
   - create oauth 2.0 client id (macos app type)
   - download your client id

2. **configure the project**
   - copy `DynamicIslandManager/Info.plist.template` to `DynamicIslandManager/Info.plist`
   - replace `YOUR_CLIENT_ID_HERE` with your actual google client id (just the numbers part before .apps.googleusercontent.com)
   - for picking existing drive folders: enable the **Google Picker API**, create an **API key** (restrict it to Picker API only, no app/referrer restriction), and put it in `GooglePickerAPIKey`
   - open the project in xcode

3. **build and run**
   - select your development team in signing & capabilities
   - build and run the app

## tech stack

- SwiftUI
- Google Drive API
- GoogleSignIn SDK

---

*this is a student project, expect bugs and incomplete features*
