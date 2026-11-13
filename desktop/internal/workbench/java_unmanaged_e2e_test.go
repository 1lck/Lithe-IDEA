package workbench

import (
	"archive/zip"
	"bytes"
	"fmt"
	"os"
	"runtime"
	"strings"
	"testing"
)

// These workflows deliberately have no POM or Gradle model. The Ant case
// exercises JDT's source import, not an Ant target-discovery provider.
func TestJavaPluginUnmanagedProjects(t *testing.T) {
	if os.Getenv("LITHE_TEST_JAVA_UNMANAGED") != "1" {
		t.Skip("set LITHE_TEST_JAVA_UNMANAGED=1 and LITHE_TEST_JAVA8_HOME")
	}
	java8 := os.Getenv("LITHE_TEST_JAVA8_HOME")
	if java8 == "" {
		t.Fatal("unmanaged legacy projects require LITHE_TEST_JAVA8_HOME")
	}
	plainMain := strings.ReplaceAll(javaWorkflowMain, `org.apache.commons.lang3.StringUtils.reverse("avaj")`, `"java"`)
	for _, kind := range []string{"plain-source", "plain-library", "ant-source-tree", "eclipse-multiple-roots"} {
		t.Run(kind, func(t *testing.T) {
			fixture := javaWorkflowFixture{
				files: map[string]string{"src/demo/Main.java": plainMain}, mainPath: "src/demo/Main.java",
				javaHome: java8, vmVersion: "1.8", noMaven: true,
			}
			switch kind {
			case "plain-library":
				jar := os.Getenv("LITHE_TEST_JAVA_REFERENCE_JAR")
				if jar == "" {
					t.Fatal("set LITHE_TEST_JAVA_REFERENCE_JAR to commons-lang3 3.17.0")
				}
				info, err := os.Stat(jar)
				if err != nil || !info.Mode().IsRegular() || info.Size() > 8<<20 {
					t.Fatalf("reference JAR must be a regular file below 8 MiB: %v", err)
				}
				data, err := os.ReadFile(jar)
				if err != nil {
					t.Fatal(err)
				}
				fixture.files[fixture.mainPath] = javaWorkflowMain
				fixture.files["lib/commons-lang3.jar"] = string(data)
			case "ant-source-tree":
				fixture.mainPath = "old-source/demo/Main.java"
				fixture.files = map[string]string{
					fixture.mainPath: plainMain,
					"build.xml":      `<project name="legacy"><target name="compile"><mkdir dir="classes"/><javac srcdir="old-source" destdir="classes" source="1.8" target="1.8" includeantruntime="false"/></target></project>`,
				}
			case "eclipse-multiple-roots":
				fixture.files[".project"] = `<projectDescription><name>legacy-eclipse</name><buildSpec><buildCommand><name>org.eclipse.jdt.core.javabuilder</name></buildCommand></buildSpec><natures><nature>org.eclipse.jdt.core.javanature</nature></natures></projectDescription>`
				fixture.files[".classpath"] = `<classpath><classpathentry kind="src" path="src"/><classpathentry kind="src" path="generated-source"/><classpathentry kind="con" path="org.eclipse.jdt.launching.JRE_CONTAINER"/><classpathentry kind="output" path="classes"/></classpath>`
				fixture.files["generated-source/demo/LegacyPart.java"] = `package demo; public class LegacyPart { public static String label() { return "java"; } }`
				fixture.files[fixture.mainPath] = strings.ReplaceAll(javaWorkflowMain, `org.apache.commons.lang3.StringUtils.reverse("avaj")`, `LegacyPart.label()`)
				fixture.classPath = "classes/demo/Main.class"
			}
			runJavaPluginWorkflow(t, fixture)
		})
	}
}

// Empty valid JARs stress the real Windows command-line boundary without
// creating hundreds of copies of a large dependency or a false memory load.
func TestJavaPluginWindowsLongClasspath(t *testing.T) {
	if runtime.GOOS != "windows" || os.Getenv("LITHE_TEST_JAVA_LONG_CLASSPATH") != "1" {
		t.Skip("Windows integration: set LITHE_TEST_JAVA_LONG_CLASSPATH=1")
	}
	java8, jar := os.Getenv("LITHE_TEST_JAVA8_HOME"), os.Getenv("LITHE_TEST_JAVA_REFERENCE_JAR")
	if java8 == "" || jar == "" {
		t.Fatal("the Windows legacy classpath requires Java 8 and commons-lang3")
	}
	data, err := os.ReadFile(jar)
	if err != nil || len(data) > 8<<20 {
		t.Fatalf("reference JAR: %v", err)
	}
	var buffer bytes.Buffer
	archive := zip.NewWriter(&buffer)
	manifest, err := archive.Create("META-INF/MANIFEST.MF")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manifest.Write([]byte("Manifest-Version: 1.0\r\n\r\n")); err != nil {
		t.Fatal(err)
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	main := strings.Replace(javaWorkflowMain, "\n }\n}\n", `
  try { java.nio.file.Files.write(java.nio.file.Paths.get("run-classpath.txt"), System.getProperty("java.class.path").getBytes(java.nio.charset.StandardCharsets.UTF_8)); }
  catch (java.io.IOException error) { throw new RuntimeException(error); }
 }
}
`, 1)
	fixture := javaWorkflowFixture{files: map[string]string{"src/demo/Main.java": main, "lib/zz-real/commons-lang3.jar": string(data)}, mainPath: "src/demo/Main.java", javaHome: java8, vmVersion: "1.8", noMaven: true, temporaryClasspath: true}
	for i := range 300 {
		fixture.files[fmt.Sprintf("lib/中文 old module-with-extra-long-legacy-package-layout-%03d/empty.jar", i)] = buffer.String()
	}
	runJavaPluginWorkflow(t, fixture)
}
