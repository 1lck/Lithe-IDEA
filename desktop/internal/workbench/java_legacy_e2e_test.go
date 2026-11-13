package workbench

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const javaWorkflowMain = "package demo;\npublic class Main {\n public static void main(String[] args) {\n  int answer = 41;\n  answer += 1;\n  System.out.println(org.apache.commons.lang3.StringUtils.reverse(\"avaj\") + \"-result=\" + answer + \";vm=\" + System.getProperty(\"java.specification.version\"));\n }\n}\n"

func javaFixturePOM(source, body string) string {
	return fmt.Sprintf(`<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion><groupId>demo</groupId><artifactId>java-pilot</artifactId><version>1.0</version><properties><maven.compiler.source>%s</maven.compiler.source><maven.compiler.target>%s</maven.compiler.target><project.build.sourceEncoding>UTF-8</project.build.sourceEncoding></properties><dependencies><dependency><groupId>org.apache.commons</groupId><artifactId>commons-lang3</artifactId><version>3.17.0</version></dependency></dependencies>%s</project>`, source, source, body)
}

// A fixed historical checkout is supplied externally and copied; this test
// never changes the downloaded baseline or vendors upstream code into Lithe.
func TestJavaPluginHistoricalProject(t *testing.T) {
	root := os.Getenv("LITHE_TEST_JAVA_HISTORICAL_ROOT")
	if root == "" {
		t.Skip("set LITHE_TEST_JAVA_HISTORICAL_ROOT and LITHE_TEST_JAVA_HISTORICAL_PROBE")
	}
	probe := os.Getenv("LITHE_TEST_JAVA_HISTORICAL_PROBE")
	java8 := os.Getenv("LITHE_TEST_JAVA8_HOME")
	if probe == "" || java8 == "" {
		t.Fatal("historical project requires a Java 8 home and a Java expression probing its API")
	}
	fixture := standardJavaFixture()
	fixture.files = map[string]string{fixture.mainPath: strings.Replace(javaWorkflowMain, `org.apache.commons.lang3.StringUtils.reverse("avaj")`, `"java"`, 1)}
	fixture.files[fixture.mainPath] = strings.Replace(fixture.files[fixture.mainPath], `System.getProperty("java.specification.version")`, `System.getProperty("java.specification.version") + ";probe=" + (`+probe+`)`, 1)
	fixture.projectRoot, fixture.javaHome, fixture.vmVersion = root, java8, "1.8"
	fixture.expectBuildRefused = os.Getenv("LITHE_TEST_JAVA_EXPECT_BUILD_REFUSAL") == "1"
	if level := os.Getenv("LITHE_TEST_JAVA_HISTORICAL_SOURCE"); level != "" {
		if level != "1.8" {
			t.Fatal("historical override only supports explicit source/target 1.8")
		}
		pom, err := os.ReadFile(filepath.Join(root, "pom.xml"))
		if err != nil {
			t.Fatal(err)
		}
		text := string(pom)
		for _, key := range []string{"source", "target"} {
			old := "<maven.compiler." + key + ">1.5</maven.compiler." + key + ">"
			if !strings.Contains(text, old) {
				t.Fatalf("historical POM lacks exact %s=1.5 property", key)
			}
			text = strings.ReplaceAll(text, old, "<maven.compiler."+key+">1.8</maven.compiler."+key+">")
		}
		fixture.files["pom.xml"] = text
		t.Log("temporary copy only: POM compiler source/target changed from 1.5 to 1.8; this does not verify original Java 5 configuration")
	}
	runJavaPluginWorkflow(t, fixture)
}

