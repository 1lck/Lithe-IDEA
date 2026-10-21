package io.github.litheidea.plugin.sdk;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.nio.CharBuffer;
import java.nio.charset.CharsetDecoder;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.function.Consumer;
import java.util.stream.Collectors;
import java.util.stream.Stream;

/**
 * Child processes a backend starts for one call.
 *
 * <p>Lithe's host offers no process capability in protocol version 1, so a
 * backend runs its tools itself; this helper makes sure that the call ending,
 * cancelling it, or the backend shutting down also ends the tools it started.
 *
 * <p>Process trees: on macOS and Linux every tool leads its own process group,
 * as in the Node SDK, on every Java version. Java has no API for that, so the
 * tool starts through the system {@code perl}, which calls {@code setpgrp} and
 * then replaces itself with the tool, keeping its PID. A stop signals the whole
 * group, and once the tool exits on its own the members it left behind, such
 * as a background worker, are killed too; descendants that leave the group
 * with {@code setsid} are out of reach. Windows, and a system without
 * {@code perl}, fall back to {@code ProcessHandle} on Java 9 and newer, found
 * by reflection so the SDK still loads on Java 8; it reaches only the
 * descendants still attached to the tool. Lithe starts every backend inside
 * its own process scope ({@code LITHE_PLUGIN_BACKEND_SCOPE}) and ends whatever
 * is left of it when the session ends; that remains the final boundary.
 */
public final class Processes {
    /**
     * Variables Lithe sets on the backend so it can find and end every process
     * the backend started, even one that left its parent. A tool always
     * inherits them, also when the plugin replaces the environment.
     */
    static final String[] HOST_MARKERS = {"LITHE_PROCESS_SCOPE", "LITHE_PLUGIN_BACKEND_SCOPE"};

    /** Every tool started through {@link #run} that has not exited or been stopped. */
    private static final Set<Running> RUNNING = Collections.newSetFromMap(new ConcurrentHashMap<>());

    private static final ScheduledExecutorService TIMERS = Executors.newSingleThreadScheduledExecutor(runnable -> {
        Thread thread = new Thread(runnable, "lithe-sdk-process-timer");
        thread.setDaemon(true);
        return thread;
    });

    private static final ProcessTree TREE = ProcessTree.load();

    private static final ProcessGroups GROUPS = ProcessGroups.load();

    private Processes() {}

    /** Options of one {@link #run}; every setter returns this object. */
    public static final class Options {
        private Path directory;
        private Map<String, String> environment;
        private Cancellation cancellation;
        private int maxOutputBytes = 1 << 20;
        private long killGraceMillis = 2000;
        private Consumer<String> onStdout;
        private Consumer<String> onStderr;

        /** Working directory; defaults to the backend's. */
        public Options directory(Path value) {
            directory = value;
            return this;
        }

        /** Replaces the environment; the host's process markers are carried over regardless. */
        public Options environment(Map<String, String> value) {
            environment = value;
            return this;
        }

        /** Cancelling it stops the tool and makes {@link #run} throw {@link CancelledException}. */
        public Options cancellation(Cancellation value) {
            cancellation = value;
            return this;
        }

        /** Captured bytes per stream; default 1 MiB. Listeners still see everything. */
        public Options maxOutputBytes(int value) {
            maxOutputBytes = value;
            return this;
        }

        /** Delay between the polite and the forced stop; default 2000. */
        public Options killGraceMillis(long value) {
            killGraceMillis = value;
            return this;
        }

        /** Receives stdout as it arrives, decoded as UTF-8 without splitting characters. */
        public Options onStdout(Consumer<String> value) {
            onStdout = value;
            return this;
        }

        /** Receives stderr as it arrives, decoded as UTF-8 without splitting characters. */
        public Options onStderr(Consumer<String> value) {
            onStderr = value;
            return this;
        }

        Cancellation cancellation() {
            return cancellation;
        }

        Options copy() {
            Options copy = new Options();
            copy.directory = directory;
            copy.environment = environment;
            copy.cancellation = cancellation;
            copy.maxOutputBytes = maxOutputBytes;
            copy.killGraceMillis = killGraceMillis;
            copy.onStdout = onStdout;
            copy.onStderr = onStderr;
            return copy;
        }
    }

    /** Exit status and captured output of a tool. */
    public static final class Result {
        private final int exitCode;
        private final String stdout;
        private final String stderr;
        private final boolean truncated;

        Result(int exitCode, String stdout, String stderr, boolean truncated) {
            this.exitCode = exitCode;
            this.stdout = stdout;
            this.stderr = stderr;
            this.truncated = truncated;
        }

        /** The exit code; on POSIX a tool ended by signal N reports 128 + N. */
        public int exitCode() {
            return exitCode;
        }

