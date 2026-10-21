package io.github.litheidea.plugin.sdk;

import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Supplier;

/**
 * The plugin backend session: one process the host starts from the plugin's
 * manifest and talks to over stdio with the LSP base protocol.
 *
 * <p>The SDK owns everything Lithe manages uniformly -- the lifecycle, protocol
 * negotiation, cancellation, error codes, and the {@code lithe/*} namespace --
 * and leaves the plugin free to decide what its handlers do. Declare handlers,
 * then call {@link #listen()}. Handlers run on their own threads, so several
 * calls can be in flight at once; shared plugin state needs its own locking.
 *
 * <p>Contract: {@code shared/contracts/plugins/v1/README.md} ("Build providers"
 * and "Plugin functions"). Behaviour and error codes match the Node.js SDK.
 */
public final class Backend {
    /** Answers a typed build request or a plugin function. */
    @FunctionalInterface
    public interface Handler {
        Object handle(Map<String, Object> params, CallContext context) throws Exception;
    }

    /** Answers a standard LSP request, for a backend that is also a language server. */
    @FunctionalInterface
    public interface RequestHandler {
        Object handle(Object params, CallContext context) throws Exception;
    }

    /** Handles a standard LSP notification. */
    @FunctionalInterface
    public interface NotificationHandler {
        void handle(Object params) throws Exception;
    }

    /** Runs before the {@code initialize} answer. */
    @FunctionalInterface
    public interface InitializeHook {
        void run(Map<String, Object> params, Negotiated negotiated) throws Exception;
    }

    /** Runs on {@code shutdown}, after running calls were cancelled. */
    @FunctionalInterface
    public interface ShutdownHook {
        void run() throws Exception;
    }

    /** Protocols the host agreed to in {@code initialize}. */
    public static final class Negotiated {
        static final Negotiated NONE = new Negotiated(false, false);

        private final boolean functions;
        private final boolean build;

        Negotiated(boolean functions, boolean build) {
            this.functions = functions;
            this.build = build;
        }

        /** Plugin functions, {@code litheFunctions} version 1. */
        public boolean functions() {
            return functions;
        }

        /** Typed build requests, {@code litheBuild} version 1. */
        public boolean build() {
            return build;
        }
    }

    private enum Phase { IDLE, LISTENING, INITIALIZING, READY, SHUTTING_DOWN, EXITED }

    /** Canonical result format of each typed build request. */
    private static final Map<String, String> BUILD_FORMATS;

    static {
        Map<String, String> formats = new HashMap<>();
        formats.put(Protocol.BUILD_MODEL, "litheBuildModel");
        formats.put(Protocol.BUILD_DEPENDENCIES, "litheDependencies");
        BUILD_FORMATS = Collections.unmodifiableMap(formats);
    }

    private final String name;
    private final String version;
    private final Map<String, Object> capabilities;
    private final Object lock = new Object();
    private final Object writeLock = new Object();
    private final Map<String, Handler> functions = new HashMap<>();
    private final Map<String, Handler> buildHandlers = new HashMap<>();
    private final Map<String, RequestHandler> requestHandlers = new HashMap<>();
    private final Map<String, NotificationHandler> notificationHandlers = new HashMap<>();
    private final List<InitializeHook> initializeHooks = new ArrayList<>();
    private final List<ShutdownHook> shutdownHooks = new ArrayList<>();
    /** Host requests being handled, by JSON-RPC ID. */
    private final Map<String, Call> incoming = new HashMap<>();
    /** Requests this backend sent to the host, by JSON-RPC ID. */
    private final Map<String, Pending> outgoing = new HashMap<>();
    private final AtomicInteger nextRequestId = new AtomicInteger(1);
    private final ExecutorService executor = Executors.newCachedThreadPool(new ThreadNamer());
    /** Serializes register/unregister so the host sees them in call order. */
    private CompletableFuture<Void> registrations = CompletableFuture.completedFuture(null);
    private volatile Phase phase = Phase.IDLE;
    private volatile Negotiated negotiated = Negotiated.NONE;
    private volatile Map<String, Object> initializeParams;
    private volatile OutputStream output;
    private volatile PrintStream errorOutput = System.err;
    private int exitCode = 1;

