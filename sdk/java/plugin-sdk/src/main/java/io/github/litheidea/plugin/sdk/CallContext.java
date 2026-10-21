package io.github.litheidea.plugin.sdk;

import java.io.IOException;
import java.util.List;

/**
 * What a handler gets besides its params: the call's cancellation, tools that
 * end with the call, the backend's log, and progress for plugin functions.
 */
public final class CallContext {
    /** Sends one progress report; absent outside plugin functions. */
    interface ProgressSink {
        void report(String message, Double percentage);
    }

    private final Cancellation cancellation;
    private final Backend backend;
    private final String functionId;
    private final String operationId;
    private final ProgressSink progress;

    CallContext(Cancellation cancellation, Backend backend, String functionId, String operationId, ProgressSink progress) {
        this.cancellation = cancellation;
        this.backend = backend;
        this.functionId = functionId;
        this.operationId = operationId;
        this.progress = progress;
    }

    /**
     * Cancelled when the host cancels the call, the backend shuts down, or the
     * call ends; work a handler leaves running after it returned is stopped.
     */
    public Cancellation cancellation() {
        return cancellation;
    }

    public boolean isCancelled() {
        return cancellation.isCancelled();
    }

    /** Throws {@link CancelledException} once the call was cancelled. */
    public void throwIfCancelled() {
        cancellation.throwIfCancelled();
    }

    /**
     * Runs a tool that belongs to this call: cancelling the call or ending it
     * stops the tool, and the backend shutting down ends it.
     */
    public Processes.Result run(List<String> command, Processes.Options options) throws IOException {
        Processes.Options settings = options == null ? new Processes.Options() : options.copy();
        Cancellation own = settings.cancellation();
        settings.cancellation(own == null ? cancellation : cancellation.combinedWith(own));
        return Processes.run(command, settings);
    }

    /** Runs a tool that belongs to this call with default options. */
    public Processes.Result run(List<String> command) throws IOException {
        return run(command, null);
    }

    /** Writes a diagnostic line to stderr, which the host keeps in its log. */
    public void log(String message) {
        backend.log(message);
    }

    /**
     * Reports progress of a plugin function. {@code message} is cut to 1024
     * bytes and {@code percentage} rounded into 0-100; either may be null.
     * Reports after the call ended, and from build requests, are dropped.
     */
    public void progress(String message, Double percentage) {
        if (progress != null) {
            progress.report(message, percentage);
        }
    }

    /** The function this call runs, or null for a build or LSP request. */
    public String functionId() {
        return functionId;
    }

    /** The host's operation ID of a function call, or null. */
    public String operationId() {
        return operationId;
    }
}
