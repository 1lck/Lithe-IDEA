package workbench

import (
	"context"
	"errors"
	"io"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

func remoteDebugUntrusted() error {
	return &core.MarketplaceRejection{Code: core.LaunchUntrustedWorkspace}
}

type debugForward struct {
	host    string
	port    int
	release func(context.Context) error
}

func (a *App) forwardDebugEndpoint(ctx context.Context, connection *core.RemoteWorkspaceConnection, host string, port int, confirmed bool) (debugForward, error) {
	sessionID := connection.SessionID()
	if sessionID == "" {
		return debugForward{}, errRemoteSessionClosed
	}
	forward, created, err := a.kernel.RemoteStartForward(ctx, sessionID, core.RemoteForwardTarget{
		Host: host, Port: uint16(port), AllowNonLoopback: confirmed,
	})
	if err != nil {
		return debugForward{}, err
	}
	local := debugForward{host: forward.LocalHost, port: int(forward.LocalPort)}
	if created {
		local.release = func(ctx context.Context) error {
			// A resumed attachment can have the same session ID. IDs for
			// this forward stay owned by that original Core session.
			_, err := a.kernel.RemoteStopForward(ctx, sessionID, forward.ID)
			// log-exempt: 预期的缺失：会话已关闭时，Core 已回收它的转发。
			if remoteConnectionClosed(err) {
				return nil
			}
			return err
		}
	}
	return local, nil
}

// remoteDebugStream bridges the process events and input requests of one
// captured workspace attachment. The event callback cannot wait for DAP to
// respond, since it runs inside a Core call.
type remoteDebugStream struct {
	kernel  Kernel
	ctx     context.Context
	cancel  context.CancelFunc
	process *buildprocess.RemoteProcess
	output  chan []byte
	done    chan struct{}
	err     error
	pending []byte
	mu      sync.Mutex
	queued  int
	full    bool
}

func (a *App) startRemoteAnnouncedAdapter(ctx context.Context, p *project, session *debugSession, prepared preparedDebugLaunch, observe func(buildprocess.Stream, string), unreached error) error {
	if !p.trust.allowed() {
		return remoteDebugUntrusted()
	}
	startup, cancel := context.WithTimeout(ctx, debugOperationTimeout)
	defer cancel()
	process, err := buildprocess.StartRemote(startup, context.WithoutCancel(ctx), a.kernel, remoteDebugProcessSpec(p, prepared, false), observe)
	if err != nil {
		return err
	}
	done := make(chan struct{})
	// The process stays alive through transport shutdown so Stop can flush DAP disconnect.
	session.waitRemoteAdapter = func() {
		process.Stop()
		<-done
	}
	go func() {
		defer close(done)
		a.debugAdapterProcessExited(p, session, process.Wait(), unreached)
	}()
	return nil
}

func (a *App) openRemoteDebugTransport(p *project, session *debugSession, prepared preparedDebugLaunch, policy core.DebugTransportPolicy, messages i18n.DebugMessages) error {
	hooks := a.debugStreamHooks(p, session, messages)
	hooks.OpenStream = func(wait context.Context) (io.ReadWriteCloser, error) {
		if !p.trust.allowed() {
			return nil, remoteDebugUntrusted()
		}
		ctx, cancel := context.WithCancel(context.WithoutCancel(session.ctx))
		stop := context.AfterFunc(wait, cancel)
		stream := &remoteDebugStream{
			kernel: a.kernel, ctx: ctx, cancel: cancel,
			output: make(chan []byte, policy.Limits.BufferedWrites),
			done:   make(chan struct{}),
		}
		process, err := buildprocess.StartRemoteBytes(ctx, ctx, a.kernel, remoteDebugProcessSpec(p, prepared, true), func(name string, data []byte) {
			if name == "stderr" {
				text := string(data)
				a.post(func(a *App) { a.appendDebugOutput(p, session, text) })
				return
			}
			stream.enqueue(data, policy.Limits.BufferedBytes)
		})
		if err != nil {
			stop()
			cancel()
			if stream.full {
				err = errors.New(messages.BufferLimit)
			}
			return nil, err
		}
		stream.process = process
		session.waitRemoteAdapter = func() { <-stream.done }
		go func() {
			defer stop()
			defer close(stream.done)
			err := process.Wait()
			if stream.full {
				err = errors.New(messages.BufferLimit)
			}
			stream.err = err
			close(stream.output)
		}()
		return stream, nil
	}
	transport := newDebugTransport(a.kernel, session.id+"-transport", hooks)
	if !session.setTransport(transport) {
		return context.Canceled
	}
	session.hosted = transport
	return transport.Start(nil)
}

func remoteDebugProcessSpec(p *project, prepared preparedDebugLaunch, stdio bool) core.RemoteProcessOpen {
	return core.RemoteProcessOpen{
		Argv:        append([]string{prepared.Executable}, prepared.Arguments...),
		ScopedCwd:   &core.RemoteScopedDirectory{Root: p.remote.binding.RemoteRoot()},
		Environment: "login",
		Env:         prepared.Environment,
		PathPrepend: prepared.RemotePathPrepend,
		PipeStdin:   stdio,
		Label:       core.NewRemoteResourceLabel("debug", prepared.Configuration.Name),
	}
}

func (s *remoteDebugStream) enqueue(data []byte, byteLimit int) {
	if len(data) == 0 {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.full && len(data) <= byteLimit-s.queued {
		select {
		case s.output <- data:
			s.queued += len(data)
			return
		default:
		}
	}
	s.full = true
	s.cancel()
}

func (s *remoteDebugStream) Read(buffer []byte) (int, error) {
	if len(s.pending) == 0 {
		data, ok := <-s.output
		if !ok {
			if s.err != nil {
				return 0, s.err
			}
			return 0, io.EOF
		}
		s.pending = data
	}
	count := copy(buffer, s.pending)
	s.pending = s.pending[count:]
	s.mu.Lock()
	s.queued -= count
	s.mu.Unlock()
	return count, nil
}

func (s *remoteDebugStream) Write(frame []byte) (int, error) {
	var written int
	for len(frame) > 0 {
		chunk := frame[:min(len(frame), debugReadChunk)]
		if err := s.kernel.WriteRemoteProcessInput(s.ctx, s.process.ID, chunk); err != nil {
			return written, err
		}
		written += len(chunk)
		frame = frame[len(chunk):]
	}
	return written, nil
}

func (s *remoteDebugStream) Close() error {
	s.cancel()
	return nil
}