    private Backend(String name, String version, Map<String, Object> capabilities) {
        Object experimental = capabilities.get("experimental");
        if (experimental instanceof Map
                && (((Map<?, ?>) experimental).containsKey("litheBuild")
                        || ((Map<?, ?>) experimental).containsKey("litheFunctions"))) {
            throw new PluginSdkError("sdk.capabilities.reserved",
                    "litheBuild and litheFunctions are negotiated by the SDK; declare handlers instead.");
        }
        this.name = name == null ? "lithe-plugin-backend" : name;
        this.version = version;
        this.capabilities = new LinkedHashMap<>(capabilities);
    }

    /**
     * Creates a backend.
     *
     * @param name reported as {@code serverInfo.name} and used as the log prefix
     * @param version reported as {@code serverInfo.version}; may be null
     */
    public static Backend create(String name, String version) {
        return new Backend(name, version, Collections.<String, Object>emptyMap());
    }

    /**
     * Creates a backend that also declares standard LSP server capabilities.
     * {@code experimental.litheBuild} and {@code experimental.litheFunctions}
     * are negotiated by the SDK and cannot be set here.
     */
    public static Backend create(String name, String version, Map<String, Object> capabilities) {
        return new Backend(name, version, capabilities == null ? Collections.<String, Object>emptyMap() : capabilities);
    }

    /** Protocols the host agreed to in {@code initialize}; both false before it. */
    public Negotiated negotiated() {
        return negotiated;
    }

    /** The host's {@code initialize} params, or null before it arrives. */
    public Map<String, Object> initializeParams() {
        return initializeParams;
    }

    /** IDs of the functions this backend currently serves, sorted. */
    public List<String> functionIds() {
        synchronized (lock) {
            List<String> ids = new ArrayList<>(functions.keySet());
            Collections.sort(ids);
            return ids;
        }
    }

    /** Answers {@code lithe/build/model} with a {@code litheBuildModel} document. */
    public Backend onModel(Handler handler) {
        return declareBuild(Protocol.BUILD_MODEL, handler);
    }

    /** Answers {@code lithe/build/dependencies} with a {@code litheDependencies} document. */
    public Backend onDependencies(Handler handler) {
        return declareBuild(Protocol.BUILD_DEPENDENCIES, handler);
    }

    /**
     * Declares a plugin function offered from the start, in the {@code initialize}
     * answer. To add one later, use {@link #registerFunction}.
     *
     * @param id dot-separated lowerCamelCase segments, such as {@code snapshot.refresh}
     */
    public Backend function(String id, Handler handler) {
        synchronized (lock) {
            if (!beforeAnswer()) {
                throw new PluginSdkError("sdk.function.lateDeclaration",
                        "After initialize, add functions with registerFunction().");
            }
            checkNewFunction(id, handler);
            functions.put(id, handler);
        }
        return this;
    }

    /** Handles a standard LSP request, for a backend that is also a language server. */
    public Backend onRequest(String method, RequestHandler handler) {
        checkDeclared(method, handler);
        synchronized (lock) {
            requestHandlers.put(method, handler);
        }
        return this;
    }

    /** Handles a standard LSP notification. */
    public Backend onNotification(String method, NotificationHandler handler) {
        checkDeclared(method, handler);
        synchronized (lock) {
            notificationHandlers.put(method, handler);
        }
        return this;
    }

    /** Runs before the {@code initialize} answer, with the host's params and the negotiation. */
    public Backend onInitialize(InitializeHook hook) {
        synchronized (lock) {
            initializeHooks.add(hook);
        }
        return this;
    }

    /** Runs on {@code shutdown}, after running calls were cancelled. */
    public Backend onShutdown(ShutdownHook hook) {
        synchronized (lock) {
            shutdownHooks.add(hook);
        }
        return this;
    }

    /**
     * Adds a function. Before the {@code initialize} answer (including from an
     * {@link #onInitialize} hook) it joins the initial list; afterwards the host
     * must accept it first. The future completes once the function is served.
     */
    public CompletableFuture<Void> registerFunction(String id, Handler handler) {
        synchronized (lock) {
            if (beforeAnswer()) {
                try {
                    checkNewFunction(id, handler);
                    functions.put(id, handler);
                    return CompletableFuture.completedFuture(null);
                } catch (RuntimeException error) {
                    return failed(error);
                }
            }
        }
        return queueRegistration(() -> {
            synchronized (lock) {
                requireFunctions();
                checkNewFunction(id, handler);
                // Installed before the request: the host may invoke it as soon as
                // its registry changed, before this backend reads the reply.
                functions.put(id, handler);
            }
            Map<String, Object> entry = new LinkedHashMap<>();
            entry.put("id", id);
            Map<String, Object> params = new LinkedHashMap<>();
            params.put("functions", Collections.singletonList(entry));
            return request(Protocol.FUNCTION_REGISTER, params).handle((result, error) -> {
                if (error != null) {
                    synchronized (lock) {
                        functions.remove(id);
                    }
                    throw new CompletionException(unwrap(error));
                }
                return null;
            });
        });
    }

