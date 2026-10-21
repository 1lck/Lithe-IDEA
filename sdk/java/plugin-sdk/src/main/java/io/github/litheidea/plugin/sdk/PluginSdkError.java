package io.github.litheidea.plugin.sdk;

/**
 * An SDK usage error raised to the plugin author, or a failure the host
 * reported for a request this backend sent. {@link #rpcCode()} carries the
 * host's JSON-RPC error code in the latter case.
 */
public class PluginSdkError extends RuntimeException {
    private static final long serialVersionUID = 1L;

    private final String code;
    private final Integer rpcCode;

    public PluginSdkError(String code, String message) {
        this(code, message, null);
    }

    public PluginSdkError(String code, String message, Integer rpcCode) {
        super(message);
        this.code = code;
        this.rpcCode = rpcCode;
    }

    public String code() {
        return code;
    }

    /** The host's JSON-RPC error code, or {@code null} for a local usage error. */
    public Integer rpcCode() {
        return rpcCode;
    }
}
