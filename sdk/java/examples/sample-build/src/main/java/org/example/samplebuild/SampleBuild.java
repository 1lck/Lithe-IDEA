package org.example.samplebuild;

import io.github.litheidea.plugin.sdk.Backend;
import io.github.litheidea.plugin.sdk.CallContext;
import io.github.litheidea.plugin.sdk.Json;
import io.github.litheidea.plugin.sdk.PluginError;
import io.github.litheidea.plugin.sdk.Processes;
import io.github.litheidea.plugin.sdk.StateStore;
import java.io.IOException;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Sample Lithe plugin backend built on the official Java SDK; the Java twin of
 * {@code sdk/node/examples/sample-build}.
 *
 * <p>It is the build provider of the fictional "sample" build system, whose
 * workspace file {@code lithe-sample.json} lists projects:
 *
 * <pre>
 * { "projects": [{ "name": "app", "path": "app",
 *                  "build": ["/usr/bin/make"],
 *                  "dependencies": [{ "name": "left-pad", "version": "1.3.0" }] }] }
 * </pre>
 *
 * <p>It shows the three things a backend does:
 * <ul>
 *   <li>answers Lithe's typed build requests ({@code lithe/build/model},
 *       {@code lithe/build/dependencies}), whose results Lithe itself understands;</li>
 *   <li>offers plugin functions for its own UI: {@code workspace.build} runs a
 *       multi-step build (prepare, run each project's tool, record a snapshot),
 *       and {@code snapshot.read} returns the last snapshot, also after a restart;</li>
 *   <li>registers {@code snapshot.clear} at runtime once there is a snapshot to clear.</li>
 * </ul>
 *
 * <p>A packaged plugin shades the SDK into its own JAR, as this module's POM does.
 */
public final class SampleBuild {
    private final Backend backend = Backend.create("sample-build", "0.1.0");
    private final String stateDirectory;
    private volatile Path workspaceRoot;
    private volatile StateStore store;

    private SampleBuild(String stateDirectory) {
        this.stateDirectory = stateDirectory;
    }

    public static void main(String[] arguments) {
        new SampleBuild(argument(arguments, "--state")).serve();
    }

    private void serve() {
        backend.onInitialize((params, negotiated) -> {
            // `Paths.get(URI)` accepts the trailing slash a directory URI may carry.
            workspaceRoot = Paths.get(URI.create((String) params.get("rootUri"))).toAbsolutePath().normalize();
            // `--state ${workspaceStateDir}` in plugin.json: the host's writable
            // directory for this workspace. The package itself is read-only.
            store = StateStore.open(Paths.get(stateDirectory));
            if (store.read("snapshot", null) != null) {
                offerClear();
            }
        });

        backend.onModel((params, context) -> {
            List<Object> projects = new ArrayList<>();
            for (Map<String, Object> project : readConfig(Json.string(params, "root"))) {
                projects.add(object("name", project.get("name"), "path", project.get("path")));
            }
            return object("projects", projects);
        });

        backend.onDependencies((params, context) -> {
            Object selected = params.get("project");
            String path = selected instanceof Map ? Json.string(Json.object(selected), "path") : null;
            List<Object> dependencies = new ArrayList<>();
            for (Map<String, Object> project : readConfig(Json.string(params, "root"))) {
                if (path != null && !path.equals(project.get("path"))) {
                    continue;
                }
                Object declared = project.get("dependencies");
                if (declared instanceof List) {
                    for (Object entry : (List<?>) declared) {
                        Map<String, Object> dependency = Json.object(entry);
                        dependencies.add(object("name", dependency.get("name"), "version", dependency.get("version"),
                                "children", new ArrayList<>()));
                    }
                }
            }
            return object("dependencies", dependencies);
        });

        backend.function("workspace.build", this::build);
        backend.function("snapshot.read", (params, context) -> store.read("snapshot", null));
        backend.listen();
    }

    private Object build(Map<String, Object> params, CallContext context) throws IOException {
        // Step 1: prepare. Read the workspace file and resolve the selection.
        context.progress("Preparing", 0.0);
        List<Map<String, Object>> projects = selectProjects(readConfig("."), params.get("projects"));

        // Step 2: run each project's tool. `context.run` stops the tool when
        // Lithe cancels the call, so a cancelled build leaves nothing behind.
        List<Object> results = new ArrayList<>();
        for (int index = 0; index < projects.size(); index++) {
            Map<String, Object> project = projects.get(index);
            String name = (String) project.get("name");
            context.progress("Building " + name, 100.0 * index / projects.size());
            List<String> command = new ArrayList<>();
            for (Object part : (List<?>) project.get("build")) {
                command.add((String) part);
            }
            Processes.Result result = context.run(command, new Processes.Options()
                    .directory(inside(workspaceRoot, (String) project.get("path")))
                    .onStdout(text -> context.log("[" + name + "] " + text.trim())));
            results.add(object("name", name, "exitCode", result.exitCode()));
            if (result.exitCode() != 0) {
                record(results, "failed");
                throw new PluginError("sample.buildFailed", name + " failed with exit code " + result.exitCode() + ".");
            }
        }

        // Step 3: record the outcome, so `snapshot.read` returns it after a restart.
        Object snapshot = record(results, "succeeded");
        context.progress("Done", 100.0);
        return snapshot;
    }

    /**
     * Reads the latest snapshot when the build ends, not when it starts: two
     * overlapping builds then get consecutive generations instead of the same
     * one. Handlers run on their own threads, so the read and the write hold
     * one lock.
     */
    private synchronized Object record(List<Object> projects, String status) throws IOException {
        Object previous = store.read("snapshot", null);
        long generation = previous instanceof Map
                ? ((Number) Json.object(previous).get("generation")).longValue() + 1
                : 1;
        Map<String, Object> snapshot = object("generation", generation, "status", status, "projects", projects);
        store.write("snapshot", snapshot);
        offerClear();
        return snapshot;
    }

    private void offerClear() {
        if (backend.functionIds().contains("snapshot.clear")) {
            return;
        }
        backend.registerFunction("snapshot.clear", (params, context) -> {
            store.delete("snapshot");
            return null;
        }).whenComplete((ignored, error) -> {
            if (error != null) {
                backend.log("snapshot.clear stays unavailable: " + error.getMessage());
            }
        });
    }

    /** Every project, or exactly the named ones; an unknown name is an error, not an empty build. */
    private static List<Map<String, Object>> selectProjects(List<Map<String, Object>> projects, Object selected) {
        if (selected == null) {
            return projects;
        }
        if (!(selected instanceof List) || ((List<?>) selected).isEmpty()
                || !((List<?>) selected).stream().allMatch(name -> name instanceof String)) {
            throw new PluginError("sample.selection", "\"projects\" must be a non-empty list of project names.");
        }
        List<String> unknown = new ArrayList<>();
        for (Object name : (List<?>) selected) {
            if (projects.stream().noneMatch(project -> name.equals(project.get("name")))) {
                unknown.add((String) name);
            }
        }
        if (!unknown.isEmpty()) {
            throw new PluginError("sample.unknownProject", "Unknown project: " + String.join(", ", unknown) + ".");
        }
        List<Map<String, Object>> chosen = new ArrayList<>();
        for (Map<String, Object> project : projects) {
            if (((List<?>) selected).contains(project.get("name"))) {
                chosen.add(project);
            }
        }
        return chosen;
    }

    private List<Map<String, Object>> readConfig(String root) {
        Object config;
        try {
            Path file = inside(workspaceRoot, root == null ? "." : root).resolve("lithe-sample.json");
            config = Json.parse(new String(Files.readAllBytes(file), StandardCharsets.UTF_8));
        } catch (IOException | RuntimeException error) {
            if (error instanceof PluginError) {
                throw (PluginError) error;
            }
            throw new PluginError("sample.config", "lithe-sample.json is missing or is not valid JSON.");
        }
        Object projects = config instanceof Map ? ((Map<?, ?>) config).get("projects") : null;
        if (!(projects instanceof List)) {
            throw new PluginError("sample.config", "lithe-sample.json needs a \"projects\" list.");
        }
        List<Map<String, Object>> result = new ArrayList<>();
        for (Object project : (List<?>) projects) {
            result.add(Json.object(project));
        }
        return result;
    }

    /** {@code relative} resolved inside {@code base}; workspace files never name paths outside it. */
    private static Path inside(Path base, String relative) {
        Path path = base.resolve(relative).normalize();
        if (Paths.get(relative).isAbsolute() || !path.startsWith(base)) {
            throw new PluginError("sample.path", relative + " is outside the workspace.");
        }
        return path;
    }

    private static Map<String, Object> object(Object... entries) {
        Map<String, Object> map = new LinkedHashMap<>();
        for (int index = 0; index < entries.length; index += 2) {
            map.put((String) entries[index], entries[index + 1]);
        }
        return map;
    }

    private static String argument(String[] arguments, String name) {
        for (int index = 0; index + 1 < arguments.length; index++) {
            if (arguments[index].equals(name)) {
                return arguments[index + 1];
            }
        }
        return null;
    }
}
