package settingswindow

import (
	"fmt"
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildinfo"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// updatesPage is the About page's update card of a build packaged for installed, showing
// status as the test changes it, and recording what the card asked the updater to do.
type updatesPage struct {
	status   UpdateStatus
	switches []string
	sources  []string
	shown    int
	updates  int
}

func newUpdatesPage(t *testing.T, version string, status UpdateStatus) (*updatesPage, *windowDriver) {
	t.Helper()
	p := &updatesPage{status: status}
	if p.status.Channel == "" {
		p.status.Channel = p.status.Installed
	}
	p.status.Sources = nil
	for _, channel := range buildinfo.Channels {
		p.status.Sources = append(p.status.Sources, UpdateSource{Channel: channel, URL: buildinfo.DefaultFeedURL(channel)})
	}
	w := newWindow(NewController(Options{
		Version:      version,
		UpdateStatus: func() UpdateStatus { return p.status },
		UpdateNow:    func() { p.updates++ },
		ShowUpdate:   func() { p.shown++ },
		SetUpdateChannel: func(channel string, now, restore bool) {
			p.switches = append(p.switches, fmt.Sprintf("%s now=%v restore=%v", channel, now, restore))
			p.status.Channel = channel
		},
		SetUpdateSource: func(channel, address string) {
			p.sources = append(p.sources, channel+" "+address)
			for i := range p.status.Sources {
				if p.status.Sources[i].Channel == channel {
					p.status.Sources[i].Custom = address != ""
					p.status.Sources[i].URL = buildinfo.DefaultFeedURL(channel)
					if address != "" {
						p.status.Sources[i].URL = address
					}
				}
			}
		},
	}), Values{})
	w.sess.page = pageAbout
	return p, openWindow(t, w)
}

// showsWrapped reports whether the frame shows text, which may wrap over lines: the lines of
// the frame, joined with the space each break took, contain it.
func (d *windowDriver) showsWrapped(text string) bool {
	var lines []string
	for _, run := range d.driver.Snapshot().Texts {
		lines = append(lines, run.Value)
	}
	return strings.Contains(strings.Join(lines, " "), text)
}

// pick chooses channel in the page's channel list, by the entry the list shows for it.
func (d *windowDriver) pick(channel string) {
	d.t.Helper()
	d.click(i18n.Shared(i18n.English, "desktop.settings.updates.channel"))
	d.click(channelEntry(i18n.English, channel, d.w.ctrl.opts.UpdateStatus().Installed))
	d.pump()
}

// TestChannelListMarksTheBuildsOwnChannelAutomatic shows a stable build following its own
// channel: the list reads Automatic (Stable) and offers AutoBuild by name. Once the user has
// switched to AutoBuild, the list shows that explicit choice and no Automatic entry as the value.
func TestChannelListMarksTheBuildsOwnChannelAutomatic(t *testing.T) {
	_, d := newUpdatesPage(t, "0.7.0", UpdateStatus{Configured: true, Installed: buildinfo.ChannelStable, UpToDate: true})
	automatic := i18n.SharedFormat(i18n.English, "desktop.settings.updates.channelFollowsBuild", map[string]string{
		"channel": ChannelName(i18n.English, buildinfo.ChannelStable),
	})
	if automatic != "Automatic (Stable)" {
		t.Fatalf("the build's own channel reads %q, want Automatic (Stable)", automatic)
	}
	if !d.showsWrapped(automatic) {
		t.Fatalf("a build following its own channel shows no %q", automatic)
	}

	d.pick(buildinfo.ChannelAutoBuild)
	d.click(i18n.Shared(i18n.English, "desktop.settings.updates.toAutoBuild.confirm"))
	d.pump()
	if d.showsWrapped(automatic) {
		t.Fatalf("after switching to AutoBuild the list still shows %q as the value", automatic)
	}
	d.click(i18n.Shared(i18n.English, "desktop.settings.updates.channel"))
	d.pump()
	if !d.has(automatic) || !d.has(ChannelName(i18n.English, buildinfo.ChannelAutoBuild)) {
		t.Fatalf("the open list has %q = %v and AutoBuild = %v, want both entries",
			automatic, d.has(automatic), d.has(ChannelName(i18n.English, buildinfo.ChannelAutoBuild)))
	}
}

// TestSwitchingToAutoBuildAsksFirst picks AutoBuild on a stable build: a dialog says what
// AutoBuild is, Cancel keeps stable, and Confirm switches without anything else.
func TestSwitchingToAutoBuildAsksFirst(t *testing.T) {
	p, d := newUpdatesPage(t, "0.7.0", UpdateStatus{Configured: true, Installed: buildinfo.ChannelStable, UpToDate: true})
	title := i18n.Shared(i18n.English, "desktop.settings.updates.toAutoBuild.title")

	d.pick(buildinfo.ChannelAutoBuild)
	if !d.text(title) || len(p.switches) != 0 {
		t.Fatalf("picking AutoBuild shows the dialog %v and switched %v, want the dialog alone", d.text(title), p.switches)
	}
	d.click(d.w.text.Settings.Cancel)
	d.pump()
	if d.text(title) || len(p.switches) != 0 {
		t.Fatalf("Cancel left the dialog %v and switched %v, want neither", d.text(title), p.switches)
	}

	d.pick(buildinfo.ChannelAutoBuild)
	d.click(i18n.Shared(i18n.English, "desktop.settings.updates.toAutoBuild.confirm"))
	d.pump()
	if want := []string{"autobuild now=false restore=false"}; !slices.Equal(p.switches, want) || d.text(title) {
		t.Fatalf("Confirm switched %v with the dialog %v, want %v and the dialog closed", p.switches, d.text(title), want)
	}
}

// TestBackToStableWaitsOrSwitchesNow takes an AutoBuild build back to stable: the dialog
// offers to wait for the next stable release or take the latest at once, and to bring back the
// settings kept of stable, which stays off unless the user ticks it. Picking the build's own
// channel switches at once.
func TestBackToStableWaitsOrSwitchesNow(t *testing.T) {
	p, d := newUpdatesPage(t, "0.8.0-autobuild.20261116", UpdateStatus{
		Configured: true, Installed: buildinfo.ChannelAutoBuild, UpToDate: true, Restorable: []string{buildinfo.ChannelStable},
	})
	body := i18n.SharedFormat(i18n.English, "desktop.settings.updates.toStable.body", map[string]string{"version": "0.8.0"})
	restore := i18n.SharedFormat(i18n.English, "desktop.settings.updates.restore", map[string]string{
		"channel": ChannelName(i18n.English, buildinfo.ChannelStable),
	})

	d.pick(buildinfo.ChannelStable)
	if !d.showsWrapped(body) || !d.has(restore) {
		t.Fatalf("the dialog says %q = %v with the restore box %v, want both", body, d.showsWrapped(body), d.has(restore))
	}
	d.click(i18n.Shared(i18n.English, "desktop.settings.updates.toStable.wait"))
	d.pump()

	d.pick(buildinfo.ChannelAutoBuild)
	d.pick(buildinfo.ChannelStable)
	d.click(restore)
	d.pump()
	d.click(i18n.Shared(i18n.English, "desktop.settings.updates.toStable.now"))
	d.pump()
	want := []string{"stable now=false restore=false", "autobuild now=false restore=false", "stable now=true restore=true"}
	if !slices.Equal(p.switches, want) {
		t.Fatalf("the switches were %v, want %v", p.switches, want)
	}
}

// TestUpdateSourceSavesAndResets edits the channel's feed: an address that is not HTTPS is
// refused with a word, a good one is saved, and Reset puts the default back.
func TestUpdateSourceSavesAndResets(t *testing.T) {
	p, d := newUpdatesPage(t, "0.7.0", UpdateStatus{Configured: true, Installed: buildinfo.ChannelStable, UpToDate: true})
	field := i18n.SharedFormat(i18n.English, "desktop.settings.updates.source", map[string]string{
		"channel": ChannelName(i18n.English, buildinfo.ChannelStable),
	})
	save := i18n.Shared(i18n.English, "desktop.settings.updates.sourceSave")
	reset := i18n.Shared(i18n.English, "desktop.settings.updates.sourceReset")
	enter := func(address string) {
		t.Helper()
		d.click(field)
		if err := d.driver.SelectText(0, len([]rune(d.w.updates.source.Text()))); err != nil {
			t.Fatal(err)
		}
		d.typeText(address)
		d.pump()
	}
	if !d.text(i18n.SharedFormat(i18n.English, "desktop.settings.updates.sourceDefault", map[string]string{"repo": "1lck/Lithe-IDEA"})) {
		t.Fatal("the default feed is not said to be the project's")
	}
	if d.has(reset) {
		t.Fatal("the default feed offers Reset")
	}

	enter("http://feeds.example.com/stable.json")
	if !d.text(i18n.Shared(i18n.English, "desktop.settings.updates.sourceInvalid")) {
		t.Fatal("an address that is not HTTPS is not refused")
	}
	d.click(save)
	d.pump()
	if len(p.sources) != 0 {
		t.Fatalf("Save took the refused address: %v", p.sources)
	}

	enter("https://feeds.example.com/stable.json")
	d.click(save)
	d.pump()
	d.click(reset)
	d.pump()
	want := []string{"stable https://feeds.example.com/stable.json", "stable "}
	if !slices.Equal(p.sources, want) || d.w.updates.source.Text() != buildinfo.DefaultFeedURL(buildinfo.ChannelStable) {
		t.Fatalf("the sources set were %v and the field reads %q, want %v and the default back", p.sources, d.w.updates.source.Text(), want)
	}
}

// TestViewChangesOpensTheUpdateDialog finds a version on the page: its button opens the
// update dialog, which says what changed, instead of downloading it.
func TestViewChangesOpensTheUpdateDialog(t *testing.T) {
	p, d := newUpdatesPage(t, "0.7.0", UpdateStatus{Configured: true, Installed: buildinfo.ChannelStable, Available: "0.8.0"})
	d.click(i18n.Shared(i18n.English, "desktop.updates.viewChanges"))
	d.pump()
	if p.shown != 1 || p.updates != 0 {
		t.Fatalf("View Changes opened the dialog %d times and downloaded %d times, want the dialog once", p.shown, p.updates)
	}
}