        public String stdout() {
            return stdout;
        }

        public String stderr() {
            return stderr;
        }

        /** True when either stream exceeded {@code maxOutputBytes}. */
        public boolean truncated() {
            return truncated;
        }
    }

    /**
     * Runs {@code command} without a shell and returns its exit status and
     * captured output. A non-zero exit returns normally; the caller decides
     * what it means for its tool. Cancellation stops the tool and throws
     * {@link CancelledException} once it ended.
     */
    public static Result run(List<String> command, Options options) throws IOException {
        Options settings = options == null ? new Options() : options;
        Cancellation cancellation = settings.cancellation;
        if (cancellation != null) {
            cancellation.throwIfCancelled();
        }
        if (command.isEmpty()) {
            throw new IllegalArgumentException("A command needs an executable.");
        }
        ProcessBuilder builder = new ProcessBuilder(new ArrayList<>(command));
        if (settings.directory != null) {
            builder.directory(settings.directory.toFile());
        }
        if (settings.environment != null) {
            Map<String, String> environment = builder.environment();
            environment.clear();
            environment.putAll(settings.environment);
            for (String name : HOST_MARKERS) {
                String value = System.getenv(name);
                if (value == null) {
                    environment.remove(name);
                } else {
                    environment.put(name, value);
                }
            }
        }
        boolean grouped = GROUPS.available();
        if (grouped) {
            builder.command(GROUPS.launcher(command, builder.environment()));
        }
        Process process = builder.start();
        // Tools get no input; an open pipe would let one wait on it forever.
        process.getOutputStream().close();
        Running entry = new Running(process, grouped ? GROUPS.leader(process) : 0);
        RUNNING.add(entry);
        Capture stdout = new Capture(process.getInputStream(), settings.maxOutputBytes, settings.onStdout, "stdout");
        Capture stderr = new Capture(process.getErrorStream(), settings.maxOutputBytes, settings.onStderr, "stderr");
        Cancellation.Registration registration = cancellation == null
                ? () -> {}
                : cancellation.onCancel(() -> entry.stop(settings.killGraceMillis));
        int exitCode;
        try {
            exitCode = waitFor(process, entry);
            registration.remove();
            // The tool ended on its own; what it left running, such as a
            // background worker, ends with it. A stopped tool stays registered
            // until its forced stop, which reaches the same members.
            entry.endLeftovers();
            // A descendant out of reach can keep the inherited pipes open after
            // the tool exited; the output then ends at the grace period.
            stdout.join(settings.killGraceMillis);
            stderr.join(settings.killGraceMillis);
        } finally {
            registration.remove();
            if (!entry.stopping()) {
                RUNNING.remove(entry);
            }
        }
        if (cancellation != null) {
            cancellation.throwIfCancelled();
        }
        String errors = stderr.text();
        if (grouped && exitCode == ProcessGroups.EXEC_FAILED && errors.startsWith(ProcessGroups.EXEC_FAILURE)) {
            // The launcher could not start the tool; report it as ProcessBuilder would.
            throw new IOException("Cannot run program \"" + command.get(0) + "\": "
                    + errors.substring(ProcessGroups.EXEC_FAILURE.length()).trim());
        }
        return new Result(exitCode, stdout.text(), errors, stdout.truncated() || stderr.truncated());
    }

    /** Runs {@code command} with default options. */
    public static Result run(List<String> command) throws IOException {
        return run(command, null);
    }

    /**
     * Forcibly ends every tool still running. The backend calls it on shutdown,
     * on {@code exit}, and when the host closes stdin, so no tool outlives the
     * session that started it.
     */
    public static void killAll() {
        for (Running entry : new ArrayList<>(RUNNING)) {
            entry.forceStop();
        }
        RUNNING.clear();
    }

    /** Number of tools still running or being stopped, for tests and diagnostics. */
    public static int runningCount() {
        return RUNNING.size();
    }

    private static int waitFor(Process process, Running entry) {
        boolean interrupted = false;
        try {
            for (;;) {
                try {
                    return process.waitFor();
                } catch (InterruptedException error) {
                    // The tool still belongs to this call; end it before giving
                    // the interrupt back to the caller.
                    interrupted = true;
                    entry.forceStop();
                }
            }
        } finally {
            if (interrupted) {
                Thread.currentThread().interrupt();
            }
        }
    }

    /** One started tool and its stop state. */
    private static final class Running {
        private final Process process;
        /** The tool's process group, or 0 when it has none of its own. */
        private final long group;
        private final Object lock = new Object();
        private boolean stopping;
        private List<Object> tree = Collections.emptyList();
        private ScheduledFuture<?> forceTimer;

        Running(Process process, long group) {
            this.process = process;
            this.group = group;
        }

