package pluginservice

import (
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

type viewRefreshBinding struct {
	pluginID, sessionID, contextID string
	wake                           func()
}
type viewRefreshRegistry struct {
	mu         sync.Mutex
	byInstance map[string]*viewRefreshBinding
}

// WatchView registers a thread-safe invalidation callback for one visible view.
func (s *Service) WatchView(pluginID, instance string, wake func()) func() {
	s.viewRefresh.mu.Lock()
	if s.viewRefresh.byInstance == nil {
		s.viewRefresh.byInstance = map[string]*viewRefreshBinding{}
	}
	binding := &viewRefreshBinding{pluginID: pluginID, wake: wake}
	s.viewRefresh.byInstance[instance] = binding
	s.viewRefresh.mu.Unlock()
	return func() {
		s.viewRefresh.mu.Lock()
		if s.viewRefresh.byInstance[instance] == binding {
			delete(s.viewRefresh.byInstance, instance)
		}
		s.viewRefresh.mu.Unlock()
	}
}
func (s *Service) bindView(pluginID, sessionID, contextID, instance string) {
	s.viewRefresh.mu.Lock()
	defer s.viewRefresh.mu.Unlock()
	if binding := s.viewRefresh.byInstance[instance]; binding != nil && binding.pluginID == pluginID {
		binding.sessionID = sessionID
		binding.contextID = contextID
	}
}
func (s *Service) refreshView(caller pluginhost.Caller, contextID, instance string) bool {
	s.viewRefresh.mu.Lock()
	binding := s.viewRefresh.byInstance[instance]
	if binding == nil || binding.pluginID != caller.PluginID || binding.sessionID != caller.SessionID || binding.contextID != contextID {
		s.viewRefresh.mu.Unlock()
		return false
	}
	s.viewRefresh.mu.Unlock()
	binding.wake()
	return true
}