    /** Withdraws a function. The host ends its running calls as revoked. */
    public CompletableFuture<Void> unregisterFunction(String id) {
        synchronized (lock) {
            if (beforeAnswer()) {
                if (functions.remove(id) == null) {
                    return failed(unknownFunction(id));
                }
                return CompletableFuture.completedFuture(null);
            }
        }
        return queueRegistration(() -> {
            synchronized (lock) {
                requireFunctions();
                if (!functions.containsKey(id)) {
                    throw unknownFunction(id);
                }
            }
            Map<String, Object> params = new LinkedHashMap<>();
            params.put("ids", Collections.singletonList(id));
            return request(Protocol.FUNCTION_UNREGISTER, params).thenApply(result -> {
                List<Call> running = new ArrayList<>();
                synchronized (lock) {
                    functions.remove(id);
                    for (Call call : incoming.values()) {
                        if (id.equals(call.functionId)) {
                            running.add(call);
                        }
                    }
                }
                for (Call call : running) {
                    call.cancellation.cancel("The function was withdrawn.");
                }
                return null;
            });
        });
    }

    /** Sends a standard LSP request to the host. {@code lithe/*} methods are reserved. */
    public CompletableFuture<Object> sendRequest(String method, Object params) {
        checkOutgoing(method);
        return request(method, params);
    }

    /** Sends a standard LSP notification to the host. {@code lithe/*} methods are reserved. */
    public void sendNotification(String method, Object params) {
        checkOutgoing(method);
        Map<String, Object> message = message(null, method);
        if (params != null) {
            message.put("params", params);
        }
        write(message);
    }

    /** Writes a diagnostic line to stderr, which the host keeps in its log. */
    public void log(String message) {
        errorOutput.println("[" + name + "] " + message);
    }

    /** Writes a diagnostic line and the failure's stack trace to stderr. */
    public void log(String message, Throwable error) {
        PrintStream stream = errorOutput;
        synchronized (stream) {
            stream.println("[" + name + "] " + message + " " + error);
            error.printStackTrace(stream);
        }
    }

    /**
     * Serves the host over stdio until it sends {@code exit} or closes stdin,
     * then exits the process with the session's exit code: 0 after a
     * {@code shutdown}, 1 otherwise. {@code System.out} is redirected to stderr
     * first, because stdout carries the protocol and a stray line there would
     * end the session.
     */
    public void listen() {
        OutputStream protocol = new FileOutputStream(FileDescriptor.out);
        System.setOut(System.err);
        int code = listen(System.in, protocol, System.err);
        System.exit(code);
    }

    /**
     * Serves the host over the given streams and returns the exit code once the
     * session ended, without exiting the process. Blocks the calling thread.
     */
    public int listen(InputStream input, OutputStream output, PrintStream errorOutput) {
        synchronized (lock) {
            if (phase != Phase.IDLE) {
                throw new PluginSdkError("sdk.listen.repeated", "A backend listens once.");
            }
            phase = Phase.LISTENING;
            this.output = output;
            this.errorOutput = errorOutput;
        }
        Framing.Decoder decoder = new Framing.Decoder();
        byte[] chunk = new byte[64 * 1024];
        try {
            while (phase != Phase.EXITED) {
                int count = input.read(chunk);
                if (count < 0) {
                    finish(phase == Phase.SHUTTING_DOWN ? 0 : 1);
                    break;
                }
                List<Object> messages;
                try {
                    messages = decoder.push(chunk, 0, count);
                } catch (Framing.FramingException error) {
                    log("Ending the session: " + error.getMessage());
                    finish(1);
                    break;
                }
                for (Object message : messages) {
                    if (phase == Phase.EXITED) {
                        break;
                    }
                    dispatch(message);
                }
            }
        } catch (IOException error) {
            finish(1);
        }
        synchronized (lock) {
            return exitCode;
        }
    }