func copyHistoricalJavaProject(t *testing.T, source, target string) {
	t.Helper()
	files, bytes := 0, int64(0)
	err := filepath.WalkDir(source, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() && (entry.Name() == ".git" || entry.Name() == "target") {
			return filepath.SkipDir
		}
		if entry.IsDir() {
			return nil
		}
		if !entry.Type().IsRegular() {
			return fmt.Errorf("historical fixture must contain regular files: %s", path)
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		files++
		bytes += info.Size()
		if files > 5000 || bytes > 100<<20 {
			return fmt.Errorf("historical fixture exceeds 5000 files or 100 MiB")
		}
		rel, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		destination := filepath.Join(target, rel)
		if err := os.MkdirAll(filepath.Dir(destination), 0700); err != nil {
			return err
		}
		return os.WriteFile(destination, data, 0600)
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("historical project copied: %d files, %d bytes; upstream POM unchanged", files, bytes)
}

func standardJavaFixture() javaWorkflowFixture {
	return javaWorkflowFixture{files: map[string]string{"pom.xml": javaFixturePOM("17", ""), "src/main/java/demo/Main.java": javaWorkflowMain}, mainPath: "src/main/java/demo/Main.java", classPath: "target/classes/demo/Main.class"}
}

// These are deliberately opt-in real-tool integrations, not unit tests. Each
// subtest owns a separate install, workspace, JDT data area and process lifetime.
func TestJavaPluginLegacyWorkflows(t *testing.T) {
	if os.Getenv("LITHE_TEST_JAVA_LEGACY") != "1" {
		t.Skip("set LITHE_TEST_JAVA_LEGACY=1 and JAVA8/JAVA11 test homes")
	}
	java8, java11 := os.Getenv("LITHE_TEST_JAVA8_HOME"), os.Getenv("LITHE_TEST_JAVA11_HOME")
	if java8 == "" || java11 == "" {
		t.Fatal("legacy matrix requires LITHE_TEST_JAVA8_HOME and LITHE_TEST_JAVA11_HOME")
	}
	for _, source := range []struct {
		name, level string
		major       byte
	}{{"java8", "1.8", 52}} {
		t.Run(source.name, func(t *testing.T) {
			fixture := standardJavaFixture()
			fixture.files["pom.xml"] = javaFixturePOM(source.level, "")
			fixture.javaHome, fixture.vmVersion, fixture.classVersion = java8, "1.8", source.major
			runJavaPluginWorkflow(t, fixture)
		})
	}
	t.Run("maven2-custom-layout", func(t *testing.T) {
		fixture := standardJavaFixture()
		fixture.files = map[string]string{
			"pom.xml":                 javaFixturePOM("1.8", `<build><sourceDirectory>src/java</sourceDirectory><outputDirectory>build/classes</outputDirectory></build>`),
			"src/java/demo/Main.java": javaWorkflowMain,
		}
		fixture.mainPath, fixture.classPath = "src/java/demo/Main.java", "build/classes/demo/Main.class"
		fixture.javaHome, fixture.vmVersion = java8, "1.8"
		runJavaPluginWorkflow(t, fixture)
	})
	t.Run("reactor-unicode-space-path", func(t *testing.T) {
		fixture := standardJavaFixture()
		fixture.files = map[string]string{
			"pom.xml":         `<project><modelVersion>4.0.0</modelVersion><groupId>demo</groupId><artifactId>parent</artifactId><version>1.0</version><packaging>pom</packaging><modules><module>library</module><module>旧 模块</module></modules></project>`,
			"library/pom.xml": strings.Replace(javaFixturePOM("11", ""), "<artifactId>java-pilot</artifactId>", "<artifactId>legacy-library</artifactId>", 1),
			"library/src/main/java/demo/LegacyLibrary.java": `package demo; public class LegacyLibrary { public static String label() { return "java"; } }`,
			"旧 模块/pom.xml":                                  strings.Replace(javaFixturePOM("11", ""), "<dependencies>", "<dependencies><dependency><groupId>demo</groupId><artifactId>legacy-library</artifactId><version>1.0</version></dependency>", 1),
			"旧 模块/src/main/java/demo/Main.java":             strings.Replace(javaWorkflowMain, `org.apache.commons.lang3.StringUtils.reverse("avaj")`, `LegacyLibrary.label()`, 1),
		}
		fixture.mainPath, fixture.classPath = "旧 模块/src/main/java/demo/Main.java", "旧 模块/target/classes/demo/Main.class"
		fixture.javaHome, fixture.vmVersion, fixture.classVersion = java11, "11", 55
		runJavaPluginWorkflow(t, fixture)
	})
	t.Run("active-profile-source-root", func(t *testing.T) {
		fixture := standardJavaFixture()
		fixture.files = map[string]string{
			"pom.xml":                javaFixturePOM("1.8", `<build><sourceDirectory>${legacy.source}</sourceDirectory></build><profiles><profile><id>legacy</id><activation><activeByDefault>true</activeByDefault></activation><properties><legacy.source>old-src</legacy.source></properties></profile></profiles>`),
			"old-src/demo/Main.java": javaWorkflowMain,
		}
		fixture.mainPath, fixture.javaHome, fixture.vmVersion = "old-src/demo/Main.java", java8, "1.8"
		runJavaPluginWorkflow(t, fixture)
	})
	t.Run("java8-javax-jaxb", func(t *testing.T) {
		fixture := standardJavaFixture()
		fixture.files["pom.xml"] = javaFixturePOM("1.8", "")
		fixture.files[fixture.mainPath] = strings.Replace(javaWorkflowMain, `org.apache.commons.lang3.StringUtils.reverse("avaj")`, `new String(javax.xml.bind.DatatypeConverter.parseHexBinary("6A617661"), java.nio.charset.StandardCharsets.UTF_8)`, 1)
		fixture.javaHome, fixture.vmVersion = java8, "1.8"
		runJavaPluginWorkflow(t, fixture)
	})
	for _, framework := range []struct{ name, version, source string }{
		{"junit3", "3.8.2", "package demo; public class LegacyTest extends junit.framework.TestCase { public void testLegacy() { assertEquals(42, 41+1); } }"},
		{"junit4", "4.12", "package demo; public class LegacyTest { @org.junit.Test public void legacy() { org.junit.Assert.assertEquals(42,41+1); } }"},
	} {
		t.Run(framework.name, func(t *testing.T) {
			fixture := standardJavaFixture()
			fixture.files["pom.xml"] = strings.Replace(javaFixturePOM("1.8", ""), "<dependencies>", "<dependencies><dependency><groupId>junit</groupId><artifactId>junit</artifactId><version>"+framework.version+"</version><scope>test</scope></dependency>", 1)
			fixture.files["src/test/java/demo/LegacyTest.java"] = framework.source
			fixture.javaHome, fixture.vmVersion, fixture.testGoal = java8, "1.8", true
			runJavaPluginWorkflow(t, fixture)
		})
	}
	t.Run("eclipse-ant-layout", func(t *testing.T) {
		fixture := standardJavaFixture()
		fixture.files = map[string]string{
			".project":                             `<projectDescription><name>legacy-ant</name><buildSpec><buildCommand><name>org.eclipse.jdt.core.javabuilder</name></buildCommand></buildSpec><natures><nature>org.eclipse.jdt.core.javanature</nature></natures></projectDescription>`,
			".classpath":                           `<classpath><classpathentry kind="src" path="src"/><classpathentry kind="con" path="org.eclipse.jdt.launching.JRE_CONTAINER"/><classpathentry kind="output" path="bin"/></classpath>`,
			".settings/org.eclipse.jdt.core.prefs": "eclipse.preferences.version=1\norg.eclipse.jdt.core.compiler.codegen.targetPlatform=1.8\norg.eclipse.jdt.core.compiler.compliance=1.8\norg.eclipse.jdt.core.compiler.source=1.8\n",
			"build.xml":                            `<project name="legacy-ant"><target name="compile"><mkdir dir="bin"/><javac srcdir="src" destdir="bin" source="1.8" target="1.8" includeantruntime="false"/></target></project>`,
			"src/demo/Main.java":                   strings.ReplaceAll(javaWorkflowMain, `org.apache.commons.lang3.StringUtils.reverse("avaj")`, `"java"`),
		}
		fixture.mainPath, fixture.classPath = "src/demo/Main.java", "bin/demo/Main.class"
		fixture.javaHome, fixture.vmVersion, fixture.noMaven = java8, "1.8", true
		runJavaPluginWorkflow(t, fixture)
	})
}

func TestJavaPluginLegacySourceBoundaries(t *testing.T) {
	if os.Getenv("LITHE_TEST_JAVA_LEGACY") != "1" {
		t.Skip("set LITHE_TEST_JAVA_LEGACY=1")
	}
	java8 := os.Getenv("LITHE_TEST_JAVA8_HOME")
	if java8 == "" {
		t.Fatal("set LITHE_TEST_JAVA8_HOME")
	}
	for _, source := range []struct {
		name, level string
		major       byte
	}{{"java5", "1.5", 49}, {"java7", "1.7", 51}} {
		t.Run(source.name, func(t *testing.T) {
			fixture := standardJavaFixture()
			fixture.files["pom.xml"] = javaFixturePOM(source.level, "")
			fixture.javaHome, fixture.classVersion, fixture.expectBuildRefused = java8, source.major, true
			runJavaPluginWorkflow(t, fixture)
		})
	}
}
