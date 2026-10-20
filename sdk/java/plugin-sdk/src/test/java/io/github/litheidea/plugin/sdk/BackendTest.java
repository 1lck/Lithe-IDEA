package io.github.litheidea.plugin.sdk;

import static io.github.litheidea.plugin.sdk.Fixtures.map;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionException;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;

/** Protocol behaviour of {@link Backend}; mirrors {@code sdk/node/test/backend.test.mjs}. */
@Timeout(value = 30, unit = TimeUnit.SECONDS)
class BackendTest {
    private static Backend functionBackend() {
        return Backend.create("test-backend", "1.0.0")
                .function("snapshot.refresh", (params, context) -> map("echoed", params))
                .function("install.prepare", (params, context) -> null);
    }

    private static Map<String, Object> invoke(String functionId, String operationId, Object params) {
        return map("functionID", functionId, "operationID", operationId, "params", params);
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> object(Object value) {
        return (Map<String, Object>) value;
    }

    private static Object errorCode(Map<String, Object> response) {
        Object error = response.get("error");
        return error == null ? null : object(error).get("code");
    }

    @Test
    void initializeAnswersTheOfferedProtocolsWithSortedFunctions() {
        Backend backend = functionBackend().onModel((params, context) -> map("projects", Collections.emptyList()));
        TestHost host = new TestHost(backend);
        Map<String, Object> result = object(host.initialize().get("result"));
        assertEquals(
                map("litheBuild", map("version", 1L),
                        "litheFunctions", map("version", 1L, "functions",
                                Arrays.asList(map("id", "install.prepare"), map("id", "snapshot.refresh")))),
                object(result.get("capabilities")).get("experimental"));
        assertEquals(map("name", "test-backend", "version", "1.0.0"), result.get("serverInfo"));
        assertTrue(backend.negotiated().functions());
        assertTrue(backend.negotiated().build());
        assertEquals(1, host.close());
    }

    @Test
    void aHostThatOffersNothingGetsNoLitheCapabilities() {
        TestHost quiet = new TestHost(functionBackend());
        assertEquals(map(), object(object(quiet.initialize(map()).get("result")).get("capabilities")).get("experimental"));
        quiet.close();

        // No build handler: litheBuild is never claimed. Version 2 only: no functions.
        TestHost other = new TestHost(functionBackend());
        Map<String, Object> answer = object(other.initialize(map(
                "litheBuild", map("versions", Arrays.asList(1L)),
                "litheFunctions", map("versions", Arrays.asList(2L)))).get("result"));
        assertEquals(map(), object(answer.get("capabilities")).get("experimental"));
        other.close();
    }

    @Test
    void functionIdsFollowTheSharedContractIncludingTheFixtureCases() throws IOException {
        for (String id : Arrays.asList("snapshot.refresh", "install.prepare", "a", "x1.y2Z")) {
            assertTrue(Protocol.isFunctionId(id), id);
        }
        StringBuilder long129 = new StringBuilder();
        for (int index = 0; index < 129; index++) {
            long129.append('a');
        }
        for (String id : Arrays.asList("", "Not-Valid", "snapshot..refresh", "1abc", "a_b", "é", long129.toString(), "a.")) {
            assertFalse(Protocol.isFunctionId(id), id);
        }
        // Every ID the fixture accepts is accepted locally, and the fixture's
        // malformed ID refused, so the SDK never declares what Core rejects.
        Map<String, Object> fixture = object(Json.parse(new String(Files.readAllBytes(
                Paths.get("../../../shared/contracts/plugins/v1/fixtures/function-protocol.json")), StandardCharsets.UTF_8)));
        for (Object entry : (List<?>) fixture.get("negotiation")) {
            Map<String, Object> testCase = object(entry);
            List<String> ids = new ArrayList<>();
            Object experimental = object(testCase.get("capabilities")).get("experimental");
            Object functions = experimental == null ? null : object(experimental).get("litheFunctions");
            Object declared = functions == null ? null : object(functions).get("functions");
            if (declared != null) {
                for (Object function : (List<?>) declared) {
                    ids.add((String) object(function).get("id"));
                }
            }
            String name = (String) testCase.get("name");
            if (name.contains("malformed")) {
                assertTrue(ids.stream().anyMatch(id -> !Protocol.isFunctionId(id)), name);
            } else if (object(testCase.get("expected")).get("functions") != null) {
                assertTrue(ids.stream().allMatch(Protocol::isFunctionId), name);
            }
        }
        PluginSdkError invalid = assertThrows(PluginSdkError.class,
                () -> Backend.create(null, null).function("Bad-ID", (params, context) -> null));
        assertEquals("sdk.function.invalidID", invalid.code());
        PluginSdkError duplicate = assertThrows(PluginSdkError.class, () -> Backend.create(null, null)
                .function("a", (params, context) -> null)
                .function("a", (params, context) -> null));
        assertEquals("sdk.function.duplicate", duplicate.code());
    }

    @Test
    void theLifecycleAndTheLitheNamespaceStayReservedForTheSdk() {
        Backend backend = Backend.create(null, null);
        for (String method : Arrays.asList("initialize", "shutdown", "exit", "$/cancelRequest", "lithe/build/model", "lithe/anything")) {
            assertThrows(PluginSdkError.class, () -> backend.onRequest(method, (params, context) -> null), method);
        }
        PluginSdkError reserved = assertThrows(PluginSdkError.class, () -> Backend.create(null, null,
                map("experimental", map("litheFunctions", map("version", 1)))));
        assertEquals("sdk.capabilities.reserved", reserved.code());
        TestHost host = new TestHost(backend);
        host.initialize();
        // A backend never asks the host to dispatch a domain operation or a function.
        for (String method : Arrays.asList("lithe/function/invoke", "lithe/build/model", "lithe/host/process.run")) {
            PluginSdkError error = assertThrows(PluginSdkError.class, () -> backend.sendRequest(method, map()), method);
            assertEquals("sdk.method.reserved", error.code());
        }
        host.close();
    }

    @Test
    void requestsBeforeInitializeAreRefusedWithServerNotInitialized() {
        TestHost host = new TestHost(functionBackend());
        Map<String, Object> response = host.request("lithe/function/invoke", invoke("snapshot.refresh", "op", map()));
        assertEquals(-32002L, errorCode(response));
        host.close();
    }

    @Test
    void anInvocationReturnsItsResultAndNullStaysNull() {
        TestHost host = new TestHost(functionBackend());
        host.initialize();
        Map<String, Object> response = host.request("lithe/function/invoke",
                invoke("snapshot.refresh", "op-1", map("project", "app")));
        assertEquals(map("echoed", map("project", "app")), response.get("result"));
        Map<String, Object> empty = host.request("lithe/function/invoke", invoke("install.prepare", "op-2", null));
        assertTrue(empty.containsKey("result"));
        assertNull(empty.get("result"));
        Map<String, Object> unknown = host.request("lithe/function/invoke", invoke("missing", "op-3", null));
        assertEquals(-32602L, errorCode(unknown));
        host.close();
    }

    @Test
    void progressEchoesTheOperationIsBoundedAndStopsOnceTheCallEnded() {
        CountDownLatch release = new CountDownLatch(1);
        AtomicReference<CallContext> late = new AtomicReference<>();
        StringBuilder longMessage = new StringBuilder();
        for (int index = 0; index < 2000; index++) {
            longMessage.append('x');
        }
        Backend backend = Backend.create(null, null).function("long.task", (params, context) -> {
            context.progress(longMessage.toString(), 140.4);
            context.progress("half", 49.6);
            late.set(context);
            Fixtures.await(release, "the test to release the call");
            return "done";
        });
        TestHost host = new TestHost(backend);
        host.initialize();
        CompletableFuture<Map<String, Object>> response = host.requestAsync("lithe/function/invoke",
                invoke("long.task", "wire-7", null), 1001L);
        Map<String, Object> first = object(host.waitFor(
                message -> "lithe/function/progress".equals(message.get("method")), "progress").get("params"));
        assertEquals("wire-7", first.get("operationID"));
        assertEquals(1024, ((String) first.get("message")).length());
        assertEquals(100L, first.get("percentage"));
        Map<String, Object> second = object(host.waitFor(message -> message.get("params") instanceof Map
                && "half".equals(object(message.get("params")).get("message")), "the second report").get("params"));
        assertEquals(50L, second.get("percentage"));
        release.countDown();
        assertEquals("done", Fixtures.await(response, "the response").get("result"));
        late.get().progress("too late", null);
        host.close();
        assertTrue(host.messages().stream().noneMatch(message -> message.get("params") instanceof Map
                && "too late".equals(object(message.get("params")).get("message"))));
    }

    @Test
    void aPluginErrorCarriesItsCodeAndOtherFailuresHideTheirDetails() {
        Backend backend = Backend.create(null, null)
                .function("locked", (params, context) -> {
                    throw new PluginError("maven.snapshotLocked", "Snapshot is locked.");
                })
                .function("crash", (params, context) -> {
                    throw new IOException("No such file: /Users/someone/secret");
                });
        TestHost host = new TestHost(backend);
        host.initialize();
        Map<String, Object> locked = host.request("lithe/function/invoke", invoke("locked", "a", null));
        assertEquals(map("code", -32000L, "message", "Snapshot is locked.", "data", map("code", "maven.snapshotLocked")),
                locked.get("error"));
        Map<String, Object> crash = object(host.request("lithe/function/invoke", invoke("crash", "b", null)).get("error"));
        assertEquals(-32603L, crash.get("code"));
        assertFalse(((String) crash.get("message")).contains("/Users/"));
        assertFalse(crash.containsKey("data"));
        assertThrows(IllegalArgumentException.class, () -> new PluginError("bad code!", "x"));
        host.close();
    }

    @Test
    void aFailingCancellationListenerNeitherSkipsTheOthersNorTheReply() {
        CountDownLatch laterListenerRan = new CountDownLatch(1);
        CountDownLatch started = new CountDownLatch(1);
        CountDownLatch cancelled = new CountDownLatch(1);
        Backend backend = Backend.create(null, null)
                .function("listener.settles", (params, context) -> {
                    context.cancellation().onCancel(() -> {
                        throw new IllegalStateException("clean-up failed");
                    });
                    context.cancellation().onCancel(laterListenerRan::countDown);
                    return "ok";
                })
                .function("listener.cancelled", (params, context) -> {
                    context.cancellation().onCancel(() -> {
                        throw new IllegalStateException("clean-up failed");
                    });
                    context.cancellation().onCancel(cancelled::countDown);
                    started.countDown();
                    Fixtures.await(cancelled, "the cancellation");
                    context.throwIfCancelled();
                    return "not reached";
                });
        TestHost host = new TestHost(backend);
        host.initialize();
        // The call ending runs the listeners before the reply.
        assertEquals("ok", host.request("lithe/function/invoke", invoke("listener.settles", "s", null)).get("result"));
        Fixtures.await(laterListenerRan, "the listener after the failing one");
        // $/cancelRequest runs them on the read loop, which must keep reading.
        CompletableFuture<Map<String, Object>> response = host.requestAsync("lithe/function/invoke",
                invoke("listener.cancelled", "c", null), 42L);
        Fixtures.await(started, "the handler to start");
        host.notify("$/cancelRequest", map("id", 42L));
        assertEquals(-32800L, errorCode(Fixtures.await(response, "the cancelled call")));
        assertEquals("ok", host.request("lithe/function/invoke", invoke("listener.settles", "t", null)).get("result"));
        host.close();
    }

    @Test
    void cancelRequestCancelsTheHandlerAndAnswersRequestCancelled() {
        CountDownLatch started = new CountDownLatch(1);
        CountDownLatch cancelled = new CountDownLatch(1);
        Backend backend = Backend.create(null, null).function("wait.forever", (params, context) -> {
            context.cancellation().onCancel(cancelled::countDown);
            started.countDown();
            Fixtures.await(cancelled, "the cancellation");
            context.throwIfCancelled();
            return "not reached";
        });
        TestHost host = new TestHost(backend);
        host.initialize();
        CompletableFuture<Map<String, Object>> response = host.requestAsync("lithe/function/invoke",
                invoke("wait.forever", "c", null), 41L);
        Fixtures.await(started, "the handler to start");
        host.notify("$/cancelRequest", map("id", 41L));
        assertEquals(-32800L, errorCode(Fixtures.await(response, "the response")));
        host.close();
    }

    @Test
    void registerAndUnregisterFunctionGoThroughTheHostAllOrNothing() throws Exception {
        Backend backend = Backend.create(null, null);
        TestHost host = new TestHost(backend);
        host.initialize();

        CompletableFuture<Void> registering = backend.registerFunction("late.one", (params, context) -> "late");
        Map<String, Object> register = host.waitFor(
                message -> "lithe/function/register".equals(message.get("method")), "the registration");
        assertEquals(map("functions", Arrays.asList(map("id", "late.one"))), register.get("params"));
        host.send(map("id", register.get("id"), "result", null));
        Fixtures.await(registering, "the registration to settle");
        assertEquals("late", host.request("lithe/function/invoke", invoke("late.one", "d", null)).get("result"));

        // A refused registration leaves no handler behind.
        CompletableFuture<Void> refused = backend.registerFunction("other.one", (params, context) -> 0);
        Map<String, Object> second = host.waitFor(message -> "lithe/function/register".equals(message.get("method"))
                && object(message.get("params")).toString().contains("other.one"), "the second registration");
        host.send(map("id", second.get("id"), "error",
                map("code", -32602L, "message", "No.", "data", map("code", "plugin.function.invalidRegistration"))));
        ExecutionException failure = assertThrows(ExecutionException.class,
                () -> refused.get(TestHost.WAIT_MILLIS, TimeUnit.MILLISECONDS));
        assertEquals("plugin.function.invalidRegistration", ((PluginSdkError) unwrap(failure)).code());
        assertEquals(Arrays.asList("late.one"), backend.functionIds());

        CompletableFuture<Void> unregistering = backend.unregisterFunction("late.one");
        Map<String, Object> unregister = host.waitFor(
                message -> "lithe/function/unregister".equals(message.get("method")), "the withdrawal");
        assertEquals(map("ids", Arrays.asList("late.one")), unregister.get("params"));
        host.send(map("id", unregister.get("id"), "result", null));
        Fixtures.await(unregistering, "the withdrawal to settle");
        assertEquals(Collections.emptyList(), backend.functionIds());
        host.close();
    }

    @Test
    void buildHandlersGetTheCanonicalFormatStampedAndAWrongFormatFails() {
        Backend backend = Backend.create(null, null)
                .onModel((params, context) -> map("projects", Arrays.asList(map("name", "app", "path", params.get("root")))))
                .onDependencies((params, context) -> map("format", "litheBuildModel", "projects", Collections.emptyList()));
        TestHost host = new TestHost(backend);
        host.initialize();
        Map<String, Object> model = host.request("lithe/build/model", map("buildSystemID", "sample", "root", "."));
        assertEquals(map("projects", Arrays.asList(map("name", "app", "path", ".")), "format", "litheBuildModel", "version", 1L),
                model.get("result"));
        Map<String, Object> dependencies = host.request("lithe/build/dependencies", map("buildSystemID", "sample", "root", "."));
        assertEquals(-32603L, errorCode(dependencies));
        host.close();
    }

    @Test
    void aBuildResultCannotReplaceTheVersionTheSdkStamps() {
        Backend backend = Backend.create(null, null)
                .onModel((params, context) -> map("version", 2, "projects", Collections.emptyList()))
                .onDependencies((params, context) -> map("version", 1, "dependencies", Collections.emptyList()));
        TestHost host = new TestHost(backend);
        host.initialize();
        assertEquals(-32603L, errorCode(host.request("lithe/build/model", map("buildSystemID", "sample", "root", "."))));
        assertEquals(map("version", 1L, "dependencies", Collections.emptyList(), "format", "litheDependencies"),
                host.request("lithe/build/dependencies", map("buildSystemID", "sample", "root", ".")).get("result"));
        host.close();
    }

    @Test
    void aResultJsonCannotEncodeOrOneOverOneMebibyteFailsAndTheSessionContinues() {
        Map<String, Object> cycle = map();
        cycle.put("self", cycle);
        char[] large = new char[1 << 20];
        Arrays.fill(large, 'x');
        Backend backend = Backend.create(null, null)
                .function("result.object", (params, context) -> new Object())
                .function("result.cycle", (params, context) -> cycle)
                .function("result.nan", (params, context) -> Double.NaN)
                .function("result.large", (params, context) -> new String(large))
                .function("result.fine", (params, context) -> map("ok", true))
                .onModel((params, context) -> map("projects", Arrays.asList(map("name", "app", "path", ".", "size", new Object()))));
        TestHost host = new TestHost(backend);
        host.initialize();
        int operation = 0;
        for (String functionId : Arrays.asList("result.object", "result.cycle", "result.nan", "result.large")) {
            Map<String, Object> response = host.request("lithe/function/invoke", invoke(functionId, "op-" + operation++, null));
            assertEquals(-32603L, errorCode(response), functionId);
        }
        assertEquals(-32603L, errorCode(host.request("lithe/build/model", map("buildSystemID", "sample", "root", "."))));
        assertEquals(map("ok", true), host.request("lithe/function/invoke", invoke("result.fine", "op-last", null)).get("result"));
        assertEquals(1, host.close());
    }

    @Test
    void buildRequestsAreRefusedWhenTheHostDidNotNegotiateLitheBuild() {
        Backend backend = Backend.create(null, null).onModel((params, context) -> map("projects", Collections.emptyList()));
        TestHost host = new TestHost(backend);
        host.initialize(map("litheFunctions", map("versions", Arrays.asList(1L))));
        assertEquals(-32601L, errorCode(host.request("lithe/build/model", map("buildSystemID", "sample", "root", "."))));
        host.close();
    }

    @Test
    void shutdownCancelsRunningCallsAndRunsHooksAndExitAfterShutdownIsZero() {
        CountDownLatch started = new CountDownLatch(1);
        List<String> order = Collections.synchronizedList(new ArrayList<>());
        Backend backend = Backend.create(null, null)
                .function("wait.forever", (params, context) -> {
                    CountDownLatch cancelled = new CountDownLatch(1);
                    context.cancellation().onCancel(cancelled::countDown);
                    started.countDown();
                    Fixtures.await(cancelled, "the shutdown to cancel the call");
                    context.throwIfCancelled();
                    return null;
                })
                .onShutdown(() -> order.add("hook"));
        TestHost host = new TestHost(backend);
        host.initialize();
        CompletableFuture<Map<String, Object>> call = host.requestAsync("lithe/function/invoke",
                invoke("wait.forever", "e", null), 2001L);
        Fixtures.await(started, "the handler to start");
        Map<String, Object> shutdown = host.request("shutdown", null);
        assertTrue(shutdown.containsKey("result"));
        assertNull(shutdown.get("result"));
        assertEquals(-32800L, errorCode(Fixtures.await(call, "the cancelled call")));
        assertEquals(Arrays.asList("hook"), order);
        assertEquals(-32600L, errorCode(host.request("lithe/function/invoke", invoke("wait.forever", "f", null))));
        host.notify("exit", null);
        assertEquals(0, host.exitCode());
    }

    @Test
    void exitWithoutShutdownOrAClosedInputEndsWithCodeOne() {
        TestHost host = new TestHost(Backend.create(null, null));
        host.initialize();
        host.notify("exit", null);
        assertEquals(1, host.exitCode());
        assertEquals(1, new TestHost(Backend.create(null, null)).close());
    }

    @Test
    void aMalformedBodyIsAnsweredWithAParseErrorAndTheSessionContinues() {
        TestHost host = new TestHost(functionBackend());
        byte[] body = "{not json".getBytes(StandardCharsets.UTF_8);
        host.sendBytes(("Content-Length: " + body.length + "\r\n\r\n{not json").getBytes(StandardCharsets.UTF_8));
        Map<String, Object> parseError = host.waitFor(message -> message.get("error") instanceof Map
                && Long.valueOf(-32700L).equals(object(message.get("error")).get("code")), "the parse error");
        assertTrue(parseError.containsKey("id"));
        assertNull(parseError.get("id"));
        assertNotNull(host.initialize().get("result"));
        host.close();
    }

    @Test
    void aJsonValueThatIsNotAMessageObjectIsRefusedAndTheSessionContinues() {
        TestHost host = new TestHost(functionBackend());
        host.sendBytes(Framing.encode(Arrays.asList(1, 2)));
        host.waitFor(message -> message.get("error") instanceof Map
                && Long.valueOf(-32600L).equals(object(message.get("error")).get("code")), "the refusal");
        assertNotNull(host.initialize().get("result"));
        host.close();
    }

    @Test
    void registeringFromAnInitializeHookJoinsTheInitialListWithoutARequest() {
        Backend backend = Backend.create(null, null).function("a.one", (params, context) -> 1);
        backend.onInitialize((params, negotiated) -> {
            backend.registerFunction("b.two", (arguments, context) -> 2);
            backend.unregisterFunction("a.one");
        });
        TestHost host = new TestHost(backend);
        Map<String, Object> experimental = object(object(object(host.initialize().get("result")).get("capabilities")).get("experimental"));
        assertEquals(Arrays.asList(map("id", "b.two")), object(experimental.get("litheFunctions")).get("functions"));
        assertTrue(host.messages().stream().noneMatch(message -> message.get("method") instanceof String
                && ((String) message.get("method")).startsWith("lithe/function/")));
        host.close();
    }

    @Test
    void runtimeRegistrationNeedsTheNegotiatedProtocol() {
        Backend backend = Backend.create(null, null);
        TestHost host = new TestHost(backend);
        host.initialize(map());
        ExecutionException failure = assertThrows(ExecutionException.class, () -> backend
                .registerFunction("late.one", (params, context) -> 1).get(TestHost.WAIT_MILLIS, TimeUnit.MILLISECONDS));
        assertEquals("sdk.functions.unavailable", ((PluginSdkError) unwrap(failure)).code());
        host.close();
    }

    @Test
    void aShutdownDuringASlowInitializeHookKeepsTheSessionClosed() {
        CountDownLatch hookStarted = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        Backend backend = Backend.create(null, null).onInitialize((params, negotiated) -> {
            hookStarted.countDown();
            Fixtures.await(release, "the test to release initialize");
        });
        TestHost host = new TestHost(backend);
        CompletableFuture<Map<String, Object>> initialize = host.requestAsync("initialize",
                map("capabilities", map()), 3001L);
        Fixtures.await(hookStarted, "the initialize hook");
        assertNull(host.request("shutdown", null).get("error"));
        release.countDown();
        assertEquals(-32600L, errorCode(Fixtures.await(initialize, "the initialize answer")));
        assertEquals(-32600L, errorCode(host.request("lithe/function/invoke", invoke("x", "y", null))));
        host.notify("exit", null);
        assertEquals(0, host.exitCode());
    }

    @Test
    void notificationsReachTheirHandlerOnlyOnceReady() {
        CountDownLatch received = new CountDownLatch(1);
        AtomicBoolean early = new AtomicBoolean();
        Backend backend = Backend.create(null, null).onNotification("workspace/didChangeConfiguration", params -> {
            if (!(params instanceof Map)) {
                early.set(true);
            }
            received.countDown();
        });
        TestHost host = new TestHost(backend);
        host.notify("workspace/didChangeConfiguration", "before");
        host.initialize();
        host.notify("workspace/didChangeConfiguration", map("settings", map()));
        Fixtures.await(received, "the notification");
        assertFalse(early.get());
        host.close();
    }

    private static Throwable unwrap(Throwable error) {
        Throwable current = error;
        while ((current instanceof ExecutionException || current instanceof CompletionException) && current.getCause() != null) {
            current = current.getCause();
        }
        return current;
    }
}
