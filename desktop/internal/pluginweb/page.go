// Package pluginweb hosts plugin pages (`ui` 2) in web tool windows.
//
// Core decides what a page is served and which bridge requests it may make
// (plugins.web.*); this package does the I/O around those decisions: it reads
// package files without following links, carries out checked requests through
// a Host, and posts the answers Core frames back to the page. Nothing here is
// written next to the package: page state goes to the Host's store, so the
// installed package and the application bundle stay unchanged.
//
// Note: the decision is recorded in
// .agents/notes/implemented/architecture/2026-10-18-plugin-web-content-in-host-windows.md
package pluginweb

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

const (
	// coreTimeout bounds Core's pure page decisions.
	coreTimeout = 2 * time.Second
	// stateTimeout bounds reading or writing a page's stored state.
	stateTimeout = 10 * time.Second
	// callTimeout bounds one function call of a page, consent included.
	callTimeout = 15 * time.Minute
)

// Kernel is the part of Core a page uses.
type Kernel interface {
	OpenPluginWebPage(context.Context, core.PluginWebOpen) (core.PluginWebPage, error)
	ClosePluginWebPage(context.Context, uint64) ([]string, error)
	PluginWebResource(context.Context, uint64, string) (core.PluginWebResource, error)
	PluginWebDocument(context.Context, uint64, string) (string, error)
	PluginWebRequest(context.Context, uint64, string) (core.PluginWebRequestOutcome, error)
	PluginWebReply(context.Context, core.PluginWebReply) (string, error)
	PluginWebEvent(context.Context, uint64, string, any) (string, error)
}

// View is the web view showing a page.
type View interface {
	PostMessage(text string)
	Load(url string)
	Close()
}

// FileRequest is a file dialog a page asked for.
type FileRequest struct {
	Save          bool
	Title         string
	SuggestedName string
	Extensions    []string
}

// Host carries out the requests of the pages of one workspace.
type Host interface {
	// State returns the stored state of a window, nil for none.
	State(ctx context.Context, pluginID, windowID string) ([]byte, error)
	// SetState stores the state of a window; nil clears it.
	SetState(ctx context.Context, pluginID, windowID string, state []byte) error
	// BackendFunctions starts the plugin's backend and lists its functions.
	BackendFunctions(ctx context.Context, pluginID string) ([]string, error)
	// CallBackend invokes a function of the plugin's backend for the
	// workspace. progress, when not nil, receives the call's progress.
	CallBackend(ctx context.Context, pluginID, function string, params json.RawMessage, progress func(json.RawMessage)) (json.RawMessage, error)
	// ChooseFile shows a file dialog and returns the chosen absolute path,
	// or "" when cancelled. It is called off the window thread and blocks
	// until the user answers; Core lets a page have one dialog at a time.
	ChooseFile(pluginID string, request FileRequest) (string, error)
	// OpenFile opens a workspace file in the editor on the window thread.
	OpenFile(path string, line, column int) error
}

// Failure is an answer a page receives as `{ code, message }`.
type Failure struct {
	core.PluginWebError
}

func (f *Failure) Error() string { return f.Code + ": " + f.Message }

// Fail returns a Failure with code and message.
func Fail(code, message string) *Failure {
	return &Failure{core.PluginWebError{Code: code, Message: message}}
}

// Config describes one page.
type Config struct {
	Kernel Kernel
	Host   Host
	// Open is the Core registration request.
	Open core.PluginWebOpen
	// Package is the installed package directory, read only.
	Package string
	// Post runs fn on the window thread.
	Post func(fn func())
	// Log records a failure that the page itself is not told about.
	Log func(stage string, err error)
}

// Page is one open plugin page. Serve, Receive, Loaded, SetTheme and Close
// run on the window thread.
type Page struct {
	config Config
	info   core.PluginWebPage
	root   string
	view   View

	mu     sync.Mutex
	closed bool
	// calls are the running function calls by call ID.
	calls map[string]context.CancelFunc
	// ctx ends when the page closes.
	ctx    context.Context
	cancel context.CancelFunc
}