    private void dispatch(Object message) {
        if (message == Framing.MALFORMED) {
            respond(null, null, error(Protocol.PARSE_ERROR, "The message is not valid JSON."));
            return;
        }
        // Valid JSON that is not a message object, such as `null` or a batch.
        if (!(message instanceof Map)) {
            respond(null, null, error(Protocol.INVALID_REQUEST, "The message is not a JSON-RPC object."));
            return;
        }
        Map<String, Object> object = Json.object(message);
        Object id = object.get("id");
        Object method = object.get("method");
        if (!(method instanceof String)) {
            if (id != null) {
                settleOutgoing(object);
            }
            return;
        }
        if (id != null) {
            handleRequest(id, (String) method, object.get("params"));
        } else {
            handleNotification((String) method, object.get("params"));
        }
    }

    private void handleRequest(Object id, String method, Object params) {
        if (method.equals(Protocol.INITIALIZE)) {
            initialize(id, params instanceof Map ? Json.object(params) : new LinkedHashMap<>());
            return;
        }
        if (method.equals(Protocol.SHUTDOWN)) {
            shutdown(id);
            return;
        }
        Phase current = phase;
        if (current == Phase.LISTENING || current == Phase.INITIALIZING) {
            respond(id, null, error(Protocol.SERVER_NOT_INITIALIZED, "The backend is not initialized."));
            return;
        }
        if (current != Phase.READY) {
            respond(id, null, error(Protocol.INVALID_REQUEST, "The backend is shutting down."));
            return;
        }
        if (method.equals(Protocol.FUNCTION_INVOKE)) {
            invokeFunction(id, params);
            return;
        }
        Handler build;
        RequestHandler handler;
        synchronized (lock) {
            build = negotiated.build() ? buildHandlers.get(method) : null;
            handler = requestHandlers.get(method);
        }
        if (build != null) {
            if (params != null && !(params instanceof Map)) {
                respond(id, null, error(Protocol.INVALID_PARAMS, method + " params must be an object."));
                return;
            }
            Map<String, Object> arguments = Json.object(params);
            run(id, null, null, context -> build.handle(arguments, context), result -> buildResult(method, result), null);
            return;
        }
        if (handler != null) {
            run(id, null, null, context -> handler.handle(params, context), result -> result, null);
            return;
        }
        respond(id, null, error(Protocol.METHOD_NOT_FOUND, "Unsupported method: " + method));
    }

    private void handleNotification(String method, Object params) {
        if (method.equals(Protocol.EXIT)) {
            finish(phase == Phase.SHUTTING_DOWN ? 0 : 1);
            return;
        }
        if (method.equals(Protocol.CANCEL_REQUEST)) {
            Object id = params instanceof Map ? ((Map<?, ?>) params).get("id") : null;
            Call call;
            synchronized (lock) {
                call = incoming.get(requestKey(id));
            }
            if (call != null) {
                call.cancellation.cancel("The request was cancelled.");
            }
            return;
        }
        if (phase != Phase.READY || method.equals(Protocol.INITIALIZED)) {
            return;
        }
        NotificationHandler handler;
        synchronized (lock) {
            handler = notificationHandlers.get(method);
        }
        if (handler == null) {
            return;
        }
        executor.execute(() -> {
            try {
                handler.handle(params);
            } catch (Throwable error) {
                log("Notification " + method + " failed:", error);
            }
        });
    }

