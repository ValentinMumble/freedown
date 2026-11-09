# Freedown 📸

A Mac app to see what fills your iCloud Photos, and to clean it up. It shows what each photo and video
really costs in iCloud, finds duplicates and near-identical shots, strips the motion from Live Photos,
drops the originals kept under edits, shrinks videos, and fixes dates in batches. Native SwiftUI on
Apple's PhotoKit: the library never leaves your Mac, and every deletion goes through macOS's own
confirmation.

![Videos, biggest first, with iCloud storage by app in the sidebar](docs/videos.png)

<sub>Photos are blurred in these screenshots, with the app's `BlurPhotos` setting.</sub>

## Why

iCloud says "Photos: 35 GB" and nothing more. Most of it is rarely the photos themselves:

- **Live Photos** carry a few seconds of video, often bigger than the photo. On the library this was built
  on, 1,600 Live Photos held 5.7 GB of motion.
- **Edits** keep the original *and* the edited version, and an edited Live Photo keeps two motion clips.
- **Videos** are usually the biggest items by far, and a few are worth re-encoding.
- **Bursts and retakes**: several shots of the same moment.

Freedown counts every file iCloud stores for an item, so the sizes it shows add up to what iCloud bills.

## What it does

| View | What it does |
|---|---|
| Videos, Photos | everything, biggest first, with the size iCloud really stores |
| Duplicates & Similar | exact copies first, which can all go in one click; then photos taken less than a minute apart that look alike, with the best one picked to keep |
| Probably Accidental | photos that look taken by mistake (in a pocket, of the floor, a black or blurred frame), to look at and delete |
| Live Photos | **Remove Motion**: each one becomes a still, with its edit, the same date, place, favorite and albums |
| No People or Pets | Live Photos where Vision finds no person, face, cat or dog: the motion rarely matters there |
| Hidden Motion | stills that still store a Live Photo's motion clip, which Photos no longer plays but iCloud still counts: Remove Motion frees it |
| Edited | **Keep Edited Version**: the edited version alone replaces the item, and the original under it goes; a Live Photo stays live, with its edited motion |
| Only Rotated | edits that only rotate an item (or change nothing), where the original is a full extra copy: same Keep Edited Version |
| JPEG Photos | **Convert to HEIC**: lightly compressed JPEGs are saved again as HEIC, and the copy replaces the JPEG only when it is smaller and looks the same |
| Screenshots | rarely worth keeping for long |
| iCloud Drive | files in iCloud Drive and in apps' iCloud folders from 1 MB, biggest first, to move to the Trash or show in Finder |
| Clean Up | disk space on this Mac: the Trash, Docker leftovers, caches that tools and apps fill again, app update downloads, browser caches and apps not opened for 60 days |
| Half-Frame Scans | lab scans of half-frame film, two shots per picture: check the cut, turn each half, and split them into two photos |
| Shrinking | re-encodes the videos you pick in Videos to a smaller file, keeping a copy only when it looks the same |
| Favorites | what the name says |

![Duplicates & Similar](docs/duplicates-similar.png)

Select items (click, Cmd-click, Shift-click, or right-click) to delete them, add them to Favorites, change
their date or open them in Photos (double-click does that too). The keyboard works too: the arrow keys move
through the grid, Cmd-A selects everything shown, Space plays or pauses the video or Live Photo in the panel,
Return opens the item in Photos, and M marks Live Photos for Remove Motion.

The saved total is split three ways: photos, files (from iCloud Drive, or the Trash emptied in Clean Up) and
caches, kept apart because apps fill them again. Moving something to the Trash counts once the Trash is
emptied. Clicking "Saved with Freedown" in the sidebar shows what each day saved, by kind of change, next to iCloud's
free space read along the way. When shrinking or a replacement ends while you are in another app, a
notification says how it went. The shrink queue survives quitting the app, and so do the hashes and Vision
answers, so only new and edited photos are analysed again. Deleted items stay in Recently Deleted for
30 days, where you can get them back, and they no longer count toward your iCloud storage: Apple says so in
[Manage your iCloud storage](https://support.apple.com/108922), and on the library this was built on the free
space rose as soon as items were deleted. So emptying Recently Deleted frees no iCloud space.

Drag photos onto another one to give them its date and time, a second after it. Changing dates: move a set so the earliest gets a date and the others keep their spacing, set an exact
date, shift by an amount, or read the date from the file name (`%Y%m%d_%H%M%S` reads
`IMG_20240714_183000`).

![Live Photos and Remove Motion](docs/live-photos.png)

## Install

Needs macOS 26 or later and Xcode. Open `Freedown.xcodeproj` and press Run, or from the terminal:

```
xcodebuild -project Freedown.xcodeproj -scheme Freedown -destination 'platform=macOS' -derivedDataPath build build
open build/Build/Products/Debug/Freedown.app
```

The unit tests (Swift Testing) run with `xcodebuild test` and the same arguments. They cover the arithmetic
and the file formats, and leave your library alone.

Set your own `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` in the target's build settings first. On
first launch macOS asks for access to Photos: choose Allow Full Access.

Shrinking videos also needs ffmpeg from Homebrew (`brew install ffmpeg`), which comes with libx265 and
libvmaf. Everything else works without it.

## How it works, and why

- **Sizes** come from each asset's resources (`PHAssetResource` and its `fileSize` key, which is not public
  API but the only way to know a size without downloading the file). Reading them costs a query per item,
  so they are cached between reloads.
