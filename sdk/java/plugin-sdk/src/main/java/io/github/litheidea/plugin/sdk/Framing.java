package io.github.litheidea.plugin.sdk;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * LSP base-protocol framing: {@code Content-Length} headers followed by a UTF-8
 * JSON body. Lithe talks to every plugin backend this way, so the SDK owns the
 * framing and plugin code never writes to stdout itself.
 */
public final class Framing {
    /** Largest header block accepted from the host. */
    static final int MAX_HEADER_BYTES = 8192;

    /** Largest body accepted from the host. Larger frames end the session. */
    public static final int MAX_FRAME_BYTES = 64 * 1024 * 1024;

    /** Stands for a body that is not JSON; compared by identity, so no host message can mimic it. */
    public static final Object MALFORMED = new Object() {
        @Override
        public String toString() {
            return "MALFORMED";
        }
    };

    private static final byte[] HEADER_END = {'\r', '\n', '\r', '\n'};

    private Framing() {}

    /** A framing error the session cannot recover from. */
    public static final class FramingException extends RuntimeException {
        private static final long serialVersionUID = 1L;

        FramingException(String message) {
            super(message);
        }
    }

    /** Encodes one JSON-RPC message as a complete frame. */
    public static byte[] encode(Object message) {
        byte[] body = Json.stringify(message).getBytes(StandardCharsets.UTF_8);
        byte[] header = ("Content-Length: " + body.length + "\r\n\r\n").getBytes(StandardCharsets.US_ASCII);
        byte[] frame = Arrays.copyOf(header, header.length + body.length);
        System.arraycopy(body, 0, frame, header.length, body.length);
        return frame;
    }

    /** Incrementally splits a byte stream into decoded JSON-RPC messages. */
    public static final class Decoder {
        private byte[] buffer = new byte[8192];
        private int length;

        /**
         * Appends {@code count} bytes of {@code chunk} and returns every complete
         * message they finished. A body that is not JSON is returned as
         * {@link #MALFORMED} so the caller can report it without losing the
         * framing position.
         */
        public List<Object> push(byte[] chunk, int offset, int count) {
            ensureCapacity(length + count);
            System.arraycopy(chunk, offset, buffer, length, count);
            length += count;
            List<Object> messages = new ArrayList<>();
            int start = 0;
            for (;;) {
                int headerEnd = indexOfHeaderEnd(start);
                int available = length - start;
                // The same bound whether the header arrived whole or in pieces.
                if ((headerEnd >= 0 && headerEnd - start > MAX_HEADER_BYTES)
                        || (headerEnd < 0 && available > MAX_HEADER_BYTES)) {
                    throw new FramingException("The message header is too long.");
                }
                if (headerEnd < 0) {
                    break;
                }
                int bodyLength = contentLength(new String(buffer, start, headerEnd - start, StandardCharsets.US_ASCII));
                int bodyStart = headerEnd + HEADER_END.length;
                if ((long) length < (long) bodyStart + bodyLength) {
                    break;
                }
                String body = new String(buffer, bodyStart, bodyLength, StandardCharsets.UTF_8);
                start = bodyStart + bodyLength;
                try {
                    messages.add(Json.parse(body));
                } catch (Json.JsonException error) {
                    messages.add(MALFORMED);
                }
            }
            if (start > 0) {
                System.arraycopy(buffer, start, buffer, 0, length - start);
                length -= start;
            }
            return messages;
        }

        private int indexOfHeaderEnd(int from) {
            for (int index = from; index + HEADER_END.length <= length; index++) {
                if (buffer[index] == '\r' && buffer[index + 1] == '\n'
                        && buffer[index + 2] == '\r' && buffer[index + 3] == '\n') {
                    return index;
                }
            }
            return -1;
        }

        private void ensureCapacity(int required) {
            if (required > buffer.length) {
                buffer = Arrays.copyOf(buffer, Math.max(required, buffer.length * 2));
            }
        }
    }

    private static int contentLength(String header) {
        for (String line : header.split("\r\n")) {
            int separator = line.indexOf(':');
            if (separator < 0) {
                continue;
            }
            if (!line.substring(0, separator).trim().equalsIgnoreCase("content-length")) {
                continue;
            }
            String value = line.substring(separator + 1).trim();
            if (!value.matches("[0-9]+")) {
                break;
            }
            // More than ten digits exceeds the limit whatever they are.
            long length = value.length() > 10 ? Long.MAX_VALUE : Long.parseLong(value);
            if (length > MAX_FRAME_BYTES) {
                throw new FramingException("A message of " + value + " bytes exceeds the "
                        + MAX_FRAME_BYTES + "-byte limit.");
            }
            return (int) length;
        }
        throw new FramingException("A message has no valid Content-Length header.");
    }
}
