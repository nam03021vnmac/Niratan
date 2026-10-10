*Last updated: October 10 2026*
# Privacy Policy

Your data stays on your device unless you use the features below.

**PDF Reading and OCR** - Local PDFs are opened read-only. Japanese PDF text recognition runs on-device through Apple Vision and does not upload pages. The PDF catalog, reading positions and covers are stored in Application Support; bounded recognized-text caches are stored in Caches. Passwords are session-only; encrypted PDFs do not create persistent recognized-text or cover caches, and text extraction restrictions are respected. Removing a PDF from the library does not delete the original file. Dictionary audio and Anki actions invoked from PDF lookup follow the same services as other lookup surfaces.

**Google Drive Sync** - If enabled and when syncing a book, the book title, reading progress, statistics, and book cover can be uploaded to your Google Drive. The app can only access files that were created by the Google Cloud Project and cannot read any other files in your Drive. 

**Audio** - When you play word audio or have Anki audio export configured, the word and reading are sent to a Cloudflare Worker by default. The default audio source can be disabled, and additional user-configurable audio sources can be added.

**AnkiMobile** - When you export a word to AnkiMobile, user-configurable word data is shared via URL schemes.

**Manga Sources** - Suwayomi requests are sent to the server configured in the active Profile. User-installed Aidoku sources are third-party WebAssembly code and may request arbitrary HTTP(S) or local-network endpoints; Niratan shows this disclosure before installation and asks separately before allowing insecure HTTP or local-network source lists. Aidoku packages, settings, library, progress, and bounded caches are stored globally on-device. Login credentials, cookies, and opaque source-authored runtime values are stored in an Aidoku-specific Keychain service. Removing a source deletes its package, credentials, settings, and rebuildable cache while retaining library and progress records for recovery after reinstall.

**Third-Party Services** - Google Drive and Cloudflare are used as described above. Both services are governed by their respective privacy policies.

**Data Deletion** - Removing the Niratan `.app` does not automatically remove data kept in Application Support, preferences, caches, or Keychain. Niratan does not currently provide a single control that erases every local record. To remove the remaining data, quit Niratan, use Finder's **Go to Folder** to review and delete Niratan-owned files under `~/Library/Application Support` and `~/Library/Caches`, delete `~/Library/Preferences/moe.shishamo.hoshi.plist`, and remove Niratan-related credentials in Keychain Access (including services beginning with `moe.shishamo.hoshi` and Google Drive credential entries). Google Drive data must be deleted separately from Google Drive; using Google Drive's sign-out control removes the Google credentials stored by Niratan.

No analytics, tracking, or advertising is used.

For questions, open an issue on [GitHub](https://github.com/W1ght/Niratan/issues).
