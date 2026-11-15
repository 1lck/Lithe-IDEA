package githubapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// ErrDeviceExpired reports that the device code expired before the user authorized it.
var ErrDeviceExpired = errors.New("github: the device authorization expired")

// ErrDeviceDenied reports that the user refused the authorization on GitHub.
var ErrDeviceDenied = errors.New("github: the device authorization was denied")

// Transitioner is the part of Rust Core the device flow asks what to do next. *core.Client
// implements it.
type Transitioner interface {
	GitHubDeviceTransition(ctx context.Context, request core.DeviceTransitionRequest) (core.DeviceTransition, error)
}

// StartDevice asks GitHub for a device code. The caller keeps the time it started at and passes it
// to AwaitDevice, so the deadline counts the request's own latency too.
func (c *Client) StartDevice(ctx context.Context, clientID string) (DeviceCode, error) {
	raw, err := c.Do(ctx, core.GitHubRequest{Operation: "deviceCode", ClientID: clientID}, "")
	if err != nil {
		return DeviceCode{}, err
	}
	var code DeviceCode
	if err := json.Unmarshal(raw, &code); err != nil || code.DeviceCode == "" {
		return DeviceCode{}, errors.New("github: invalid device authorization response")
	}
	return code, nil
}

// AwaitDevice polls GitHub until the user authorizes the code and returns the access token. Core
// decides each step from the monotonic time elapsed since started, the server's interval and any
// slow_down answer; the host only sleeps and sends the planned requests. Cancelling ctx stops it.
// waiting is told each time the flow sleeps, so the UI can show it is still waiting.
func (c *Client) AwaitDevice(ctx context.Context, transitions Transitioner, clientID string, code DeviceCode, started time.Time, waiting func()) (string, error) {
	event := "start"
	interval := code.Interval
	var suggested *uint64
	var accessToken, message string
	for {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		step, err := transitions.GitHubDeviceTransition(ctx, core.DeviceTransitionRequest{
			Event:               event,
			ExpiresIn:           code.ExpiresIn,
			Interval:            interval,
			ElapsedMilliseconds: uint64(time.Since(started).Milliseconds()),
			SuggestedInterval:   suggested,
		})
		if err != nil {
			return "", err
		}
		interval = step.IntervalSeconds
		switch step.Action {
		case "wait":
			if waiting != nil {
				waiting()
			}
			if err := sleepContext(ctx, time.Duration(step.WaitMilliseconds)*time.Millisecond); err != nil {
				return "", err
			}
			event = "tick"
		case "poll":
			raw, err := c.Do(ctx, core.GitHubRequest{Operation: "deviceToken", ClientID: clientID, DeviceCode: code.DeviceCode}, "")
			if err != nil {
				return "", err
			}
			var answer deviceTokenResponse
			if err := json.Unmarshal(raw, &answer); err != nil {
				return "", errors.New("github: invalid device token response")
			}
			suggested = answer.Interval
			event = answer.Status
			if answer.AccessToken != "" {
				accessToken = answer.AccessToken
			}
			if answer.Message != nil {
				message = *answer.Message
			} else {
				message = answer.Error
			}
		case "authorize":
			if accessToken == "" {
				return "", errors.New("github: the authorization returned no token")
			}
			return accessToken, nil
		case "expired":
			return "", ErrDeviceExpired
		case "denied":
			return "", ErrDeviceDenied
		default:
			if message == "" {
				message = "unknown error"
			}
			return "", fmt.Errorf("github: device authorization failed: %s", message)
		}
	}
}

// sleepContext waits for d, or until ctx ends.
func sleepContext(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		return ctx.Err()
	}
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
