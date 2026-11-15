package core

/*
#include <signal.h>
void lithe_signal_guard_link(void);

// The regression test observes the real process disposition without replacing it.
static int lithe_child_signal_flags(void) {
    struct sigaction current;
    if (sigaction(SIGCHLD, NULL, &current) != 0) return -1;
    return current.sa_flags;
}
static int lithe_onstack_flag(void) { return SA_ONSTACK; }

static void lithe_test_handler(int number) { (void)number; }
// Run only in an isolated test subprocess, then restore the prior disposition.
static int lithe_test_unrelated_signal(void) {
    struct sigaction before, requested, observed;
    if (sigaction(SIGUSR1, NULL, &before) != 0) return 1;
    requested = before;
    requested.sa_handler = lithe_test_handler;
    requested.sa_flags = SA_RESTART;
    sigemptyset(&requested.sa_mask);
    sigaddset(&requested.sa_mask, SIGTERM);
    if (sigaction(SIGUSR1, &requested, NULL) != 0) return 2;
    int result = 0;
    if (sigaction(SIGUSR1, NULL, &observed) != 0) result = 3;
    else if (observed.sa_handler != lithe_test_handler ||
             (observed.sa_flags & SA_ONSTACK) != 0 ||
             (observed.sa_flags & SA_RESTART) == 0 ||
             sigismember(&observed.sa_mask, SIGTERM) != 1) result = 4;
    if (sigaction(SIGUSR1, &before, NULL) != 0) return 5;
    return result;
}
static int lithe_test_ignored_child(void) {
    struct sigaction before, requested, observed;
    if (sigaction(SIGCHLD, NULL, &before) != 0) return 1;
    requested = before;
    requested.sa_handler = SIG_IGN;
    requested.sa_flags = 0;
    sigemptyset(&requested.sa_mask);
    if (sigaction(SIGCHLD, &requested, NULL) != 0) return 2;
    int result = 0;
    if (sigaction(SIGCHLD, NULL, &observed) != 0) result = 3;
    else if (observed.sa_handler != SIG_IGN || (observed.sa_flags & SA_ONSTACK) != 0) result = 4;
    if (sigaction(SIGCHLD, &before, NULL) != 0) return 5;
    return result;
}
*/
import "C"

func init() { C.lithe_signal_guard_link() }

func childSignalFlags() (int, int) {
	return int(C.lithe_child_signal_flags()), int(C.lithe_onstack_flag())
}

func testUnrelatedSignal() int { return int(C.lithe_test_unrelated_signal()) }

func testIgnoredChildSignal() int { return int(C.lithe_test_ignored_child()) }
