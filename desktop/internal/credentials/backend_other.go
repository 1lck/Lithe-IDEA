//go:build !darwin

package credentials

import (
	"errors"

	"github.com/zalando/go-keyring"
)

// keyringBackend is the Windows Credential Manager or the Linux Secret Service
// (through D-Bus), whichever go-keyring selects for the platform.
type keyringBackend struct{}

func platformBackend() Backend { return keyringBackend{} }

// platformLegacy is nil: the older Windows client stored no plugin credentials
// (its backend service was never advertised), and Linux has no older client.
func platformLegacy() Legacy { return nil }

func (keyringBackend) Get(service, account string) (string, error) {
	secret, err := keyring.Get(service, account)
	return secret, mapKeyringError(err)
}

func (keyringBackend) Set(service, account, secret string) error {
	return mapKeyringError(keyring.Set(service, account, secret))
}

func (keyringBackend) Delete(service, account string) error {
	return mapKeyringError(keyring.Delete(service, account))
}

func mapKeyringError(err error) error {
	switch {
	case err == nil:
		return nil
	case errors.Is(err, keyring.ErrNotFound):
		return ErrNotFound
	case errors.Is(err, keyring.ErrSetDataTooBig):
		return ErrTooLarge
	}
	return err
}
