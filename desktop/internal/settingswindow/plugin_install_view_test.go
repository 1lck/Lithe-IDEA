package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"testing"
)

func TestPluginInstallReviewStaysInSettingsAndHidesTechnicalDetails(t *testing.T) {
	status := PluginInstallStatus{Token: 7, Review: true, Name: "Sample", Version: "1.0.0", Permissions: []string{"process.build"}, Programs: []string{`{"kind":"runtime","command":"sample-tool"}`}}
	var confirmed uint64
	w := newWindow(NewController(Options{PluginInstall: func() PluginInstallStatus { return status }, ConfirmPluginInstall: func(token uint64) { confirmed = token }}), Values{})
	d := openWindow(t, w)
	if !d.text(permissionDescription(i18n.English, "process.build")) {
		t.Fatal("missing readable permission")
	}
	if len(w.installDialog.lines) != 0 {
		t.Fatal("technical declarations were materialized before disclosure")
	}
	label := i18n.SharedFormat(i18n.English, "desktop.marketplace.programDetails", map[string]string{"count": "1"})
	d.click(label)
	if !w.installDialog.details || len(w.installDialog.lines) == 0 {
		t.Fatal("program details did not open")
	}
	d.click(i18n.Shared(i18n.English, "desktop.marketplace.confirmInstall"))
	if confirmed != 7 {
		t.Fatalf("confirmation token = %d", confirmed)
	}
}

func TestPluginInstallProgressCanCancelFromSettings(t *testing.T) {
	status := PluginInstallStatus{Token: 9, Busy: true, Phase: "download", Received: 1 << 20, Total: 2 << 20, Name: "Sample"}
	var cancelled uint64
	w := newWindow(NewController(Options{PluginInstall: func() PluginInstallStatus { return status }, CancelPluginInstall: func(token uint64) { cancelled = token }}), Values{})
	d := openWindow(t, w)
	if !d.text("1.0 / 2.0 MiB") {
		t.Fatal("missing byte progress")
	}
	if d.has(i18n.Shared(i18n.English, "desktop.marketplace.confirmInstall")) {
		t.Fatal("download can be approved before verification")
	}
	d.click(i18n.Shared(i18n.English, "desktop.marketplace.cancel"))
	if cancelled != 9 {
		t.Fatalf("cancel token = %d", cancelled)
	}
}

func TestPluginInstallAfterCancelDoesNotReuseDismissedDialog(t *testing.T) {
	status := PluginInstallStatus{Token: 1, Review: true, Name: "Sample"}
	var cancelled []uint64
	w := newWindow(NewController(Options{PluginInstall: func() PluginInstallStatus { return status }, CancelPluginInstall: func(token uint64) { cancelled = append(cancelled, token); status = PluginInstallStatus{} }}), Values{})
	d := openWindow(t, w)
	d.click(i18n.Shared(i18n.English, "desktop.marketplace.cancel"))
	d.pump()
	status = PluginInstallStatus{Token: 3, Busy: true, Phase: "download", Name: "Another", Total: -1}
	for i := 0; i < 3; i++ {
		d.w.inv.Invalidate()
		d.pump()
	}
	if len(cancelled) != 1 || cancelled[0] != 1 {
		t.Fatalf("dismissed dialog cancelled a later transfer: %v", cancelled)
	}
	if !d.has(i18n.Shared(i18n.English, "desktop.marketplace.cancel")) {
		t.Fatal("new transfer has no cancel button")
	}
}

func TestPluginInstallConnectingExplainsTheInitialWait(t *testing.T) {
	status := PluginInstallStatus{Token: 1, Busy: true, Phase: "connect", Name: "Sample", Version: "1.0.0", Total: -1}
	w := newWindow(NewController(Options{PluginInstall: func() PluginInstallStatus { return status }}), Values{})
	d := openWindow(t, w)
	if !d.text(i18n.Shared(i18n.English, "desktop.marketplace.connecting")) {
		t.Fatal("initial network wait has no explanation")
	}
	if d.text("0.0 MiB downloaded") {
		t.Fatal("connecting was presented as an active body transfer")
	}
	if d.has(i18n.Shared(i18n.English, "desktop.marketplace.confirmInstall")) {
		t.Fatal("connection phase offered an installation confirmation")
	}
	status = PluginInstallStatus{Token: 1, Review: true, Name: "Sample", Version: "1.0.0"}
	d.w.inv.Invalidate()
	d.pump()
	if !d.has(i18n.Shared(i18n.English, "desktop.marketplace.confirmInstall")) {
		t.Fatal("verified package has no confirmation")
	}
}

func TestPluginInstallFailureOffersRetry(t *testing.T) {
	status := PluginInstallStatus{Token: 13, Failed: true, Name: "Sample", Failure: "Download timed out"}
	var retried uint64
	w := newWindow(NewController(Options{PluginInstall: func() PluginInstallStatus { return status }, RetryPluginInstall: func(token uint64) { retried = token }}), Values{})
	d := openWindow(t, w)
	if !d.has(i18n.Shared(i18n.English, "ui.retry")) {
		t.Fatal("failed installation has no retry action")
	}
	if !d.text(status.Failure) {
		t.Fatal("failure reason is missing")
	}
	d.click(i18n.Shared(i18n.English, "ui.retry"))
	if retried != 13 {
		t.Fatalf("retry token = %d", retried)
	}
}

func TestPluginInstallCompletionCanBeDismissed(t *testing.T) {
	status := PluginInstallStatus{Token: 14, Completed: true, Name: "Sample"}
	var dismissed uint64
	w := newWindow(NewController(Options{PluginInstall: func() PluginInstallStatus { return status }, CancelPluginInstall: func(token uint64) { dismissed = token }}), Values{})
	d := openWindow(t, w)
	if !d.text(i18n.Shared(i18n.English, "desktop.marketplace.installCompleteHelp")) {
		t.Fatal("installation ended without a result")
	}
	if d.has(i18n.Shared(i18n.English, "ui.retry")) {
		t.Fatal("successful installation offers retry")
	}
	d.click(i18n.Shared(i18n.English, "ui.done"))
	if dismissed != 14 {
		t.Fatalf("dismiss token = %d", dismissed)
	}
}