// Open registers a page with Core. Attach the view that loads URL().
func Open(ctx context.Context, config Config) (*Page, error) {
	root, err := filepath.EvalSymlinks(config.Package)
	if err != nil {
		return nil, fmt.Errorf("plugin package: %w", err)
	}
	info, err := config.Kernel.OpenPluginWebPage(ctx, config.Open)
	if err != nil {
		return nil, err
	}
	pageCtx, cancel := context.WithCancel(context.Background())
	return &Page{config: config, info: info, root: root, calls: map[string]context.CancelFunc{}, ctx: pageCtx, cancel: cancel}, nil
}

// Info is the page as Core registered it.
func (p *Page) Info() core.PluginWebPage { return p.info }

// Attach gives the page the view that shows it.
func (p *Page) Attach(view View) { p.view = view }

// Serve answers one request of the page from its package.
func (p *Page) Serve(path string) (mime string, data []byte, ok bool) {
	ctx, cancel := context.WithTimeout(p.ctx, coreTimeout)
	defer cancel()
	resource, err := p.config.Kernel.PluginWebResource(ctx, p.info.Page, path)
	if err != nil {
		p.log("resource", err)
		return "", nil, false
	}
	switch resource.Kind {
	case "bootstrap":
		return resource.MIME, []byte(resource.Body), true
	case "file":
	default:
		return "", nil, false
	}
	data, err = readPackageFile(p.root, resource.Segments, p.info.FileLimit)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			p.log("resource", err)
		}
		return "", nil, false
	}
	if resource.Document {
		html, err := p.config.Kernel.PluginWebDocument(ctx, p.info.Page, string(data))
		if err != nil {
			p.log("document", err)
			return "", nil, false
		}
		data = []byte(html)
	}
	return resource.MIME, data, true
}

// errOutsidePackage is a package path that leads through a link or to
// something other than a regular file.
var errOutsidePackage = errors.New("plugin page resource is not a regular package file")

// readPackageFile reads a file of the package at root, following no
// symbolic link at any level, and at most limit bytes.
func readPackageFile(root string, segments []string, limit int64) ([]byte, error) {
	path := root
	for _, segment := range segments {
		path = filepath.Join(path, segment)
		info, err := os.Lstat(path)
		if err != nil {
			return nil, err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return nil, errOutsidePackage
		}
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil {
		return nil, err
	}
	linked, err := os.Lstat(path)
	// The file must still be the regular file checked above, not one a
	// concurrent change put in its place.
	if err != nil || !opened.Mode().IsRegular() || !os.SameFile(opened, linked) {
		return nil, errOutsidePackage
	}
	if opened.Size() > limit {
		return nil, fmt.Errorf("plugin page resource is larger than %d bytes", limit)
	}
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("plugin page resource is larger than %d bytes", limit)
	}
	return data, nil
}

// Loaded reports a navigation of the page; one that leaves the plugin's
// origin is sent back to the page's entry.
func (p *Page) Loaded(url string) {
	origin := p.info.Scheme + "://" + p.info.PluginID + "/"
	if p.view == nil || url == "" || strings.HasPrefix(url, origin) || url == "about:blank" {
		return
	}
	p.log("navigation", fmt.Errorf("plugin page left its package: %s", p.info.Scheme))
	p.view.Load(p.info.URL)
}

// Receive handles one message the page posted.
func (p *Page) Receive(message string) {
	if p.isClosed() {
		return
	}
	ctx, cancel := context.WithTimeout(p.ctx, coreTimeout)
	outcome, err := p.config.Kernel.PluginWebRequest(ctx, p.info.Page, message)
	cancel()
	switch {
	case err != nil:
		p.log("request", err)
	case outcome.Reply != "":
		p.deliver(outcome.Reply)
	case outcome.Action != nil:
		p.carryOut(*outcome.Action)
	case outcome.Ignored != "":
		p.log("request", errors.New(outcome.Ignored))
	}
}