        /** Kills what the tool left after exiting on its own, unless a stop owns that. */
        void endLeftovers() {
            synchronized (lock) {
                if (stopping) {
                    return;
                }
            }
            if (group > 0) {
                // While any member lives the group ID cannot be reused, so this
                // reaches only what this tool started; an empty group is ignored.
                GROUPS.signal(group, true);
            } else {
                // Windows keeps the parent link of an exited tool, so its
                // descendants are still found there.
                TREE.destroy(TREE.descendants(process), true);
            }
        }

        boolean stopping() {
            synchronized (lock) {
                return stopping;
            }
        }

        /** Asks the tree to stop, then forces it after {@code graceMillis}. */
        void stop(long graceMillis) {
            synchronized (lock) {
                if (stopping) {
                    return;
                }
                stopping = true;
                if (group > 0) {
                    GROUPS.signal(group, false);
                } else {
                    // Descendants are listed before the tool is signalled: once
                    // it exits they are reparented and no longer reachable from it.
                    tree = TREE.descendants(process);
                    TREE.destroy(tree, false);
                }
                // Also covers a tool that has not formed its group yet.
                process.destroy();
                forceTimer = TIMERS.schedule(this::forceStop, graceMillis, TimeUnit.MILLISECONDS);
            }
        }

        void forceStop() {
            List<Object> known;
            synchronized (lock) {
                stopping = true;
                if (forceTimer != null) {
                    forceTimer.cancel(false);
                }
                known = new ArrayList<>(tree);
                if (group <= 0) {
                    known.addAll(TREE.descendants(process));
                }
            }
            if (group > 0) {
                GROUPS.signal(group, true);
            }
            TREE.destroy(known, true);
            process.destroyForcibly();
            RUNNING.remove(this);
        }
    }

    /** Reads one output stream on its own thread, keeping at most {@code limit} bytes. */
    private static final class Capture {
        private final ByteArrayOutputStream kept = new ByteArrayOutputStream();
        private final InputStream input;
        private final int limit;
        private final Consumer<String> listener;
        private final CharsetDecoder decoder = StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPLACE)
                .onUnmappableCharacter(CodingErrorAction.REPLACE);
        private final Thread thread;
        private volatile boolean truncated;

        Capture(InputStream input, int limit, Consumer<String> listener, String name) {
            this.input = input;
            this.limit = limit;
            this.listener = listener;
            thread = new Thread(this::read, "lithe-sdk-" + name);
            thread.setDaemon(true);
            thread.start();
        }

        private void read() {
            byte[] chunk = new byte[8192];
            // Holds a multi-byte character split across reads until it is whole.
            ByteBuffer pending = ByteBuffer.allocate(chunk.length + 8);
            try {
                int count;
                while ((count = input.read(chunk)) >= 0) {
                    synchronized (kept) {
                        int room = Math.max(0, limit - kept.size());
                        kept.write(chunk, 0, Math.min(room, count));
                        if (count > room) {
                            truncated = true;
                        }
                    }
                    if (listener != null) {
                        pending.put(chunk, 0, count);
                        pending.flip();
                        deliver(pending, false);
                        pending.compact();
                    }
                }
                if (listener != null) {
                    pending.flip();
                    deliver(pending, true);
                }
            } catch (IOException error) {
                // The stream was closed after the grace period; what was read is kept.
            }
        }

        private void deliver(ByteBuffer bytes, boolean end) {
            CharBuffer characters = CharBuffer.allocate(bytes.remaining() + 1);
            decoder.decode(bytes, characters, end);
            if (end) {
                decoder.flush(characters);
            }
            characters.flip();
            if (characters.hasRemaining()) {
                try {
                    listener.accept(characters.toString());
                } catch (RuntimeException error) {
                    System.err.println("An output listener failed: " + error);
                }
            }
        }

        void join(long millis) {
            try {
                thread.join(Math.max(1, millis));
                if (thread.isAlive()) {
                    input.close();
                    thread.join(millis);
                }
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
            } catch (IOException error) {
                // Closing an output pipe that already failed changes nothing.
            }
        }

        String text() {
            synchronized (kept) {
                return new String(kept.toByteArray(), StandardCharsets.UTF_8);
            }
        }

