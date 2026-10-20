package io.github.litheidea.plugin.sdk;

import static io.github.litheidea.plugin.sdk.Fixtures.map;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import java.io.IOException;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.stream.Collectors;
import java.util.stream.Stream;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.api.condition.DisabledOnOs;
import org.junit.jupiter.api.condition.OS;

/** Framing, JSON, tools, and state; mirrors {@code sdk/node/test/support.test.mjs}. */
@Timeout(value = 30, unit = TimeUnit.SECONDS)
class SupportTest {
    private Path directory;

    @BeforeEach
    void createDirectory() throws IOException {
        directory = Files.createTempDirectory("lithe-sdk-").toRealPath();
    }

    @AfterEach
    void removeDirectory() {
        Processes.killAll();
        Fixtures.deleteTree(directory);
    }

    private static List<String> shell(String script) {
        return Arrays.asList("/bin/sh", "-c", script);
    }

    /** The SDK gives each tool its own process group through the system perl. */
    private static boolean hasProcessGroups() {
        return new java.io.File("/usr/bin/perl").canExecute() || new java.io.File("/bin/perl").canExecute();
    }

    private static boolean hasProcessHandle() {
        try {
            Class.forName("java.lang.ProcessHandle");
            return true;
        } catch (ClassNotFoundException error) {
            return false;
        }
    }

    @Test
    void framesSplitAcrossChunksOrSeveralInOneChunkDecodeInOrder() {
        Framing.Decoder decoder = new Framing.Decoder();
        byte[] first = Framing.encode(map("id", 1, "text", "é✓"));
        byte[] second = Framing.encode(map("id", 2));
        byte[] bytes = Arrays.copyOf(first, first.length + second.length);
        System.arraycopy(second, 0, bytes, first.length, second.length);
        List<Object> messages = new ArrayList<>();
        for (int index = 0; index < bytes.length; index += 3) {
            messages.addAll(decoder.push(bytes, index, Math.min(3, bytes.length - index)));
        }
        assertEquals(Arrays.asList(map("id", 1L, "text", "é✓"), map("id", 2L)), messages);
        byte[] oversized = "Content-Length: 999999999999\r\n\r\n".getBytes(StandardCharsets.US_ASCII);
        assertThrows(Framing.FramingException.class, () -> new Framing.Decoder().push(oversized, 0, oversized.length));
        byte[] missing = "X-Other: 1\r\n\r\n".getBytes(StandardCharsets.US_ASCII);
        assertThrows(Framing.FramingException.class, () -> new Framing.Decoder().push(missing, 0, missing.length));
    }

    @Test
    void aHeaderOverEightKibibytesIsRefusedAlsoWhenTheWholeFrameArrivesAtOnce() {
        StringBuilder header = new StringBuilder("Content-Length: 2\r\nX-Padding: ");
        while (header.length() <= 8200) {
            header.append('x');
        }
        byte[] frame = (header + "\r\n\r\n{}").getBytes(StandardCharsets.US_ASCII);
        assertThrows(Framing.FramingException.class, () -> new Framing.Decoder().push(frame, 0, frame.length));
    }

    @Test
    void jsonRoundTripsProtocolValuesAndRefusesWhatItCannotRepresent() {
        String text = "{\"a\":[1,-2.5,true,false,null,\"\\u00e9\\n\\\"\"],\"big\":123456789012345678901234567890,\"e\":1e3}";
        Map<String, Object> value = Json.object(Json.parse(text));
        assertEquals(Arrays.asList(1L, -2.5, true, false, null, "é\n\""), value.get("a"));
        assertEquals(new BigInteger("123456789012345678901234567890"), value.get("big"));
        assertEquals(1000.0, value.get("e"));
        // Integral doubles print without a fraction, as JavaScript prints them.
        String encoded = Json.stringify(value);
        assertEquals("{\"a\":[1,-2.5,true,false,null,\"é\\n\\\"\"],\"big\":123456789012345678901234567890,\"e\":1000}", encoded);
        assertEquals(encoded, Json.stringify(Json.parse(encoded)));
        assertEquals("\"\\ud800x\"", Json.stringify("\ud800x"));
        assertEquals("[1,2.5]", Json.stringify(Arrays.asList(1.0, 2.5)));
        for (String malformed : Arrays.asList("", "{", "[1,]", "{\"a\" 1}", "01", "1.", "\"\u0001\"", "tru", "{} x")) {
            assertThrows(Json.JsonException.class, () -> Json.parse(malformed), malformed);
        }
        Map<Object, Object> numericKeys = new HashMap<>();
        numericKeys.put(1, "x");
        assertThrows(Json.JsonException.class, () -> Json.stringify(numericKeys));
        assertThrows(Json.JsonException.class, () -> Json.stringify(Double.POSITIVE_INFINITY));
        StringBuilder deep = new StringBuilder();
        for (int index = 0; index < 600; index++) {
            deep.append('[');
        }
        assertThrows(Json.JsonException.class, () -> Json.parse(deep.toString()));
    }