func (p *Page) deliver(message string) {
	if message != "" && p.view != nil && !p.isClosed() {
		p.view.PostMessage(message)
	}
}

// answer frames the answer to an action off the window thread and posts it
// on the window thread.
func (p *Page) answer(action core.PluginWebAction, call string, result any, failure error) {
	reply := core.PluginWebReply{Page: p.info.Page, ID: action.ID, Method: action.Method, Call: call}
	if failure != nil {
		var coded *Failure
		if !errors.As(failure, &coded) {
			coded = Fail("plugin.web.invalidRequest", failure.Error())
		}
		reply.Error = &coded.PluginWebError
	} else {
		encoded, err := json.Marshal(result)
		if err != nil {
			encoded, _ = json.Marshal(map[string]any{})
		}
		reply.Result = encoded
	}
	ctx, cancel := context.WithTimeout(context.Background(), coreTimeout)
	defer cancel()
	message, err := p.config.Kernel.PluginWebReply(ctx, reply)
	if err != nil {
		p.log("reply", err)
		return
	}
	p.config.Post(func() { p.deliver(message) })
}

// carryOut runs one checked action. Work that waits, touches files or shows
// a dialog runs off the window thread; editor navigation runs on it.
func (p *Page) carryOut(action core.PluginWebAction) {
	var params struct {
		Path          string          `json:"path"`
		Line          int             `json:"line"`
		Column        int             `json:"column"`
		State         *string         `json:"state"`
		Function      string          `json:"function"`
		Params        json.RawMessage `json:"params"`
		Call          string          `json:"call"`
		Progress      bool            `json:"progress"`
		Active        bool            `json:"active"`
		Title         string          `json:"title"`
		SuggestedName string          `json:"suggestedName"`
		Extensions    []string        `json:"extensions"`
	}
	if err := json.Unmarshal(action.Params, &params); err != nil {
		go p.answer(action, "", nil, err)
		return
	}
	host, plugin, window := p.config.Host, p.info.PluginID, p.info.WindowID
	switch action.Method {
	case "ui.getState":
		go func() {
			ctx, cancel := context.WithTimeout(p.ctx, stateTimeout)
			defer cancel()
			state, err := host.State(ctx, plugin, window)
			if err != nil || len(state) == 0 || len(state) > p.info.StateLimit || !json.Valid(state) {
				if err != nil {
					p.log("state", err)
				}
				state = []byte("null")
			}
			p.answer(action, "", map[string]json.RawMessage{"state": state}, nil)
		}()
	case "ui.setState":
		go func() {
			ctx, cancel := context.WithTimeout(p.ctx, stateTimeout)
			defer cancel()
			var state []byte
			if params.State != nil {
				state = []byte(*params.State)
			}
			if err := host.SetState(ctx, plugin, window, state); err != nil {
				p.log("state", err)
				p.answer(action, "", nil, Fail("plugin.web.invalidRequest", err.Error()))
				return
			}
			p.answer(action, "", struct{}{}, nil)
		}()
	case "functions.list":
		go func() {
			ctx, cancel := context.WithTimeout(p.ctx, callTimeout)
			defer cancel()
			functions, err := host.BackendFunctions(ctx, plugin)
			if err != nil {
				p.answer(action, "", nil, err)
				return
			}
			p.answer(action, "", map[string][]string{"functions": functions}, nil)
		}()
	case "functions.invoke":
		p.invoke(action, params.Call, params.Function, params.Params, params.Progress)
	case "functions.cancel":
		if params.Active {
			p.mu.Lock()
			stop := p.calls[params.Call]
			p.mu.Unlock()
			if stop != nil {
				stop()
			}
		}
		go p.answer(action, "", struct{}{}, nil)
	case "dialog.openFile", "dialog.saveFile":
		request := FileRequest{
			Save: action.Method == "dialog.saveFile", Title: params.Title,
			SuggestedName: params.SuggestedName, Extensions: params.Extensions,
		}
		go func() {
			path, err := host.ChooseFile(plugin, request)
			if err != nil {
				p.log("dialog", err)
				p.answer(action, "", nil, Fail("plugin.web.forbidden", err.Error()))
				return
			}
			var chosen *string
			if path != "" {
				chosen = &path
			}
			p.answer(action, "", map[string]*string{"path": chosen}, nil)
		}()
	case "workspace.openFile":
		err := host.OpenFile(params.Path, params.Line, params.Column)
		go p.answer(action, "", struct{}{}, err)
	default:
		go p.answer(action, "", nil, Fail("plugin.web.unknownMethod", "This host does not answer "+action.Method+"."))
	}
}

