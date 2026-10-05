# Mosaic privacy

Mosaic has no account, advertising, analytics SDK, or hosted media service. It does not upload a library to Mosaic or a model provider.

## Stored on this device

Mosaic saves Photos identifiers, file/folder bookmarks, filenames and basic metadata, collections, favorites, and playback positions in its application storage. Optional text recognition saves recognized text locally. Visual grouping saves small color/composition descriptors in a rebuildable cache. Normal iOS device backup rules apply to application metadata; caches are disposable.

The metadata archive uses iOS file protection until the first device unlock after restart. File reads and organization reject paths that escape a connected folder through traversal or symbolic links.

Original media remain where they are unless you explicitly confirm a batch in Auto organize’s Original files mode. Photos-library originals are never moved. Viewing can create thumbnails and temporary representations. Original media exported for sharing and S3 images downloaded for viewing use temporary storage, cleaned up when the viewer closes. Unexpected termination can leave temporary files until iOS or a later maintenance pass removes them.

Disconnecting a folder or forgetting a file removes its active reference from Mosaic, not the original. Collection/favorite identifiers may remain for disconnected or temporarily inaccessible sources. Clearing the text index removes recognized text; clearing the visual cache removes color/composition analysis.

## Permissions and discovery

Photos access may include all assets or a user-selected subset. Files and folders are accessed only after a system picker grant. iOS prevents scanning other apps’ private storage or unselected directories. Connected folder trees are scanned recursively on launch, foreground entry, or refresh.

## Network activity

Opening cloud-only Photos media can download it through Apple. A Files provider may fetch metadata or media from its service while listing a folder, generating a thumbnail, or opening a selected item. Its own authentication and privacy policies apply.

A configured S3 connection sends signed read requests directly to the specified HTTPS endpoint when browsing or opening objects. This can incur the provider’s usual request and transfer charges. Media is never relayed through a Mosaic server. S3 videos stream; images may download to temporary storage. No S3 object is uploaded, edited, or deleted.

S3 listing and image transfers use ephemeral network sessions without persistent URL caches, cookies, or credential storage. They reject redirects and enforce received-byte limits, including when the server omits Content-Length. Native video streaming is handled separately by AVKit.

S3 credentials are stored in Keychain with device-only accessibility after first unlock. They do not sync through iCloud Keychain. Disconnecting deletes the saved credentials. Nextcloud, Proton Drive, Google Drive, and iCloud provider credentials stay under their respective apps’ control.

## On-device analysis

Text recognition uses Apple Vision after an explicit Settings action. Visual grouping uses small local/cached thumbnails. Neither sends content to an external AI service. Sentiment uses filenames and optionally recognized text, not an inference about people in photos.

## Sharing

Sharing sends the chosen media through the destination selected in the system share sheet. That destination’s behavior and privacy terms apply.

Batch organization stores display-name overrides, collection memberships, and the inverse of the most recent batch locally so it can be undone. In the default In Mosaic mode, original filenames and folder locations are not changed. The separate Original files mode physically renames/moves files only inside connected folder grants after a preview and explicit confirmation. It stores source/destination references and a move journal locally for recovery and Undo. Provider moves may sync to the user’s cloud account.
