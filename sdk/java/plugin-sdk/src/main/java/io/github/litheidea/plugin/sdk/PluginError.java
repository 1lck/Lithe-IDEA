package io.github.litheidea.plugin.sdk;

/**
 * A failure a handler reports on purpose. Core ends the call with the stable
 * {@code plugin.function.failed} code and forwards {@link #code()} as
 * {@code pluginErrorCode}, so the plugin's own UI can tell its failures apart.
 * Lithe never branches on it.
 *
 * <p>The message is shown to the user as written (Core keeps its first 1024
 * bytes), so it must not contain stack traces or machine paths.
 */
public class PluginError extends RuntimeException {
    private static final long serialVersionUID = 1L;

    private final String code;

    /**
     * @param code identifier of at most 64 bytes, such as {@code maven.snapshotLocked}
     * @param message user-facing text
     */
    public PluginError(String code, String message) {
        this(code, message, null);
    }

    /** As {@link #PluginError(String, String)}; {@code cause} is kept for logs only. */
    public PluginError(String code, String message, Throwable cause) {
        super(message, cause);
        if (!Protocol.isPluginErrorCode(code)) {
            throw new IllegalArgumentException("Plugin error code \"" + code
                    + "\" must start with a letter, use letters, digits, \".\", \"_\" or \"-\", and be at most 64 bytes.");
        }
        this.code = code;
    }

    public String code() {
        return code;
    }
}
