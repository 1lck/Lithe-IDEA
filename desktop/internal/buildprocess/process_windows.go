//go:build windows

package buildprocess

import (
	"errors"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// processPlatform owns the Windows Job Object that contains the build process
// and every descendant it starts. It mirrors the semantics of Core's
// lithe-git-host ProcessTree: the child is created suspended, joins a job with
// JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE before running, and the job ends the entire
// tree even when the root process has already exited.
type processPlatform struct {
	mu     sync.Mutex
	job    windows.Handle
	active bool
}

func (p *processPlatform) configure(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: windows.CREATE_NO_WINDOW | windows.CREATE_SUSPENDED | windows.CREATE_NEW_PROCESS_GROUP,
	}
}

func (p *processPlatform) adopt(process *os.Process) error {
	if process == nil {
		return errors.New("buildprocess: no process to adopt")
	}
	handle, err := windows.OpenProcess(
		windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE|windows.PROCESS_QUERY_INFORMATION,
		false,
		uint32(process.Pid),
	)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(handle)
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return err
	}
	var info windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(
		job,
		windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&info)),
		uint32(unsafe.Sizeof(info)),
	); err != nil {
		windows.CloseHandle(job)
		return err
	}
	if err := windows.AssignProcessToJobObject(job, handle); err != nil {
		windows.CloseHandle(job)
		return err
	}
	if err := resumeProcess(uint32(process.Pid)); err != nil {
		_ = windows.TerminateJobObject(job, 1)
		windows.CloseHandle(job)
		return err
	}
	p.mu.Lock()
	p.job = job
	p.active = true
	p.mu.Unlock()
	return nil
}

func (p *processPlatform) terminate(process *os.Process) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.active || p.job == 0 {
		return
	}
	if err := windows.TerminateJobObject(p.job, 1); err != nil && process != nil {
		_ = process.Kill()
	}
	p.active = false
}

func (p *processPlatform) release() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.job == 0 {
		p.active = false
		return
	}
	// KILL_ON_JOB_CLOSE also removes any child that outlived the root process.
	_ = windows.CloseHandle(p.job)
	p.job = 0
	p.active = false
}

func resumeProcess(processID uint32) error {
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPTHREAD, 0)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(snapshot)
	entry := windows.ThreadEntry32{Size: uint32(unsafe.Sizeof(windows.ThreadEntry32{}))}
	resumed := false
	for err := windows.Thread32First(snapshot, &entry); err == nil; err = windows.Thread32Next(snapshot, &entry) {
		if entry.OwnerProcessID != processID {
			continue
		}
		thread, openErr := windows.OpenThread(windows.THREAD_SUSPEND_RESUME, false, entry.ThreadID)
		if openErr != nil {
			continue
		}
		if _, resumeErr := windows.ResumeThread(thread); resumeErr == nil {
			resumed = true
		}
		windows.CloseHandle(thread)
	}
	if !resumed {
		return errors.New("buildprocess: no suspended thread was found")
	}
	return nil
}
