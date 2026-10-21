package io.github.litheidea.plugin.sdk;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.function.BooleanSupplier;

/** Small helpers shared by the SDK tests. */
final class Fixtures {
    private Fixtures() {}

    /** A map from alternating keys and values, in order. */
    static Map<String, Object> map(Object... entries) {
        Map<String, Object> map = new LinkedHashMap<>();
        for (int index = 0; index < entries.length; index += 2) {
            map.put((String) entries[index], entries[index + 1]);
        }
        return map;
    }

    /** The future's value within {@link TestHost#WAIT_MILLIS}. */
    static <T> T await(CompletableFuture<T> future, String description) {
        try {
            return future.get(TestHost.WAIT_MILLIS, TimeUnit.MILLISECONDS);
        } catch (TimeoutException error) {
            throw new AssertionError("Timed out waiting for " + description + ".", error);
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new AssertionError("Interrupted waiting for " + description + ".", error);
        } catch (ExecutionException error) {
            throw new AssertionError(description + " failed.", error.getCause());
        }
    }

    /** Waits for {@code latch} within {@link TestHost#WAIT_MILLIS}. */
    static void await(CountDownLatch latch, String description) {
        try {
            if (!latch.await(TestHost.WAIT_MILLIS, TimeUnit.MILLISECONDS)) {
                throw new AssertionError("Timed out waiting for " + description + ".");
            }
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new AssertionError("Interrupted waiting for " + description + ".", error);
        }
    }

    /**
     * Bounded poll of an OS-level fact, such as a process having exited, that
     * offers the test no notification channel.
     */
    static void eventually(BooleanSupplier check, String description) {
        long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(TestHost.WAIT_MILLIS);
        while (!check.getAsBoolean()) {
            if (System.nanoTime() > deadline) {
                throw new AssertionError("Timed out waiting for " + description + ".");
            }
            try {
                // test-stability: allow(real-sleep) reason: the polled fact is a separate OS process's state with no notification channel; the deadline above bounds the loop.
                Thread.sleep(10);
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new AssertionError("Interrupted waiting for " + description + ".", error);
            }
        }
    }

    /** True while the POSIX process {@code pid} exists. */
    static boolean isAlive(long pid) {
        try {
            Process probe = new ProcessBuilder("kill", "-0", Long.toString(pid)).start();
            if (!probe.waitFor(TestHost.WAIT_MILLIS, TimeUnit.MILLISECONDS)) {
                probe.destroyForcibly();
                throw new AssertionError("kill -0 did not answer.");
            }
            return probe.exitValue() == 0;
        } catch (IOException error) {
            throw new UncheckedIOException(error);
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new AssertionError(error);
        }
    }

    /** The PID a tool wrote to {@code file}, once it is there. */
    static long awaitPid(Path file) {
        eventually(() -> {
            try {
                return Files.isRegularFile(file) && !new String(Files.readAllBytes(file)).trim().isEmpty();
            } catch (IOException error) {
                return false;
            }
        }, "a PID in " + file.getFileName());
        try {
            return Long.parseLong(new String(Files.readAllBytes(file)).trim());
        } catch (IOException error) {
            throw new UncheckedIOException(error);
        }
    }

    static void deleteTree(Path root) {
        if (!Files.exists(root)) {
            return;
        }
        try {
            Files.walkFileTree(root, new SimpleFileVisitor<Path>() {
                @Override
                public FileVisitResult visitFile(Path file, BasicFileAttributes attributes) throws IOException {
                    Files.delete(file);
                    return FileVisitResult.CONTINUE;
                }

                @Override
                public FileVisitResult postVisitDirectory(Path directory, IOException error) throws IOException {
                    Files.delete(directory);
                    return FileVisitResult.CONTINUE;
                }
            });
        } catch (IOException error) {
            throw new UncheckedIOException(error);
        }
    }
}