- **iCloud storage by app** has no API. macOS's iCloud notification agent caches the answers of Apple's
  quota service in `~/Library/Caches/com.apple.iCloudNotificationAgent/Cache.db`, among them
  `getCloudStorageApps`: the numbers System Settings shows. The plan size follows from the share of the plan
  each app takes, and `brctl quota` gives the free space live, every minute. macOS refreshes the split by app
  only now and then, so the sidebar also shows what was freed since, and a running total of what Freedown
  itself freed, kept across launches in `~/Library/Application Support/Freedown/savings.json`. iCloud counts in powers of 1024
  (37,472,142,715 bytes show as "34.9 GB"), so the app does too.
- **Recently Deleted**: PhotoKit never shows deleted items to other apps, even through its private options, so
  Freedown reads their count and size from Photos' own database, read-only. macOS allows that only with Full
  Disk Access; without it, the sidebar offers to open the setting.
- **Similar shots** compare a 64-bit difference hash of a small render: one bit per pixel of a 9x8 grey
  thumbnail, set when it is brighter than its right neighbour. On a 7,000-item library, shots of the same
  moment differed by up to about 16 bits, different scenes by 20 to 40, even 3 seconds apart. Vision's
  feature print was measured too and dropped: it calls two framings of the same view "very close", and
  those are both worth keeping. The keeper is a favorite or edited shot first, then the best Vision
  aesthetics score.
- **Probably Accidental** asks Vision for each photo's aesthetics score (-1 to 1), once, and looks for a
  person, face, cat or dog in those under -0.6 that are not documents or receipts. Only photos with nobody
  in them are suggested, and never favorites or edited ones. On a 6,300-photo library that found 16, about
  half plainly accidental. The other lowest scores were dark or blurred photos of friends, which is why
  people rule a photo out. Darkness or blur alone did worse: they also catch the moon, city lights at night
  and sunsets.
- **Only Rotated** reads the edit Photos saves with each item: a property list around compressed JSON, whose
  adjustments (crop, light, filters…) can each be switched off. A rotation is kept apart from them, so an edit
  with every adjustment off only rotates, or changes nothing.
- **Remove Motion and Keep Edited Version** ask Photos for the item as it looks now (an unedited photo comes
  back as its original file, not re-encoded), save it as a new item with the same date, place, favorite and
  albums, and delete the old one in the same change. macOS asks once per batch of 200, and a batch you refuse
  leaves nothing behind. Remove Motion saves the still as a new file, with one extra metadata tag and no
  re-encoding: an unedited photo comes from Photos as its original file, and iCloud takes a byte-for-byte copy
  for the original and keeps its motion clip attached. Keep Edited Version saves an edited Live Photo's rendered still and motion
  together: Photos writes the same pairing id in both, so the new item is a Live Photo again.
- **Shrinking videos**: each video is exported from Photos as it looks now (a rotated or trimmed video keeps
  its edit; Photos stores those twice, so deleting the original frees both), re-encoded with libx265 (CRF 26, or 28 for
  "Smaller files", every frame kept at its original time), then scored with VMAF against the original
  (100 = identical). VMAF pairs frames by index: iPhone videos have an uneven frame rate, and pairing them by
  timestamp scores a perfect copy around 45. The copy goes into Photos only when it is at least 20% smaller
  and scores 93 or more (88 for "Smaller files"; the Shrink window changes that bar, remembered per preset); the originals go when you press Delete Originals. A copy
  refused only for its score waits in `~/Library/Caches/Freedown/Previews`: the Shrinking view plays it and
  the original in one player that switches between the two at the same moment, and saves it anyway if it
  looks fine. Apple's
  own HEVC encoder was tried and made iPhone videos bigger at the same quality. Expect savings on some videos
  only: iPhone footage is already well compressed.
- **Convert to HEIC** writes each JPEG again with ImageIO at quality 0.8, with its metadata. A HEIC replaces
  its JPEG only when it saves at least 20% and scores 97 or more out of 100: structural similarity (SSIM) of
  the grey pictures at 1024 pixels. JPEGs with an HDR gain map are left alone, since HEIC would drop that
  layer. Whether a JPEG gains depends on how hard its camera compressed it: on 1,526 of the library's JPEGs
  (mostly Pixel and OnePlus phones), those under 1.5 bits per pixel almost never passed (55 of 801, saving
  1 to 5%), half passed from 1.5 to 4 (saving 20% of the lot), and nearly all above 4 (saving 55%). So only
  JPEGs from 1.5 bits per pixel are listed, which kept 94% of the saving for half the work, the estimates
  use those measured shares, and a refused photo is remembered (`heic-refused.json`) and not offered again.
  The space freed is the size Photos reports for the new item once it exists, not the estimate.
