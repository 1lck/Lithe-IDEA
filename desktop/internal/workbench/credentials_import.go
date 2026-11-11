package workbench

import (
	"context"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/credentials"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// This file holds the import of the plugin secrets an earlier Lithe client saved, which the
// user starts from the settings menu. The Viva client is a separate product that never reads
// those secrets on its own: the import copies each one it has no value for, once the user
// confirms, and leaves the earlier client's items as they are, since that client still uses
// them.

// credentialImportTimeout bounds an import. The platform may ask the user to allow reading
// each secret, so it waits as long as a sync does.
const credentialImportTimeout = syncTimeout

// credentialImportState is the import the user asked for: confirming says the dialog that
// explains it is open, and busy that it runs.
type credentialImportState struct {
	confirming, busy bool
}

// canImportCredentials says the settings menu offers the import: the plugin stack keeps its
// secrets in a store that can read an earlier client's on this platform.
func (a *App) canImportCredentials() bool {
	return a.plugins != nil && a.plugins.Credentials != nil && a.plugins.Credentials.CanImport()
}

// credentialImportItem declares the settings menu's item that starts the import, where the
// platform has an earlier client's secrets to read; it is disabled while the import runs.
func (a *App) credentialImportItem(c ui.C, menu *ui.MenuItems) {
	if !a.canImportCredentials() {
		return
	}
	busy := a.credentialImport.busy
	label := i18n.Shared(a.language(), "desktop.credentials.importLegacy")
	if busy {
		label = i18n.Shared(a.language(), "desktop.credentials.importLegacyBusy")
	}
	if menu.Item(label).Disabled(busy).Clicked() {
		c.After(a.confirmCredentialImport)
	}
}

// confirmCredentialImport opens the dialog that explains the import.
func (a *App) confirmCredentialImport() {
	if !a.canImportCredentials() || a.credentialImport.busy {
		return
	}
	a.credentialImport.confirming = true
}

// importLegacyCredentials runs the import the user confirmed and tells the user what it
// copied, kept and could not read. Only failing to list the earlier client's secrets fails
// it; that failure is logged with its status code, never a secret.
func (a *App) importLegacyCredentials() {
	in := &a.credentialImport
	in.confirming = false
	if !a.canImportCredentials() || in.busy {
		return
	}
	in.busy = true
	a.performed("credentials.import_legacy", surfaceButton)
	store := a.plugins.Credentials
	a.background(nil, credentialImportTimeout, func(ctx context.Context) func(*App) {
		result, err := store.ImportLegacy(ctx)
		return func(a *App) {
			a.credentialImport.busy = false
			lang := a.language()
			switch {
			case err != nil:
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("credentials_import_legacy", err))
				a.notify(i18n.SharedFormat(lang, "desktop.credentials.importLegacyFailed", map[string]string{"error": err.Error()}))
			case result == credentials.ImportResult{}:
				a.notify(i18n.Shared(lang, "desktop.credentials.importLegacyNone"))
			default:
				a.notify(i18n.SharedFormat(lang, "desktop.credentials.importLegacyDone", map[string]string{
					"imported": strconv.Itoa(result.Imported),
					"kept":     strconv.Itoa(result.Kept),
					"failed":   strconv.Itoa(result.Failed),
				}))
			}
		}
	})
}

// credentialImportView declares the dialog that explains the import before it runs.
func (a *App) credentialImportView(c ui.C) {
	in := &a.credentialImport
	if !in.confirming {
		return
	}
	lang := a.language()
	confirmed, cancelled := false, false
	closed := ui.ModalWith(c, &in.confirming, i18n.Shared(lang, "desktop.credentials.importLegacyTitle"),
		ui.ModalSpec{Width: 460}, func() {
			ui.Wrap(c, i18n.Shared(lang, "desktop.credentials.importLegacyDescription")).FontSize(12).Muted()
		}, func() {
			cancelled = ui.Button(c, i18n.Shared(lang, "desktop.gitReview.cancel")).Outline().Clicked()
			confirmed = ui.Button(c, i18n.Shared(lang, "desktop.credentials.importLegacyConfirm")).AutoFocus().Clicked()
		})
	switch {
	case confirmed:
		c.After(a.importLegacyCredentials)
	case closed || cancelled:
		in.confirming = false
	}
}