        boolean truncated() {
            return truncated;
        }
    }

    /**
     * A process group per tool on macOS and Linux. The launcher is
     * {@code perl -e SCRIPT -- <hasOpt> <opt> command...}: it calls
     * {@code setpgrp(0, 0)} and replaces itself with the tool, so the PID Java
     * reports is the tool's and also its group ID. {@code PERL5OPT} would make
     * perl load modules before the script runs, so it is withheld from perl and
     * handed back to the tool. Signals go through {@code /bin/kill}, which
     * Java 8 needs for a negative PID.
     */
    private static final class ProcessGroups {
        /** Exit code and stderr prefix of a launcher that could not start the tool. */
        static final int EXEC_FAILED = 127;
        static final String EXEC_FAILURE = "lithe-sdk-exec-failed: ";

        private static final String SCRIPT = "my $has = shift; my $opt = shift;"
                + " $ENV{PERL5OPT} = $opt if $has;"
                + " setpgrp(0, 0);"
                + " exec { $ARGV[0] } @ARGV;"
                + " print STDERR '" + EXEC_FAILURE + "', \"$!\\n\"; exit " + EXEC_FAILED + ";";

        /** A signal that has not run after this long is abandoned; the host scope remains. */
        private static final long SIGNAL_TIMEOUT_MILLIS = 2000;

        private final String perl;
        private final String kill;
        private final Method pid;

        private ProcessGroups(String perl, String kill, Method pid) {
            this.perl = perl;
            this.kill = kill;
            this.pid = pid;
        }

        static ProcessGroups load() {
            if (System.getProperty("os.name", "").startsWith("Windows")) {
                return new ProcessGroups(null, null, null);
            }
            Method pid;
            try {
                pid = Process.class.getMethod("pid");
            } catch (NoSuchMethodException error) {
                // Java 8 keeps the PID in a private field of UNIXProcess.
                pid = null;
            }
            return new ProcessGroups(executable("/usr/bin/perl", "/bin/perl"),
                    executable("/bin/kill", "/usr/bin/kill"), pid);
        }

        private static String executable(String... candidates) {
            for (String candidate : candidates) {
                if (new File(candidate).canExecute()) {
                    return candidate;
                }
            }
            return null;
        }

        boolean available() {
            return perl != null && kill != null;
        }

        List<String> launcher(List<String> command, Map<String, String> environment) {
            String option = environment.remove("PERL5OPT");
            List<String> launcher = new ArrayList<>(Arrays.asList(perl, "-e", SCRIPT, "--",
                    option == null ? "0" : "1", option == null ? "" : option));
            launcher.addAll(command);
            return launcher;
        }

        /** The tool's PID, which is its group ID; 0 when it cannot be read. */
        long leader(Process process) {
            try {
                if (pid != null) {
                    return ((Number) pid.invoke(process)).longValue();
                }
                Field field = process.getClass().getDeclaredField("pid");
                field.setAccessible(true);
                return field.getInt(process);
            } catch (ReflectiveOperationException | RuntimeException error) {
                return 0;
            }
        }

        /** Signals every member of {@code group}; an empty group is ignored. */
        void signal(long group, boolean forcibly) {
            ProcessBuilder builder = new ProcessBuilder(kill, "-s", forcibly ? "KILL" : "TERM", "--", "-" + group);
            File discard = new File("/dev/null");
            builder.redirectOutput(discard).redirectError(discard);
            try {
                Process signal = builder.start();
                signal.getOutputStream().close();
                if (!signal.waitFor(SIGNAL_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS)) {
                    signal.destroyForcibly();
                }
            } catch (IOException error) {
                // The host's process scope ends what this could not reach.
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
            }
        }
    }

    /**
     * {@code ProcessHandle} through reflection: present from Java 9, absent on
     * Java 8, where only the direct child can be stopped.
     */
    private static final class ProcessTree {
        private final Method descendants;
        private final Method destroy;
        private final Method destroyForcibly;

        private ProcessTree(Method descendants, Method destroy, Method destroyForcibly) {
            this.descendants = descendants;
            this.destroy = destroy;
            this.destroyForcibly = destroyForcibly;
        }

        static ProcessTree load() {
            try {
                Class<?> handle = Class.forName("java.lang.ProcessHandle");
                return new ProcessTree(
                        Process.class.getMethod("descendants"),
                        handle.getMethod("destroy"),
                        handle.getMethod("destroyForcibly"));
            } catch (ReflectiveOperationException error) {
                return new ProcessTree(null, null, null);
            }
        }

        List<Object> descendants(Process process) {
            if (descendants == null) {
                return Collections.emptyList();
            }
            try {
                @SuppressWarnings("unchecked")
                Stream<Object> stream = (Stream<Object>) descendants.invoke(process);
                return stream.collect(Collectors.toList());
            } catch (ReflectiveOperationException | RuntimeException error) {
                return Collections.emptyList();
            }
        }

        void destroy(List<Object> handles, boolean forcibly) {
            Method method = forcibly ? destroyForcibly : destroy;
            if (method == null) {
                return;
            }
            for (Object handle : handles) {
                try {
                    method.invoke(handle);
                } catch (ReflectiveOperationException | RuntimeException error) {
                    // The process already exited, or the platform refused; the
                    // host's process scope ends what is left.
                }
            }
        }
    }
}