    @Test
    void boundedTextCutsOnCharacterBoundaries() {
        assertEquals("ab", Protocol.boundedText("abc", 2));
        assertEquals("é", Protocol.boundedText("éé", 3));
        assertEquals("", Protocol.boundedText("😀", 3));
        assertEquals("", Protocol.boundedText(null));
        assertTrue(Protocol.isPluginErrorCode("maven.snapshotLocked"));
        assertFalse(Protocol.isPluginErrorCode("bad code"));
    }

    @Test
    @DisabledOnOs(OS.WINDOWS)
    void runCapturesOutputAndReturnsANonZeroExit() throws IOException {
        Processes.Result result = Processes.run(shell("printf out; printf err >&2; exit 3"));
        assertEquals(3, result.exitCode());
        assertEquals("out", result.stdout());
        assertEquals("err", result.stderr());
        assertFalse(result.truncated());
        Processes.Result limited = Processes.run(shell("printf xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"),
                new Processes.Options().maxOutputBytes(10));
        assertEquals("xxxxxxxxxx", limited.stdout());
        assertTrue(limited.truncated());
    }

    @Test
    @DisabledOnOs(OS.WINDOWS)
    void streamedOutputKeepsACharacterSplitAcrossReadsWhole() throws IOException {
        // 3-byte characters never align with the 8 KiB reads, so reads split them.
        String expected = String.join("", Collections.nCopies(50_000, "✓"));
        Path file = directory.resolve("checks.txt");
        Files.write(file, expected.getBytes(StandardCharsets.UTF_8));
        StringBuilder streamed = new StringBuilder();
        Processes.Result result = Processes.run(Arrays.asList("cat", file.toString()),
                new Processes.Options().onStdout(streamed::append));
        assertEquals(expected, streamed.toString());
        assertEquals(expected, result.stdout());
    }

    @Test
    @DisabledOnOs(OS.WINDOWS)
    void aReplacedEnvironmentStillCarriesTheHostProcessMarkers() throws IOException {
        Map<String, String> environment = new HashMap<>();
        environment.put("PATH", System.getenv("PATH"));
        environment.put("LITHE_PROCESS_SCOPE", "forged");
        environment.put("OWN", "kept");
        Processes.Result result = Processes.run(shell("printf '%s|%s' \"${LITHE_PROCESS_SCOPE-unset}\" \"$OWN\""),
                new Processes.Options().environment(environment));
        String inherited = System.getenv("LITHE_PROCESS_SCOPE");
        assertEquals((inherited == null ? "unset" : inherited) + "|kept", result.stdout());
    }

    @Test
    @DisabledOnOs(OS.WINDOWS)
    void cancellingACallEndsTheToolTreeItStarted() {
        assumeTrue(hasProcessGroups() || hasProcessHandle(),
                "without perl, Java 8 ends only the direct child; the host scope ends the rest");
        Path grandchildPid = directory.resolve("grandchild.pid");
        // The child starts a grandchild that ignores SIGTERM, so only the forced
        // stop can end it.
        String grandchild = "trap '' TERM; echo $$ > '" + grandchildPid + "'; while :; do sleep 1; done";
        String child = "/bin/sh -c \"" + grandchild.replace("$", "\\$") + "\" & wait";
        CountDownLatch started = new CountDownLatch(1);
        Backend backend = Backend.create(null, null).function("tool.run", (params, context) -> {
            started.countDown();
            return context.run(shell(child), new Processes.Options().killGraceMillis(50)).exitCode();
        });
        TestHost host = new TestHost(backend);
        host.initialize();
        CompletableFuture<Map<String, Object>> response = host.requestAsync("lithe/function/invoke",
                map("functionID", "tool.run", "operationID", "g"), 7L);
        Fixtures.await(started, "the tool to start");
        long pid = Fixtures.awaitPid(grandchildPid);
        host.notify("$/cancelRequest", map("id", 7L));
        Map<String, Object> answer = Fixtures.await(response, "the cancelled call");
        assertEquals(-32800L, ((Map<?, ?>) answer.get("error")).get("code"));
        Fixtures.eventually(() -> !Fixtures.isAlive(pid), "the grandchild to be stopped");
        Fixtures.eventually(() -> Processes.runningCount() == 0, "the registry to drain");
        host.close();
    }