    private void initialize(Object id, Map<String, Object> params) {
        Negotiated agreed;
        List<InitializeHook> hooks;
        synchronized (lock) {
            if (phase != Phase.LISTENING) {
                respond(id, null, error(Protocol.INVALID_REQUEST, "initialize was already received."));
                return;
            }
            phase = Phase.INITIALIZING;
            initializeParams = params;
            Map<String, Object> offered = experimental(params.get("capabilities"));
            agreed = new Negotiated(
                    offers(offered.get("litheFunctions"), Protocol.FUNCTIONS_VERSION),
                    !buildHandlers.isEmpty() && offers(offered.get("litheBuild"), Protocol.BUILD_VERSION));
            negotiated = agreed;
            hooks = new ArrayList<>(initializeHooks);
        }
        executor.execute(() -> {
            try {
                for (InitializeHook hook : hooks) {
                    hook.run(params, agreed);
                }
            } catch (Throwable failure) {
                log("initialize failed:", failure);
                synchronized (lock) {
                    if (phase == Phase.INITIALIZING) {
                        phase = Phase.LISTENING;
                    }
                }
                respond(id, null, toResponseError(failure, null));
                return;
            }
            synchronized (lock) {
                // A shutdown or exit that arrived while a hook ran ended the
                // session; finishing initialize must not reopen it.
                if (phase != Phase.INITIALIZING) {
                    respond(id, null, error(Protocol.INVALID_REQUEST, "The session ended during initialize."));
                    return;
                }
                if (!agreed.functions() && !functions.isEmpty()) {
                    log("The host did not offer litheFunctions version 1; functions stay unavailable.");
                }
                Map<String, Object> experimental = new LinkedHashMap<>(experimental(capabilities));
                if (agreed.build()) {
                    experimental.put("litheBuild", singleton("version", Protocol.BUILD_VERSION));
                }
                if (agreed.functions()) {
                    List<Object> offered = new ArrayList<>();
                    for (String functionId : functionIds()) {
                        offered.add(singleton("id", functionId));
                    }
                    Map<String, Object> entry = singleton("version", Protocol.FUNCTIONS_VERSION);
                    entry.put("functions", offered);
                    experimental.put("litheFunctions", entry);
                }
                Map<String, Object> answered = new LinkedHashMap<>(capabilities);
                answered.put("experimental", experimental);
                Map<String, Object> serverInfo = singleton("name", name);
                if (version != null) {
                    serverInfo.put("version", version);
                }
                Map<String, Object> result = singleton("capabilities", answered);
                result.put("serverInfo", serverInfo);
                phase = Phase.READY;
                respond(id, result, null);
            }
        });
    }

    private void shutdown(Object id) {
        List<ShutdownHook> hooks;
        synchronized (lock) {
            if (phase != Phase.READY && phase != Phase.LISTENING && phase != Phase.INITIALIZING) {
                respond(id, null, error(Protocol.INVALID_REQUEST, "shutdown was already received."));
                return;
            }
            phase = Phase.SHUTTING_DOWN;
            hooks = new ArrayList<>(shutdownHooks);
        }
        cancelAll("The backend is shutting down.");
        executor.execute(() -> {
            for (ShutdownHook hook : hooks) {
                try {
                    hook.run();
                } catch (Throwable error) {
                    log("A shutdown hook failed:", error);
                }
            }
            Processes.killAll();
            respond(id, null, null);
        });
    }

    private void invokeFunction(Object id, Object raw) {
        Map<String, Object> invocation = raw instanceof Map ? Json.object(raw) : new LinkedHashMap<>();
        Object functionId = invocation.get("functionID");
        Object operationId = invocation.get("operationID");
        Object params = invocation.get("params");
        Handler handler;
        synchronized (lock) {
            handler = negotiated.functions() && functionId instanceof String ? functions.get(functionId) : null;
        }
        if (handler == null) {
            respond(id, null, error(Protocol.INVALID_PARAMS, "Function " + functionId + " is not registered."));
            return;
        }
        if (params != null && !(params instanceof Map)) {
            respond(id, null, error(Protocol.INVALID_PARAMS, "Function " + functionId + " params must be an object."));
            return;
        }
        String function = (String) functionId;
        String operation = operationId instanceof String ? (String) operationId : null;
        Map<String, Object> arguments = Json.object(params);
        AtomicBoolean reporting = new AtomicBoolean(true);
        CallContext.ProgressSink progress = (message, percentage) -> {
            if (!reporting.get()) {
                return;
            }
            Map<String, Object> report = new LinkedHashMap<>();
            report.put("operationID", operationId);
            if (message != null) {
                report.put("message", Protocol.boundedText(message));
            }
            if (percentage != null && !percentage.isNaN() && !percentage.isInfinite()) {
                report.put("percentage", Math.min(100L, Math.max(0L, Math.round(percentage))));
            }
            Map<String, Object> notification = message(null, Protocol.FUNCTION_PROGRESS);
            notification.put("params", report);
            write(notification);
        };
        run(id, function, operation, context -> handler.handle(arguments, context), Backend::functionResult,
                () -> reporting.set(false), progress);
    }

    private interface Invocation {
        Object invoke(CallContext context) throws Exception;
    }

    private interface Shape {
        Object apply(Object result);
    }

    private void run(Object id, String functionId, String operationId, Invocation invoke, Shape shape, Runnable onSettled) {
        run(id, functionId, operationId, invoke, shape, onSettled, null);
    }

