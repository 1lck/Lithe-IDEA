package pluginservice

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/credentials"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

// The credential methods of protocol version 2. They are granted by the
// credentials.store permission, which a launch plan lists as the service-level
// grant "credentials". Core has already checked the permission, the key alphabet
// and the size of the secret; the handlers repeat the cheap checks because the
// platform store must never see a malformed item.
const (
	grantCredentials = "credentials"

	methodCredentialsGet    = pluginhost.MethodPrefix + "credentials/get"
	methodCredentialsSet    = pluginhost.MethodPrefix + "credentials/set"
	methodCredentialsDelete = pluginhost.MethodPrefix + "credentials/delete"
)

type credentialParams struct {
	Key    string `json:"key"`
	Secret string `json:"secret"`
}

func (s *Service) registerCredentials() error {
	for _, entry := range []struct {
		method  string
		handler pluginhost.Handler
	}{
		{methodCredentialsGet, s.handleCredentialsGet},
		{methodCredentialsSet, s.handleCredentialsSet},
		{methodCredentialsDelete, s.handleCredentialsDelete},
	} {
		if err := s.HostServices.Register(entry.method, entry.handler); err != nil {
			return err
		}
	}
	return s.HostServices.GrantService(grantCredentials)
}

// credentialRequest decodes the params and finds the caller, whose plugin ID is
// the namespace the secret lives in.
func credentialRequest(ctx context.Context, params json.RawMessage) (string, credentialParams, *pluginhost.Failure) {
	var request credentialParams
	caller, ok := pluginhost.CallerFrom(ctx)
	if !ok {
		return "", request, failure(pluginhost.CodeHostFailure, "the request has no calling plugin")
	}
	if err := decodeStrict(params, &request); err != nil {
		return "", request, invalidParams(err)
	}
	return caller.PluginID, request, nil
}

// credentialFailure maps a store error. It never quotes the key or the secret.
func credentialFailure(err error) *pluginhost.Failure {
	switch {
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return failure(pluginhost.CodeCancelled, "The request was cancelled.")
	case errors.Is(err, credentials.ErrInvalid):
		return invalidParams(err)
	case errors.Is(err, credentials.ErrTooLarge):
		return failure("plugin.host.limitExceeded", "The platform secret store cannot hold a secret this large.")
	}
	return failure(pluginhost.CodeHostFailure, "The platform secret store failed.")
}

func (s *Service) handleCredentialsGet(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	pluginID, request, refusal := credentialRequest(ctx, params)
	if refusal != nil {
		return nil, refusal
	}
	secret, found, err := s.Credentials.Get(ctx, pluginID, request.Key)
	if err != nil {
		return nil, credentialFailure(err)
	}
	if !found {
		return nil, nil
	}
	return marshalResult(map[string]string{"secret": secret})
}

func (s *Service) handleCredentialsSet(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	pluginID, request, refusal := credentialRequest(ctx, params)
	if refusal != nil {
		return nil, refusal
	}
	if err := s.Credentials.Set(ctx, pluginID, request.Key, request.Secret); err != nil {
		return nil, credentialFailure(err)
	}
	return nil, nil
}

func (s *Service) handleCredentialsDelete(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	pluginID, request, refusal := credentialRequest(ctx, params)
	if refusal != nil {
		return nil, refusal
	}
	if err := s.Credentials.Delete(ctx, pluginID, request.Key); err != nil {
		return nil, credentialFailure(err)
	}
	return nil, nil
}
