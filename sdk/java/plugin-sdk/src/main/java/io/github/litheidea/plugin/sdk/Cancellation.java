package io.github.litheidea.plugin.sdk;

import java.util.ArrayList;
import java.util.List;

/**
 * Cancellation of one call, or of work a plugin manages itself. Listeners run
 * once, on the thread that cancels; a listener added after cancellation runs
 * immediately. A listener that throws is logged to stderr and does not keep
 * the others, or the thread that cancelled, from running on. Cancelling never interrupts threads, because an interrupt
 * closes NIO channels a handler may be writing state through; long work checks
 * {@link #isCancelled()} or {@link #throwIfCancelled()} instead.
 */
public final class Cancellation {
    private final Object lock = new Object();
    private final List<Runnable> listeners = new ArrayList<>();
    private String reason;

    /** Cancels with {@code reason}; later calls have no effect. */
    public void cancel(String reason) {
        List<Runnable> pending;
        synchronized (lock) {
            if (this.reason != null) {
                return;
            }
            this.reason = reason == null ? "The request was cancelled." : reason;
            pending = new ArrayList<>(listeners);
            listeners.clear();
        }
        for (Runnable listener : pending) {
            runIsolated(listener);
        }
    }

    public boolean isCancelled() {
        synchronized (lock) {
            return reason != null;
        }
    }

    /** Throws {@link CancelledException} once cancelled. */
    public void throwIfCancelled() {
        String current;
        synchronized (lock) {
            current = reason;
        }
        if (current != null) {
            throw new CancelledException(current);
        }
    }

    /**
     * Runs {@code listener} on cancellation. The returned handle removes it,
     * for work that finished first.
     */
    public Registration onCancel(Runnable listener) {
        synchronized (lock) {
            if (reason == null) {
                listeners.add(listener);
                return () -> {
                    synchronized (lock) {
                        listeners.remove(listener);
                    }
                };
            }
        }
        runIsolated(listener);
        return () -> {};
    }

    /**
     * A token cancelled when either this one or {@code other} is; for work that
     * a plugin may also stop for its own reasons.
     */
    public Cancellation combinedWith(Cancellation other) {
        Cancellation combined = new Cancellation();
        Registration first = onCancel(() -> combined.cancel(reasonOrDefault()));
        Registration second = other.onCancel(() -> combined.cancel(other.reasonOrDefault()));
        combined.onCancel(() -> {
            first.remove();
            second.remove();
        });
        return combined;
    }

    private static void runIsolated(Runnable listener) {
        try {
            listener.run();
        } catch (RuntimeException error) {
            System.err.println("A cancellation listener failed: " + error);
        }
    }

    private String reasonOrDefault() {
        synchronized (lock) {
            return reason == null ? "The request was cancelled." : reason;
        }
    }

    /** Removes a cancellation listener. */
    public interface Registration {
        void remove();
    }
}