    /** Runs one handler with its own cancellation and answers exactly once. */
    private void run(Object id, String functionId, String operationId, Invocation invoke, Shape shape,
            Runnable onSettled, CallContext.ProgressSink progress) {
        Cancellation cancellation = new Cancellation();
        String key = requestKey(id);
        synchronized (lock) {
            incoming.put(key, new Call(cancellation, functionId));
        }
        CallContext context = new CallContext(cancellation, this, functionId, operationId, progress);
        executor.execute(() -> {
            Object result = null;
            Map<String, Object> error = null;
            try {
                Object value = invoke.invoke(context);
                cancellation.throwIfCancelled();
                result = shape.apply(value);
            } catch (Throwable failure) {
                if (!cancellation.isCancelled()) {
                    log((functionId != null ? "Function " + functionId : "A request") + " failed:", failure);
                }
                error = toResponseError(failure, cancellation);
            }
            try {
                if (onSettled != null) {
                    onSettled.run();
                }
            } finally {
                synchronized (lock) {
                    incoming.remove(key);
                }
                // Work belongs to its call: tools still running when the handler
                // returned end now. Other calls have their own cancellation.
                cancellation.cancel("The call ended.");
                // Answered whatever the clean-up did, so Lithe never waits for
                // its timeout.
                respond(id, result, error);
            }
        });
    }

    private Backend declareBuild(String method, Handler handler) {
        if (handler == null) {
            throw new IllegalArgumentException("A build handler must not be null.");
        }
        synchronized (lock) {
            if (phase != Phase.IDLE) {
                throw new PluginSdkError("sdk.build.lateDeclaration", "Declare build handlers before listen().");
            }
            buildHandlers.put(method, handler);
        }
        return this;
    }

    private static void checkDeclared(String method, Object handler) {
        if (method == null || Protocol.isReservedMethod(method)) {
            throw new PluginSdkError("sdk.method.reserved", method + " is managed by the SDK and Lithe.");
        }
        if (handler == null) {
            throw new IllegalArgumentException("A handler must not be null.");
        }
    }

    private void checkNewFunction(String id, Handler handler) {
        if (!Protocol.isFunctionId(id)) {
            throw new PluginSdkError("sdk.function.invalidID", "Function ID \"" + id
                    + "\" must be dot-separated lowerCamelCase segments of at most 128 bytes.");
        }
        if (handler == null) {
            throw new IllegalArgumentException("A function handler must not be null.");
        }
        if (functions.containsKey(id)) {
            throw new PluginSdkError("sdk.function.duplicate", "Function " + id + " is already declared.");
        }
        if (functions.size() >= Protocol.MAX_FUNCTIONS) {
            throw new PluginSdkError("sdk.function.limit",
                    "A backend serves at most " + Protocol.MAX_FUNCTIONS + " functions.");
        }
    }

    /** True until the {@code initialize} answer fixes the initial function list. */
    private boolean beforeAnswer() {
        return phase == Phase.IDLE || phase == Phase.LISTENING || phase == Phase.INITIALIZING;
    }

    private void requireFunctions() {
        if (phase != Phase.READY || !negotiated.functions()) {
            throw new PluginSdkError("sdk.functions.unavailable", "The host has not negotiated plugin functions.");
        }
    }

    private static PluginSdkError unknownFunction(String id) {
        return new PluginSdkError("sdk.function.unknown", "Function " + id + " is not registered.");
    }

    private CompletableFuture<Void> queueRegistration(Supplier<CompletableFuture<Void>> change) {
        synchronized (lock) {
            CompletableFuture<Void> next = registrations.thenComposeAsync(ignored -> {
                try {
                    return change.get();
                } catch (RuntimeException error) {
                    return failed(error);
                }
            }, executor);
            registrations = next.handle((result, error) -> null);
            return next;
        }
    }

    private void checkOutgoing(String method) {
        if (method == null || Protocol.isReservedMethod(method)) {
            throw new PluginSdkError("sdk.method.reserved", method
                    + " is reserved. A backend never asks the host to run a domain operation or a function.");
        }
        if (phase != Phase.READY) {
            throw new PluginSdkError("sdk.session.notReady", "The session is not initialized.");
        }
    }

    private CompletableFuture<Object> request(String method, Object params) {
        String id = "sdk-" + nextRequestId.getAndIncrement();
        CompletableFuture<Object> future = new CompletableFuture<>();
        synchronized (lock) {
            if (phase == Phase.EXITED) {
                future.completeExceptionally(new PluginSdkError("sdk.session.closed", "The session ended."));
                return future;
            }
            outgoing.put(id, new Pending(future, method));
        }
        Map<String, Object> message = message(id, method);
        if (params != null) {
            message.put("params", params);
        }
        write(message);
        return future;
    }