    @Test
    @DisabledOnOs(OS.WINDOWS)
    void aToolThatExitsTakesItsBackgroundWorkersButNotAnotherCallsTool() throws Exception {
        assumeTrue(hasProcessGroups(), "without perl the tool has no process group of its own");
        Path workerPid = directory.resolve("worker.pid");
        Path otherPid = directory.resolve("other.pid");
        Cancellation other = new Cancellation();
        CompletableFuture<Object> otherCall = CompletableFuture.supplyAsync(() -> {
            try {
                return Processes.run(shell("echo $$ > '" + otherPid + "'; exec sleep 600"),
                        new Processes.Options().cancellation(other).killGraceMillis(50));
            } catch (IOException | CancelledException error) {
                return error;
            }
        });
        long otherTool = Fixtures.awaitPid(otherPid);
        // The tool succeeds at once and leaves a worker that holds no pipe.
        Processes.Result result = Processes.run(shell(
                "sleep 600 >/dev/null 2>&1 & echo $! > '" + workerPid + "'; exit 0"));
        assertEquals(0, result.exitCode());
        long worker = Fixtures.awaitPid(workerPid);
        Fixtures.eventually(() -> !Fixtures.isAlive(worker), "the left worker to be killed");
        assertTrue(Fixtures.isAlive(otherTool), "a concurrent call's tool keeps running");
        other.cancel("done");
        assertTrue(Fixtures.await(otherCall, "the other call") instanceof CancelledException);
        Fixtures.eventually(() -> !Fixtures.isAlive(otherTool), "the other tool to be stopped");
    }

    @Test
    @DisabledOnOs(OS.WINDOWS)
    void aMissingExecutableFailsToStartAndPerlOptionsReachOnlyTheTool() throws IOException {
        IOException missing = assertThrows(IOException.class,
                () -> Processes.run(Arrays.asList(directory.resolve("missing").toString())));
        assertTrue(missing.getMessage().contains("missing"), missing.getMessage());
        Map<String, String> environment = new HashMap<>();
        environment.put("PATH", System.getenv("PATH"));
        // Perl would refuse to start with this; the tool only sees it.
        environment.put("PERL5OPT", "-MLithe::Missing::Module");
        Processes.Result result = Processes.run(shell("printf %s \"$PERL5OPT\""),
                new Processes.Options().environment(environment));
        assertEquals(0, result.exitCode(), result.stderr());
        assertEquals("-MLithe::Missing::Module", result.stdout());
    }

    @Test
    @DisabledOnOs(OS.WINDOWS)
    void closingTheSessionEndsToolsStillRunning() {
        Path childPid = directory.resolve("child.pid");
        CountDownLatch started = new CountDownLatch(1);
        Backend backend = Backend.create(null, null).function("tool.run", (params, context) -> {
            started.countDown();
            // `exec` keeps the PID: the tool itself ignores SIGTERM.
            return context.run(shell("trap '' TERM; echo $$ > '" + childPid + "'; exec sleep 600")).exitCode();
        });
        TestHost host = new TestHost(backend);
        host.initialize();
        // No reply is awaited: the session ends while the call is still running.
        host.send(map("id", 8L, "method", "lithe/function/invoke",
                "params", map("functionID", "tool.run", "operationID", "h")));
        Fixtures.await(started, "the tool to start");
        long pid = Fixtures.awaitPid(childPid);
        assertEquals(1, host.close());
        Fixtures.eventually(() -> !Fixtures.isAlive(pid), "the tool to be killed");
    }

