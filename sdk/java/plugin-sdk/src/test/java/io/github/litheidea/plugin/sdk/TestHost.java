package io.github.litheidea.plugin.sdk;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.function.Predicate;

/**
 * A host for SDK tests: it writes framed messages to an in-memory backend and
 * decodes the answers, with a bounded wait on each.
 */
final class TestHost {
    /** Upper bound for any single wait; a broken backend fails fast instead of hanging. */
    static final long WAIT_MILLIS = 5000;

    private final QueueInput input = new QueueInput();
    private final List<Map<String, Object>> messages = new ArrayList<>();
    private final ByteArrayOutputStream errors = new ByteArrayOutputStream();
    private final CompletableFuture<Integer> done = new CompletableFuture<>();
    private int nextId = 1;

    TestHost(Backend backend) {
        Framing.Decoder decoder = new Framing.Decoder();
        OutputStream output = new OutputStream() {
            @Override
            public void write(int value) {
                write(new byte[] {(byte) value}, 0, 1);
            }

            @Override
            public void write(byte[] bytes, int offset, int length) {
                for (Object message : decoder.push(bytes, offset, length)) {
                    synchronized (messages) {
                        messages.add(Json.object(message));
                        messages.notifyAll();
                    }
                }
            }
        };
        PrintStream errorOutput = new PrintStream(errors, true);
        Thread thread = new Thread(() -> {
            try {
                done.complete(backend.listen(input, output, errorOutput));
            } catch (Throwable error) {
                done.completeExceptionally(error);
            }
        }, "test-host-backend");
        thread.setDaemon(true);
        thread.start();
    }

    /** Sends one message; {@code jsonrpc} is added. */
    void send(Map<String, Object> message) {
        Map<String, Object> framed = new LinkedHashMap<>();
        framed.put("jsonrpc", "2.0");
        framed.putAll(message);
        input.push(Framing.encode(framed));
    }

    /** Writes raw bytes, for framing tests. */
    void sendBytes(byte[] bytes) {
        input.push(bytes);
    }

    /** Sends a request and waits for the backend's response. */
    Map<String, Object> request(String method, Object params) {
        return requestAsync(method, params, nextId()).join();
    }

    Map<String, Object> request(String method, Object params, Object id) {
        return requestAsync(method, params, id).join();
    }

    /** Sends a request now and resolves with the response once it arrives. */
    CompletableFuture<Map<String, Object>> requestAsync(String method, Object params, Object id) {
        send(Fixtures.map("id", id, "method", method, "params", params));
        return CompletableFuture.supplyAsync(() -> waitFor(
                message -> id.equals(message.get("id")) && !message.containsKey("method"),
                "the response to " + method));
    }

    void notify(String method, Object params) {
        send(Fixtures.map("method", method, "params", params));
    }

    Map<String, Object> initialize() {
        return initialize(Fixtures.map(
                "litheBuild", Fixtures.map("versions", Arrays.asList(1)),
                "litheFunctions", Fixtures.map("versions", Arrays.asList(1))));
    }

    Map<String, Object> initialize(Map<String, Object> experimental) {
        Map<String, Object> response = request("initialize", Fixtures.map(
                "processId", null,
                "rootUri", "file:///workspace",
                "capabilities", Fixtures.map("experimental", experimental)));
        notify("initialized", Fixtures.map());
        return response;
    }

    /** The first message, past or future, that {@code matches}. */
    Map<String, Object> waitFor(Predicate<Map<String, Object>> matches, String description) {
        long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(WAIT_MILLIS);
        synchronized (messages) {
            for (;;) {
                for (Map<String, Object> message : messages) {
                    if (matches.test(message)) {
                        return message;
                    }
                }
                long remaining = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime());
                if (remaining <= 0) {
                    throw new AssertionError("Timed out waiting for " + description + "; messages: " + messages
                            + "; stderr: " + errors());
                }
                try {
                    messages.wait(remaining);
                } catch (InterruptedException error) {
                    Thread.currentThread().interrupt();
                    throw new AssertionError("Interrupted waiting for " + description, error);
                }
            }
        }
    }

    List<Map<String, Object>> messages() {
        synchronized (messages) {
            return new ArrayList<>(messages);
        }
    }

    String errors() {
        return new String(errors.toByteArray(), StandardCharsets.UTF_8);
    }

    /** The backend's exit code once the session ended. */
    int exitCode() {
        return Fixtures.await(done, "the backend to exit");
    }

    /** Closes the input and returns the backend's exit code. */
    int close() {
        input.close();
        return exitCode();
    }

    private Object nextId() {
        synchronized (this) {
            return (long) nextId++;
        }
    }

    /** An input stream fed by the test; closing it is the host closing stdin. */
    private static final class QueueInput extends InputStream {
        private static final byte[] END = new byte[0];
        private final LinkedBlockingQueue<byte[]> chunks = new LinkedBlockingQueue<>();
        private byte[] current = new byte[0];
        private int position;
        private boolean ended;

        void push(byte[] bytes) {
            chunks.add(bytes.clone());
        }

        @Override
        public void close() {
            chunks.add(END);
        }

        @Override
        public int read() {
            byte[] one = new byte[1];
            int count = read(one, 0, 1);
            return count < 0 ? -1 : one[0] & 0xff;
        }

        @Override
        public int read(byte[] buffer, int offset, int length) {
            if (ended) {
                return -1;
            }
            while (position >= current.length) {
                byte[] next;
                try {
                    // The backend's reader blocks here as it blocks on stdin; the
                    // test bounds every wait on the backend's answers instead.
                    next = chunks.take();
                } catch (InterruptedException error) {
                    Thread.currentThread().interrupt();
                    return -1;
                }
                if (next == END) {
                    ended = true;
                    return -1;
                }
                current = next;
                position = 0;
            }
            int count = Math.min(length, current.length - position);
            System.arraycopy(current, position, buffer, offset, count);
            position += count;
            return count;
        }
    }
}