    private void settleOutgoing(Map<String, Object> message) {
        Object id = message.get("id");
        Pending pending;
        synchronized (lock) {
            pending = id instanceof String ? outgoing.remove(id) : null;
        }
        if (pending == null) {
            return;
        }
        Object error = message.get("error");
        // Completed on a handler thread: the reader thread never runs plugin code.
        if (error instanceof Map) {
            Map<String, Object> failure = Json.object(error);
            Object data = failure.get("data");
            String code = data instanceof Map ? Json.string(Json.object(data), "code") : null;
            String text = Json.string(failure, "message");
            Object rpcCode = failure.get("code");
            PluginSdkError rejection = new PluginSdkError(
                    code == null ? "sdk.host.error" : code,
                    text == null ? pending.method + " failed." : text,
                    rpcCode instanceof Number ? ((Number) rpcCode).intValue() : null);
            executor.execute(() -> pending.future.completeExceptionally(rejection));
        } else {
            Object result = message.get("result");
            executor.execute(() -> pending.future.complete(result));
        }
    }

    private void cancelAll(String reason) {
        List<Call> calls;
        synchronized (lock) {
            calls = new ArrayList<>(incoming.values());
        }
        for (Call call : calls) {
            call.cancellation.cancel(reason);
        }
    }

    private void finish(int code) {
        List<Pending> pending;
        synchronized (lock) {
            if (phase == Phase.EXITED) {
                return;
            }
            phase = Phase.EXITED;
            exitCode = code;
            pending = new ArrayList<>(outgoing.values());
            outgoing.clear();
        }
        cancelAll("The session ended.");
        Processes.killAll();
        for (Pending request : pending) {
            request.future.completeExceptionally(new PluginSdkError("sdk.session.closed", "The session ended."));
        }
        // Running handlers finish on their own threads; nothing new starts.
        executor.shutdown();
    }

    private void respond(Object id, Object result, Map<String, Object> error) {
        if (phase == Phase.EXITED) {
            return;
        }
        Map<String, Object> message = message(id, null);
        if (error != null) {
            message.put("error", error);
        } else {
            message.put("result", result);
        }
        try {
            writeEncoded(Framing.encode(message));
        } catch (Json.JsonException failure) {
            // A result JSON cannot encode must not end the session.
            log("The result could not be encoded:", failure);
            Map<String, Object> fallback = message(id, null);
            fallback.put("error", toResponseError(failure, null));
            write(fallback);
        }
    }

    private void write(Map<String, Object> message) {
        writeEncoded(Framing.encode(message));
    }

    private void writeEncoded(byte[] frame) {
        synchronized (writeLock) {
            OutputStream stream = output;
            if (stream == null || phase == Phase.EXITED) {
                return;
            }
            try {
                stream.write(frame);
                stream.flush();
            } catch (IOException error) {
                // The host closed the pipe; the input side ends the session.
                log("Writing to the host failed: " + error.getMessage());
            }
        }
    }

    /**
     * The JSON-RPC error object for a handler failure. Only {@link PluginError}
     * carries a plugin code; any other exception becomes a generic internal
     * error so that stack traces and machine paths never reach the host's UI.
     */
    static Map<String, Object> toResponseError(Throwable failure, Cancellation cancellation) {
        Throwable error = unwrap(failure);
        if (cancellation != null && cancellation.isCancelled() && error instanceof CancelledException) {
            return error(Protocol.REQUEST_CANCELLED, "The request was cancelled.");
        }
        if (error instanceof PluginError) {
            Map<String, Object> response = error(Protocol.REQUEST_FAILED, Protocol.boundedText(error.getMessage()));
            response.put("data", singleton("code", ((PluginError) error).code()));
            return response;
        }
        // Unexpected exceptions often embed absolute paths or internals; the
        // caller logs the details to stderr instead.
        return error(Protocol.INTERNAL_ERROR, "The plugin backend failed unexpectedly.");
    }

