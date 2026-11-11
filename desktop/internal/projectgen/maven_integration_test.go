package projectgen

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// The real Maven plugin's generators, run through Core's plan and this executor.
// It is an integration test: it needs a checkout of the Maven plugin
// (LITHE_PLUGIN_MAVEN_DIR names the directory that holds its plugin.json) and,
// for the build check, an installed mvn. Without the checkout it is skipped.
func mavenPluginDirectory(t *testing.T) (string, []byte) {
	t.Helper()
	directory := os.Getenv("LITHE_PLUGIN_MAVEN_DIR")
	if directory == "" {
		t.Skip("LITHE_PLUGIN_MAVEN_DIR is not set")
	}
	manifest, err := os.ReadFile(filepath.Join(directory, "plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	return directory, manifest
}

func TestMavenPluginProjectGeneratesABuildableMavenProject(t *testing.T) {
	directory, manifest := mavenPluginDirectory(t)
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Minute)
	defer cancel()
	kernel := core.NewClient()
	// Core only needs a JDK's home and version for the templates; the files step runs no JDK.
	home := t.TempDir()
	input := core.ProjectGeneratorFormInput{
		ProjectName: "maven-demo",
		Values:      map[string]any{"jdk": home},
		Tools:       map[string][]core.ProjectToolInstallation{"jdk": {{Home: home, Version: "17.0.2"}}},
	}
	form, err := kernel.ProjectGeneratorFormOf(ctx, manifest, "maven-java", input)
	if err != nil || !form.Valid {
		t.Fatalf("form = %+v, %v", form, err)
	}
	plan, err := kernel.ProjectGenerationPlanOf(ctx, manifest, "maven-java", directory, input)
	if err != nil {
		t.Fatal(err)
	}
	parent := t.TempDir()
	result := Run(ctx, Request{Parent: parent, Name: "maven-demo", Plan: plan, Kernel: kernel})
	if result.Failure != nil {
		t.Fatal(result.Failure)
	}
	pom, err := os.ReadFile(filepath.Join(result.Path, "pom.xml"))
	if err != nil || !strings.Contains(string(pom), "<artifactId>maven-demo</artifactId>") || !strings.Contains(string(pom), "17") {
		t.Fatalf("pom.xml = %q, %v", pom, err)
	}
	if _, err := os.Stat(filepath.Join(result.Path, "src", "main", "java", "org", "example", "Main.java")); err != nil {
		t.Fatalf("the sample class was not generated: %v", err)
	}
	if !slices.Contains(result.OpenFiles, "src/main/java/org/example/Main.java") {
		t.Fatalf("open files = %v", result.OpenFiles)
	}
	mvn, lookErr := exec.LookPath("mvn")
	if lookErr != nil {
		return
	}
	// `validate` binds no plugin, so it checks the POM without the network.
	command := exec.CommandContext(ctx, mvn, "-B", "-q", "-o", "validate")
	command.Dir = result.Path
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("mvn validate failed: %v\n%s", err, output)
	}
}

func TestMavenPluginArchetypeRunsRealMaven(t *testing.T) {
	directory, manifest := mavenPluginDirectory(t)
	if os.Getenv("LITHE_INTEGRATION_NETWORK") == "" {
		t.Skip("LITHE_INTEGRATION_NETWORK is not set: the archetype plugin is downloaded from Maven Central")
	}
	if _, err := exec.LookPath("mvn"); err != nil {
		t.Skip("mvn is not installed")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Minute)
	defer cancel()
	kernel := core.NewClient()
	home := os.Getenv("JAVA_HOME")
	if home == "" {
		t.Skip("JAVA_HOME is not set")
	}
	input := core.ProjectGeneratorFormInput{
		ProjectName: "archetype-demo",
		Values:      map[string]any{"jdk": home},
		Tools:       map[string][]core.ProjectToolInstallation{"jdk": {{Home: home, Version: "17.0.2"}}},
	}
	plan, err := kernel.ProjectGenerationPlanOf(ctx, manifest, "maven-archetype", directory, input)
	if err != nil {
		t.Fatal(err)
	}
	parent := t.TempDir()
	result := Run(ctx, Request{Parent: parent, Name: "archetype-demo", Plan: plan, Kernel: kernel})
	if result.Failure != nil {
		t.Fatalf("%v\n%s", result.Failure, result.Failure.Tail)
	}
	if _, err := os.Stat(filepath.Join(result.Path, "pom.xml")); err != nil {
		t.Fatalf("the collected archetype project has no pom.xml: %v", err)
	}
}