- **What was freed** is read back from Photos after each replacement: the new item's files, not the expected
  size. iCloud's free space is also saved once an hour (`icloud-free.json`), so the history can set what
  Freedown counted against what iCloud really gained. It moves with everything else in iCloud too.
- **iCloud Drive** reads `~/Library/Mobile Documents`, which iCloud keeps in step: iCloud Drive itself
  (`com~apple~CloudDocs`) and one folder per app, named as Finder names them. Sizes are what iCloud stores,
  read from each file's size, so files only in iCloud count too. An app's files under its `Documents` folder
  are its iCloud Drive folder; anything else (WhatsApp's chat backup, for one) is the app's own data, listed
  but deleted from the app. Move to Trash takes a file out of iCloud Drive on every device. macOS keeps some
  files for the apps that made or opened them (the `com.apple.macl` mark, common on files that came from
  elsewhere) and refuses to let other apps trash them; Freedown then asks Finder, through `osascript`, and
  macOS asks once whether it may control Finder. Apple says
  files in iCloud Drive's Recently Deleted no longer count toward your storage
  ([Delete files in iCloud Drive](https://support.apple.com/guide/icloud/mm3b7fcd0c10/icloud)).
- **Clean Up** measures what the disk really holds (allocated blocks, or what `docker system df` says it can
  reclaim), and measures again after cleaning, so the freed figure is real. Caches are emptied but their
  folders kept, for tools and apps to fill again; Docker and Homebrew clean with their own commands; a
  browser's cache waits until it is quit. An app counts as unused when neither Spotlight nor a write to its own
  data (settings, saved windows, its folders) shows use for 60 days, and apps with a program running in the
  background (Karabiner, extensions) are left out. Apps go to the Trash, through Finder when an administrator
  installed them. Docker's unused volumes are named before they go, since their data is deleted for good. A bar on top splits what can be freed by group, and every line has a bar on the same scale. On request it
  also looks through the home folder for files and apps of 500 MB or more (about a minute), counting what
  the disk holds rather than the length a file claims (disk images are mostly empty), and leaving out what
  other lines cover, node_modules, git data and other apps' containers.
- **Half-Frame Scans** finds the dark strip of unexposed film between the two shots: columns near the middle
  that are near black while the shots on both sides are clearly brighter, so a night shot is not taken for a
  scan. Each half is cut out at full size and saved as HEIC with the scan's metadata, its turn written as an
  orientation rather than encoded again.
- **Open in Photos** uses a `photos-navigation://asset?uuid=` link. AppleScript's `spotlight` command
  crashes Photos on macOS 27.
- The app is not sandboxed (it reads that cache and runs `brctl` and ffmpeg), with the hardened runtime and
  the `com.apple.security.personal-information.photos-library` entitlement it needs to reach Photos. So it
  cannot go on the App Store as it is.

## Limits

- PhotoKit cannot change a photo's time zone: dates are picked on this Mac's clock.
- Items that are replaced (Remove Motion, Keep Edited Version, shrunk videos) keep their date, place,
  favorite and albums, but not titles, keywords or the names of people tagged in them.
- Shared albums are left out: they do not count against your iCloud storage.

## Files

| File | Role |
|---|---|
| `Freedown/Model/Library.swift` | the library as the app shows it: items, counts, marks, saved space |
| `Freedown/Model/LibraryScan.swift` | reading the library, the exact copies and the sidebar counts |
| `Freedown/Model/Library+Changes.swift` | every change: deletions, favorites, dates, replacements |
| `Freedown/Model/Item.swift` | an item and the files behind it |
| `Freedown/Model/Analysis.swift`, `Similar.swift`, `Subjects.swift`, `Accidental.swift` | similar shots and Vision, cached on disk |
| `Freedown/Model/Replacer.swift`, `Stills.swift` | Remove Motion, Keep Edited Version, Convert to HEIC |
| `Freedown/Model/Shrinker.swift`, `ShrinkPipeline.swift`, `ShrinkRecords.swift`, `FFmpeg.swift` | shrinking videos |
| `Freedown/Model/ICloudStorage.swift`, `RecentlyDeleted.swift` | iCloud storage by app, Recently Deleted |
| `Freedown/Model/ICloudDrive.swift` | the biggest files in iCloud Drive |
| `Freedown/Model/HalfFrame.swift` | finding and splitting half-frame scans |
| `Freedown/Model/Cleanup.swift`, `Finder.swift` | disk space on this Mac that can go, and asking Finder to trash |
| `Freedown/Model/Savings.swift` | the space Freedown freed and iCloud's free space, kept across launches |
| `Freedown/Model/Settings.swift` | the settings' names and the app's folders |
| `Freedown/Model/DateChange.swift` | date changes and reading dates from file names |
| `Freedown/Model/Destination.swift` | the sidebar entries and sort orders |
| `Freedown/Views/` | the SwiftUI views |
| `FreedownTests/` | the unit tests |

## License

[MIT](LICENSE)
