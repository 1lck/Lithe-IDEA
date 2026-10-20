package io.github.litheidea.plugin.sdk;

import java.io.IOException;
import java.net.URISyntaxException;
import java.net.URL;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.CodeSource;
import java.security.SecureRandom;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * Durable plugin state, in a directory the host gives the backend.
 *
 * <p>The host passes writable directories through the {@code ${stateDir}} and
 * {@code ${workspaceStateDir}} launch variables; the installed package and the
 * host's installation are read-only, because signatures and delta updates are
 * computed over their exact bytes. Values are JSON; each key is one file
 * replaced atomically, so a crash leaves either the old or the new value,
 * never half of one. The envelope matches the Node.js SDK's, so either SDK
 * reads what the other wrote.
 */
public final class StateStore {
    /** Version of the envelope each value is stored in. */
    private static final int STORE_FORMAT = 1;
    private static final Pattern KEY = Pattern.compile("[A-Za-z0-9][A-Za-z0-9._-]{0,127}");
    private static final SecureRandom RANDOM = new SecureRandom();

    private final Path root;

    private StateStore(Path root) {
        this.root = root;
    }

    /**
     * Opens a store in {@code directory}, creating the directory. Refuses a
     * directory inside the plugin package, found as the nearest directory with
     * a {@code plugin.json} above the JAR this class was loaded from.
     *
     * @param directory absolute path, normally the value of {@code ${workspaceStateDir}}
     */
    public static StateStore open(Path directory) throws IOException {
        return open(directory, findPackageDirectory());
    }

    /**
     * Opens a store in {@code directory}, refusing one inside
     * {@code packageDirectory}; null skips that check.
     */
    public static StateStore open(Path directory, Path packageDirectory) throws IOException {
        if (directory == null || !directory.isAbsolute()) {
            throw new PluginSdkError("sdk.state.invalidDirectory",
                    "The state directory must be an absolute path passed by the host.");
        }
        // Checked before creating anything, so a refused path leaves the package untouched.
        Path resolved = canonical(directory);
        if (packageDirectory != null && resolved.startsWith(canonical(packageDirectory))) {
            throw new PluginSdkError("sdk.state.readOnlyPackage",
                    "The state directory is inside the plugin package, which is read-only. Use ${stateDir} or ${workspaceStateDir}.");
        }
        Files.createDirectories(resolved);
        return new StateStore(resolved);
    }

    /** The resolved directory, for a backend that keeps its own files next to the store. */
    public Path directory() {
        return root;
    }

    /** The stored value, or {@code fallback} when the key is missing or unreadable. */
    public Object read(String key, Object fallback) {
        Path path = path(key);
        if (!Files.isRegularFile(path)) {
            return fallback;
        }
        try {
            Object envelope = Json.parse(new String(Files.readAllBytes(path), StandardCharsets.UTF_8));
            if (!(envelope instanceof Map)) {
                return fallback;
            }
            Map<?, ?> fields = (Map<?, ?>) envelope;
            Object format = fields.get("litheStateStore");
            if (!(format instanceof Number) || ((Number) format).doubleValue() != STORE_FORMAT
                    || !fields.containsKey("value")) {
                return fallback;
            }
            return fields.get("value");
        } catch (IOException | RuntimeException error) {
            return fallback;
        }
    }

    /** Stores {@code value}, which must be JSON-encodable, replacing the previous one. */
    public void write(String key, Object value) throws IOException {
        Path path = path(key);
        Map<String, Object> envelope = new LinkedHashMap<>();
        envelope.put("litheStateStore", STORE_FORMAT);
        envelope.put("value", value);
        byte[] body;
        try {
            body = Json.stringify(envelope).getBytes(StandardCharsets.UTF_8);
        } catch (Json.JsonException error) {
            // Refused before touching the file, so the stored value stays.
            throw new PluginSdkError("sdk.state.invalidValue", "The value for " + key + " is not JSON-encodable.");
        }
        Path temporary = root.resolve(key + ".json." + Long.toHexString(RANDOM.nextLong()) + ".tmp");
        try {
            createPrivate(temporary);
            try (FileChannel channel = FileChannel.open(temporary, StandardOpenOption.WRITE)) {
                ByteBuffer buffer = ByteBuffer.wrap(body);
                while (buffer.hasRemaining()) {
                    channel.write(buffer);
                }
                channel.force(true);
            }
            try {
                Files.move(temporary, path, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            } catch (AtomicMoveNotSupportedException error) {
                Files.move(temporary, path, StandardCopyOption.REPLACE_EXISTING);
            }
        } catch (IOException | RuntimeException error) {
            Files.deleteIfExists(temporary);
            throw error;
        }
    }

    /** Removes the key; a missing key is not an error. */
    public void delete(String key) throws IOException {
        Files.deleteIfExists(path(key));
    }

    private Path path(String key) {
        if (key == null || !KEY.matcher(key).matches() || key.endsWith(".tmp")) {
            throw new PluginSdkError("sdk.state.invalidKey", "State key \"" + key
                    + "\" must be 1-128 letters, digits, \".\", \"_\" or \"-\", start with a letter or digit, and not end with \".tmp\".");
        }
        return root.resolve(key + ".json");
    }

    /** Creates an empty file only the user can read, where the platform supports it. */
    private static void createPrivate(Path file) throws IOException {
        try {
            Files.createFile(file, PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")));
        } catch (UnsupportedOperationException error) {
            Files.createFile(file);
        } catch (FileAlreadyExistsException error) {
            throw new IOException("A temporary state file already exists: " + file.getFileName(), error);
        }
    }

    /** Resolves symbolic links of the longest existing prefix of {@code path}. */
    static Path canonical(Path path) throws IOException {
        Path absolute = path.toAbsolutePath().normalize();
        Path existing = absolute;
        while (existing != null && !Files.exists(existing)) {
            existing = existing.getParent();
        }
        if (existing == null) {
            return absolute;
        }
        return existing.toRealPath().resolve(existing.relativize(absolute));
    }

    /** The nearest directory with a {@code plugin.json} above the JAR this class came from. */
    static Path findPackageDirectory() {
        try {
            CodeSource source = StateStore.class.getProtectionDomain().getCodeSource();
            URL location = source == null ? null : source.getLocation();
            if (location == null) {
                return null;
            }
            Path current = Paths.get(location.toURI()).toAbsolutePath();
            if (Files.isRegularFile(current)) {
                current = current.getParent();
            }
            while (current != null) {
                if (Files.isRegularFile(current.resolve("plugin.json"))) {
                    return current;
                }
                current = current.getParent();
            }
            return null;
        } catch (URISyntaxException | RuntimeException error) {
            return null;
        }
    }
}