    /**
     * Stamps the canonical format on a build result, so a handler can return the
     * plain document. A result in another format is a backend bug: Core would
     * refuse it as {@code plugin.build.invalidOutput}, so it fails here with a log.
     */
    static Object buildResult(String method, Object result) {
        String expected = BUILD_FORMATS.get(method);
        if (!(result instanceof Map)) {
            throw new PluginSdkError("sdk.build.invalidResult", method + " must return a " + expected + " object.");
        }
        Map<String, Object> document = new LinkedHashMap<>(Json.object(result));
        Object format = document.get("format");
        if (format != null && !expected.equals(format)) {
            throw new PluginSdkError("sdk.build.invalidResult",
                    method + " returned format " + format + ", not " + expected + ".");
        }
        Object version = document.get("version");
        if (version != null && !(version instanceof Number && ((Number) version).doubleValue() == 1)) {
            throw new PluginSdkError("sdk.build.invalidResult", method + " returned version " + version + ", not 1.");
        }
        document.put("format", expected);
        document.put("version", 1);
        return document;
    }

    /**
     * A function result as the JSON value Core accepts. A value JSON cannot
     * encode, or one over Core's 1 MiB limit, fails here as a backend bug with a
     * log line, instead of breaking the response frame or being refused by Core.
     */
    static Object functionResult(Object result) {
        String encoded;
        try {
            encoded = Json.stringify(result);
        } catch (Json.JsonException error) {
            throw new PluginSdkError("sdk.function.invalidResult", "The result is not JSON: " + error.getMessage());
        }
        if (encoded.getBytes(StandardCharsets.UTF_8).length > Protocol.MAX_RESULT_BYTES) {
            throw new PluginSdkError("sdk.function.invalidResult",
                    "The result exceeds " + Protocol.MAX_RESULT_BYTES + " bytes.");
        }
        return result;
    }

    private static boolean offers(Object entry, int version) {
        if (!(entry instanceof Map)) {
            return false;
        }
        Object versions = ((Map<?, ?>) entry).get("versions");
        if (!(versions instanceof List)) {
            return false;
        }
        for (Object offered : (List<?>) versions) {
            if (offered instanceof Number && ((Number) offered).doubleValue() == version) {
                return true;
            }
        }
        return false;
    }

    /** {@code capabilities.experimental}, or an empty map. */
    private static Map<String, Object> experimental(Object capabilities) {
        Object experimental = capabilities instanceof Map ? ((Map<?, ?>) capabilities).get("experimental") : null;
        return experimental instanceof Map ? Json.object(experimental) : Collections.<String, Object>emptyMap();
    }

    /** The JSON-RPC ID as a map key; numbers and strings never collide. */
    private static String requestKey(Object id) {
        if (id instanceof Number) {
            Number number = (Number) id;
            return "number:" + (number.doubleValue() == number.longValue() ? Long.toString(number.longValue()) : number);
        }
        return (id instanceof String ? "string:" : "other:") + id;
    }

    private static Map<String, Object> message(Object id, String method) {
        Map<String, Object> message = new LinkedHashMap<>();
        message.put("jsonrpc", "2.0");
        if (id != null || method == null) {
            message.put("id", id);
        }
        if (method != null) {
            message.put("method", method);
        }
        return message;
    }

    private static Map<String, Object> error(int code, String text) {
        Map<String, Object> error = new LinkedHashMap<>();
        error.put("code", code);
        error.put("message", text);
        return error;
    }

    private static Map<String, Object> singleton(String key, Object value) {
        Map<String, Object> map = new LinkedHashMap<>();
        map.put(key, value);
        return map;
    }

    private static Throwable unwrap(Throwable error) {
        Throwable current = error;
        while (current instanceof CompletionException && current.getCause() != null) {
            current = current.getCause();
        }
        return current;
    }

    private static <T> CompletableFuture<T> failed(Throwable error) {
        CompletableFuture<T> future = new CompletableFuture<>();
        future.completeExceptionally(error);
        return future;
    }

    /** One host request being handled. */
    private static final class Call {
        final Cancellation cancellation;
        final String functionId;

        Call(Cancellation cancellation, String functionId) {
            this.cancellation = cancellation;
            this.functionId = functionId;
        }
    }

    /** One request this backend sent to the host. */
    private static final class Pending {
        final CompletableFuture<Object> future;
        final String method;

        Pending(CompletableFuture<Object> future, String method) {
            this.future = future;
            this.method = method;
        }
    }

    /** Daemon threads, so a handler still running never keeps the process alive after exit. */
    private static final class ThreadNamer implements java.util.concurrent.ThreadFactory {
        private final AtomicInteger next = new AtomicInteger(1);

        @Override
        public Thread newThread(Runnable runnable) {
            Thread thread = new Thread(runnable, "lithe-sdk-call-" + next.getAndIncrement());
            thread.setDaemon(true);
            return thread;
        }
    }
}
