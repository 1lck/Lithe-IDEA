package io.github.litheidea.plugin.sdk;

/**
 * Thrown when the call a piece of work belongs to was cancelled or ended.
 * A handler normally lets it propagate; the SDK then answers the host with
 * {@code RequestCancelled}.
 */
public class CancelledException extends RuntimeException {
    private static final long serialVersionUID = 1L;

    public CancelledException(String message) {
        super(message);
    }
}
