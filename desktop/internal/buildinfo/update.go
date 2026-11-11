package buildinfo

// The update feed a release build checks, set at link time
// (-X github.com/1lck/Lithe-IDEA/desktop/internal/buildinfo.UpdateFeedURL=...). A build
// without them does not check for updates: development and local builds never replace
// themselves.
var (
	// UpdateFeedURL is the HTTPS address of the signed latest.json.
	UpdateFeedURL string
	// UpdatePublicKeys are the Ed25519 keys the feed may be signed with, base64,
	// separated by commas, so a key can be rotated.
	UpdatePublicKeys string
	// UpdateChannel is the release channel the build follows, such as "stable".
	UpdateChannel string
)

// UpdateApp is the identifier the feed and the installed application carry.
const UpdateApp = "app.lithe.viva"
