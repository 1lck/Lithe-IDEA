package buildinfo

import "strings"

// Lithe updates from one of two channels: the stable releases, which go through the release
// process, and AutoBuild, built from main every day. Each has its own signed feed. The channel a
// build was packaged for, when and from which commit, and the keys the feeds are signed with are
// set by package_info.go, which scripts/desktop/package-desktop.sh generates for the
// lithe_package_info build tag and removes once it has packaged (viva package takes no -ldflags).
// A build without a channel, a development or local build, never replaces itself.
const (
	ChannelStable    = "stable"
	ChannelAutoBuild = "autobuild"
)

// Channels are the update channels, in the order the settings list them.
var Channels = []string{ChannelStable, ChannelAutoBuild}

var (
	// Channel is the channel the build was packaged for: ChannelStable or ChannelAutoBuild.
	Channel string
	// BuildTime is when the build was packaged, in RFC 3339 and UTC.
	BuildTime string
	// Commit is the Git commit the build was packaged from.
	Commit string
	// UpdatePublicKeys are the Ed25519 keys a feed may be signed with, base64, separated by
	// commas, so a key can be rotated. Both channels and every feed address the user sets are
	// checked against them.
	UpdatePublicKeys string
	// StableFeedURL and AutoBuildFeedURL are the default feeds of the channels, on the official
	// repository's desktop-update-feed release. A fork that signs its own feeds sets them.
	StableFeedURL    = "https://github.com/1lck/Lithe-IDEA/releases/download/desktop-update-feed/stable.json"
	AutoBuildFeedURL = "https://github.com/1lck/Lithe-IDEA/releases/download/desktop-update-feed/autobuild.json"
	// DownloadsURL is where a user downloads Lithe by hand, for an installation that cannot
	// update itself.
	DownloadsURL = "https://github.com/1lck/Lithe-IDEA/releases"
)

// UpdateApp is the identifier the feed and the installed application carry.
const UpdateApp = "app.lithe.viva"

// InstalledChannel is the channel the running build was packaged for, empty for a development
// or local build, which does not update.
func InstalledChannel() string {
	if Development {
		return ""
	}
	return KnownChannel(Channel)
}

// KnownChannel is channel when it names one of the channels, else empty.
func KnownChannel(channel string) string {
	switch channel = strings.TrimSpace(channel); channel {
	case ChannelStable, ChannelAutoBuild:
		return channel
	}
	return ""
}

// ReleaseBase is version without its pre-release and build suffixes: the release an AutoBuild
// version, 0.7.0-autobuild.<time>, builds towards. An empty version stays empty.
func ReleaseBase(version string) string {
	if cut := strings.IndexAny(version, "-+"); cut >= 0 {
		version = version[:cut]
	}
	return version
}

// DefaultFeedURL is the feed a channel reads unless the user set another.
func DefaultFeedURL(channel string) string {
	if channel == ChannelAutoBuild {
		return AutoBuildFeedURL
	}
	return StableFeedURL
}