// invoke runs one function call of the page's plugin backend.
func (p *Page) invoke(action core.PluginWebAction, call, function string, params json.RawMessage, progress bool) {
	ctx, cancel := context.WithTimeout(p.ctx, callTimeout)
	p.mu.Lock()
	p.calls[call] = cancel
	p.mu.Unlock()
	var report func(json.RawMessage)
	if progress {
		report = func(update json.RawMessage) {
			var fields struct {
				Message    *string `json:"message"`
				Percentage *int    `json:"percentage"`
			}
			_ = json.Unmarshal(update, &fields)
			payload := map[string]any{"call": call, "function": function}
			if fields.Message != nil {
				payload["message"] = *fields.Message
			}
			if fields.Percentage != nil {
				payload["percentage"] = *fields.Percentage
			}
			eventCtx, done := context.WithTimeout(context.Background(), coreTimeout)
			message, err := p.config.Kernel.PluginWebEvent(eventCtx, p.info.Page, "functions.progress", payload)
			done()
			if err != nil {
				p.log("progress", err)
				return
			}
			p.config.Post(func() { p.deliver(message) })
		}
	}
	go func() {
		defer func() {
			p.mu.Lock()
			delete(p.calls, call)
			p.mu.Unlock()
			cancel()
		}()
		value, err := p.config.Host.CallBackend(ctx, p.info.PluginID, function, params, report)
		switch {
		case err == nil:
			p.answer(action, call, map[string]json.RawMessage{"value": value}, nil)
		case errors.Is(ctx.Err(), context.DeadlineExceeded):
			p.answer(action, call, nil, Fail("requestTimeout", "The function call timed out."))
		case ctx.Err() != nil:
			p.answer(action, call, nil, Fail("requestCancelled", "The function call was cancelled."))
		default:
			p.answer(action, call, nil, err)
		}
	}()
}

// SetTheme tells the page the window's theme changed.
func (p *Page) SetTheme(theme core.PluginWebTheme) {
	ctx, cancel := context.WithTimeout(p.ctx, coreTimeout)
	defer cancel()
	message, err := p.config.Kernel.PluginWebEvent(ctx, p.info.Page, "ui.themeChanged", theme)
	if err != nil {
		p.log("theme", err)
		return
	}
	p.deliver(message)
}

// Close ends the page: its calls are cancelled, its view closed, and Core
// forgets it. Closing twice is harmless.
func (p *Page) Close() {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return
	}
	p.closed = true
	calls := p.calls
	p.calls = map[string]context.CancelFunc{}
	p.mu.Unlock()
	for _, stop := range calls {
		stop()
	}
	p.cancel()
	if p.view != nil {
		p.view.Close()
	}
	ctx, cancel := context.WithTimeout(context.Background(), coreTimeout)
	defer cancel()
	if _, err := p.config.Kernel.ClosePluginWebPage(ctx, p.info.Page); err != nil {
		p.log("close", err)
	}
}

func (p *Page) isClosed() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.closed
}

func (p *Page) log(stage string, err error) {
	if p.config.Log != nil {
		p.config.Log(stage, err)
	}
}
