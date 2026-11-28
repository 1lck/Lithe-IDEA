package workbench

import (
	"strconv"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

func TestGraphArrowTipCacheReusesLabelsAcrossFrames(t *testing.T) {
	var tips logGraphArrowTips
	commit := core.GitCommit{Hash: "target", Subject: "subject", AuthorName: "author"}
	const date = "2026/11/28 12:00"
	tips.beginFrame()
	key, label := testArrowTipLabel(&tips, i18n.English, commit, date, 0)
	tips.endFrame()
	if key == "" || !strings.Contains(label, commit.Subject) || !strings.Contains(label, commit.AuthorName) || !strings.Contains(label, date) {
		t.Fatalf("incomplete arrow label %q for key %q", label, key)
	}
	if count := testing.AllocsPerRun(100, func() {
		tips.beginFrame()
		testArrowTipLabel(&tips, i18n.English, commit, date, 0)
		tips.endFrame()
	}); count != 0 {
		t.Fatalf("warm arrow label allocated %g times", count)
	}
	tips.beginFrame()
	localizedKey, localized := testArrowTipLabel(&tips, i18n.Chinese, commit, date, 0)
	if localizedKey != key || localized == label {
		t.Fatalf("language update changed identity or left stale text: %q / %q", localizedKey, localized)
	}
	commit.Subject = "changed subject"
	commit.AuthorName = "changed author"
	const newDate = "2026/11/29 07:00"
	metadataKey, metadataLabel := testArrowTipLabel(&tips, i18n.Chinese, commit, newDate, 0)
	if metadataKey != key || !strings.Contains(metadataLabel, commit.Subject) || !strings.Contains(metadataLabel, commit.AuthorName) || !strings.Contains(metadataLabel, newDate) {
		t.Fatalf("metadata update changed identity or left stale text: %q / %q", metadataKey, metadataLabel)
	}
	tips.endFrame()
}

func TestGraphArrowTipCacheRetainsOnlyCurrentFrameTargets(t *testing.T) {
	var tips logGraphArrowTips
	const date = "2026/11/28 12:00"
	target := core.GitCommit{Hash: "target"}
	tips.beginFrame()
	key, _ := testArrowTipLabel(&tips, i18n.English, target, date, 0)
	testArrowTipLabel(&tips, i18n.English, core.GitCommit{Hash: "still visible"}, date, 1)
	tips.endFrame()

	tips.beginFrame()
	testArrowTipLabel(&tips, i18n.English, core.GitCommit{Hash: "still visible"}, date, 1)
	testArrowTipLabel(&tips, i18n.English, core.GitCommit{Hash: "new arrival"}, date, 2)
	tips.endFrame()
	if len(tips.byCommit) != 2 || tips.byCommit[logCommitIdentity{hash: target.Hash}] != nil || tips.byCommit[logCommitIdentity{hash: "still visible"}] == nil || tips.byCommit[logCommitIdentity{hash: "new arrival"}] == nil {
		t.Fatalf("cache did not follow the visible targets: %v", tips.byCommit)
	}

	tips.beginFrame()
	tips.endFrame()
	if tips.byCommit != nil {
		t.Fatal("an empty frame should release the entire arrow cache")
	}

	tips.beginFrame()
	if reentered, _ := testArrowTipLabel(&tips, i18n.English, target, date, 0); reentered != key {
		t.Fatalf("reentered arrow key = %q, want %q", reentered, key)
	}
	tips.endFrame()
}

func TestGraphArrowTipCacheBoundsCrowdedFramesAndAllowsReset(t *testing.T) {
	var tips logGraphArrowTips
	const date = "2026/11/28 12:00"
	tips.beginFrame()
	for i := range logRowSlots {
		testArrowTipLabel(&tips, i18n.English, core.GitCommit{Hash: strconv.Itoa(i)}, date, 0)
	}
	overflow := core.GitCommit{Hash: "overflow", Subject: "shown without caching"}
	key, label := testArrowTipLabel(&tips, i18n.English, overflow, date, 3)
	if key == "" || !strings.Contains(label, overflow.Subject) || len(tips.byCommit) != logRowSlots || tips.byCommit[logCommitIdentity{hash: overflow.Hash}] != nil {
		t.Fatalf("crowded frame produced %q / %q with %d cached targets", key, label, len(tips.byCommit))
	}

	// Opening another project can reset the log view between beginFrame and endFrame.
	tips = logGraphArrowTips{}
	if entered, _ := testArrowTipLabel(&tips, i18n.English, overflow, date, 3); entered != key {
		t.Fatalf("arrow key after project reset = %q, want %q", entered, key)
	}
	tips.endFrame()
	if len(tips.byCommit) != 1 || tips.byCommit[logCommitIdentity{hash: overflow.Hash}] == nil {
		t.Fatal("old project targets survived a reset or new target was dropped")
	}
}
func testArrowTipLabel(tips *logGraphArrowTips, language i18n.Language, commit core.GitCommit, date string, variant int) (string, string) {
	return tips.label(logCommitIdentity{hash: commit.Hash}, language, commit, date, variant)
}