    @Test
    @DisabledOnOs(OS.WINDOWS)
    void aCallThatSettlesStopsTheToolsItsHandlerLeftRunningAndOnlyThose() {
        Path leftPid = directory.resolve("left.pid");
        Path otherPid = directory.resolve("other.pid");
        CountDownLatch otherStarted = new CountDownLatch(1);
        CountDownLatch releaseOther = new CountDownLatch(1);
        Backend backend = Backend.create(null, null)
                .function("tool.leave", (params, context) -> {
                    Thread background = new Thread(() -> {
                        try {
                            context.run(shell("echo $$ > '" + leftPid + "'; exec sleep 600"));
                        } catch (IOException | CancelledException error) {
                            // Stopped with its call, as intended.
                        }
                    });
                    background.setDaemon(true);
                    background.start();
                    Fixtures.awaitPid(leftPid);
                    return "returned";
                })
                .function("tool.other", (params, context) -> {
                    Thread background = new Thread(() -> {
                        try {
                            context.run(shell("echo $$ > '" + otherPid + "'; exec sleep 600"));
                        } catch (IOException | CancelledException error) {
                            // Ends with its own call.
                        }
                    });
                    background.setDaemon(true);
                    background.start();
                    otherStarted.countDown();
                    Fixtures.await(releaseOther, "the test to release the other call");
                    return null;
                });
        TestHost host = new TestHost(backend);
        host.initialize();
        CompletableFuture<Map<String, Object>> other = host.requestAsync("lithe/function/invoke",
                map("functionID", "tool.other", "operationID", "o"), 11L);
        Fixtures.await(otherStarted, "the other call");
        long otherTool = Fixtures.awaitPid(otherPid);
        assertEquals("returned", host.request("lithe/function/invoke",
                map("functionID", "tool.leave", "operationID", "l")).get("result"));
        long leftTool = Fixtures.awaitPid(leftPid);
        Fixtures.eventually(() -> !Fixtures.isAlive(leftTool), "the left tool to be stopped");
        assertTrue(Fixtures.isAlive(otherTool), "the other call's tool keeps running");
        releaseOther.countDown();
        Fixtures.await(other, "the other call");
        Fixtures.eventually(() -> !Fixtures.isAlive(otherTool), "the other tool to be stopped");
        host.close();
    }

    @Test
    void theStateStoreWritesAtomicallyAndSurvivesReopening() throws IOException {
        Path state = directory.resolve("workspace-state");
        StateStore store = StateStore.open(state, null);
        assertEquals("none", store.read("snapshot", "none"));
        store.write("snapshot", map("generation", 1));
        store.write("snapshot", map("generation", 2));
        assertEquals(map("generation", 2L), StateStore.open(state, null).read("snapshot", null));
        try (Stream<Path> files = Files.list(state)) {
            assertEquals(Arrays.asList("snapshot.json"),
                    files.map(path -> path.getFileName().toString()).collect(Collectors.toList()));
        }
        // The same envelope as the Node.js SDK, so either reads the other's state.
        assertEquals("{\"litheStateStore\":1,\"value\":{\"generation\":2}}",
                new String(Files.readAllBytes(state.resolve("snapshot.json")), StandardCharsets.UTF_8));
        Files.write(state.resolve("broken.json"), "{".getBytes(StandardCharsets.UTF_8));
        assertNull(store.read("broken", null));
        store.delete("snapshot");
        store.delete("snapshot");
        assertNull(store.read("snapshot", null));
        for (String key : Arrays.asList("", "../escape", "a/b", "x.tmp", ".hidden")) {
            PluginSdkError error = assertThrows(PluginSdkError.class, () -> store.write(key, 1), key);
            assertEquals("sdk.state.invalidKey", error.code());
        }
    }

    @Test
    void theStateStoreRefusesAValueJsonCannotEncodeAndKeepsTheStoredOne() throws IOException {
        StateStore store = StateStore.open(directory.resolve("state"), null);
        store.write("kept", map("ok", true));
        PluginSdkError error = assertThrows(PluginSdkError.class, () -> store.write("kept", new Object()));
        assertEquals("sdk.state.invalidValue", error.code());
        assertEquals(map("ok", true), store.read("kept", null));
    }

    @Test
    void theStateStoreRefusesTheReadOnlyPluginPackage() throws IOException {
        Path packageDirectory = directory.resolve("package");
        Files.createDirectories(packageDirectory);
        Files.write(packageDirectory.resolve("plugin.json"), "{}".getBytes(StandardCharsets.UTF_8));
        PluginSdkError refused = assertThrows(PluginSdkError.class,
                () -> StateStore.open(packageDirectory.resolve("state"), packageDirectory));
        assertEquals("sdk.state.readOnlyPackage", refused.code());
        // Refused before anything was created inside the package.
        assertFalse(Files.exists(packageDirectory.resolve("state")));
        PluginSdkError relative = assertThrows(PluginSdkError.class,
                () -> StateStore.open(java.nio.file.Paths.get("relative/state"), null));
        assertEquals("sdk.state.invalidDirectory", relative.code());
        StateStore.open(directory.resolve("state"), packageDirectory);
    }
}
