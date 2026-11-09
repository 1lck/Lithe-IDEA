//go:build !windows

package buildprocess

import (
	"os"
	"os/exec"
	"sync"
	"syscall"
)

type processPlatform struct {
	mu     sync.Mutex
	pid    int
	active bool
}

// configure puts the process in its own group so Stop can end the whole build
// tree, including wrappers that start child compilers.
func (*processPlatform) configure(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

func (p *processPlatform) adopt(process *os.Process) error {
	if process == nil {
		return nil
	}
	p.mu.Lock()
	p.pid = process.Pid
	p.active = true
	p.mu.Unlock()
	return nil
}

func (p *processPlatform) release() {
	p.mu.Lock()
	p.active = false
	p.pid = 0
	p.mu.Unlock()
}

func (p *processPlatform) terminate(process *os.Process) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.active || p.pid == 0 {
		return
	}
	if err := syscall.Kill(-p.pid, syscall.SIGKILL); err != nil && process != nil {
		_ = process.Kill()
	}
	// A later Stop must not signal a reused process-group ID. The group was
	// sent SIGKILL once; release only clears ownership.
	p.active = false
}
