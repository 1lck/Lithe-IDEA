//go:build darwin

// The statically linked Tokio process runtime installs its SIGCHLD handler
// without SA_ONSTACK. It chains the previous Go handler, which requires that
// flag: otherwise a child exit can terminate the entire Go process. Guard the
// registration itself, not the result afterwards, so no unguarded interval
// exists between sigaction and a concurrent child exit.
//
// This symbol overrides calls linked into this executable, including the Rust
// static library. It does not intercept calls originating in other dylibs.
// The original handler, mask and all other flags are preserved. Default and
// ignored dispositions and other signals pass through unchanged.
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>

static int (*lithe_original_sigaction)(int, const struct sigaction *, struct sigaction *);
static pthread_once_t lithe_sigaction_once = PTHREAD_ONCE_INIT;

static void lithe_resolve_sigaction(void) {
    lithe_original_sigaction = dlsym(RTLD_NEXT, "sigaction");
}

int sigaction(int signal_number, const struct sigaction *restrict action,
              struct sigaction *restrict previous) {
    int once_error = pthread_once(&lithe_sigaction_once, lithe_resolve_sigaction);
    if (once_error != 0 || lithe_original_sigaction == NULL) {
        errno = once_error != 0 ? once_error : ENOSYS;
        return -1;
    }
    if (signal_number == SIGCHLD && action != NULL &&
        action->sa_handler != SIG_DFL && action->sa_handler != SIG_IGN) {
        struct sigaction guarded = *action;
        guarded.sa_flags |= SA_ONSTACK;
        return lithe_original_sigaction(signal_number, &guarded, previous);
    }
    return lithe_original_sigaction(signal_number, action, previous);
}

// Go references this symbol so the external linker retains this translation
// unit even though Rust's reference to sigaction would also exist in libc.
void lithe_signal_guard_link(void) {}
