package workbench

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// The real wrapper and plugin archive are explicit integration inputs. The
// unusual module directory and a library dependency exercise Gradle's own model,
// Buildship classpaths and the same editor Run/Debug flow as a Maven project.
func TestJavaPluginGradleLegacyReactor(t *testing.T) {
	archive, wrapper, java8 := os.Getenv("LITHE_TEST_GRADLE_PLUGIN_ARCHIVE"), os.Getenv("LITHE_TEST_GRADLE_WRAPPER_DIR"), os.Getenv("LITHE_TEST_JAVA8_HOME")
	if archive == "" || wrapper == "" || java8 == "" {
		t.Skip("set LITHE_TEST_GRADLE_PLUGIN_ARCHIVE, LITHE_TEST_GRADLE_WRAPPER_DIR and LITHE_TEST_JAVA8_HOME")
	}
	gradleUserHome := t.TempDir()
	t.Setenv("GRADLE_USER_HOME", gradleUserHome)
	t.Setenv("JAVA_HOME", java8)
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		var command *exec.Cmd
		if runtime.GOOS == "windows" {
			command = exec.CommandContext(ctx, "cmd", "/c", filepath.Join(wrapper, "gradlew.bat"), "--stop")
		} else {
			command = exec.CommandContext(ctx, "/bin/sh", filepath.Join(wrapper, "gradlew"), "--stop")
		}
		command.WaitDelay = 3 * time.Second
		if output, err := command.CombinedOutput(); err != nil {
			t.Errorf("stop owned Gradle daemons: %v %s", err, output)
		}
	})
	fixture := javaWorkflowFixture{
		noMaven: true, javaHome: java8, vmVersion: "1.8", buildArchive: archive,
		buildSystem: "gradle", buildProject: "old-app", buildTask: "compileJava",
		mainPath: "模块 old app/src/main/java/demo/Main.java", classPath: "模块 old app/build/classes/java/main/demo/Main.class",
		executablePaths: []string{"gradlew"},
		files: map[string]string{
			"settings.gradle":   "rootProject.name='legacy-gradle'\ninclude 'old-lib', 'old-app'\nproject(':old-app').projectDir=file('模块 old app')\n",
			"build.gradle":      "subprojects { apply plugin: 'java'; sourceCompatibility='1.8'; targetCompatibility='1.8' }\nproject(':old-app') { dependencies { implementation project(':old-lib') } }\n",
			"gradle.properties": "org.gradle.daemon=false\norg.gradle.workers.max=1\norg.gradle.jvmargs=-Xms32m -Xmx256m -XX:MaxMetaspaceSize=256m\norg.gradle.java.home=" + strings.ReplaceAll(java8, "\\", "/") + "\n",
			"old-lib/src/main/java/demo/LegacyPart.java": `package demo; public class LegacyPart { public static String label() { return "java"; } }`,
		},
	}
	fixture.files[fixture.mainPath] = strings.ReplaceAll(javaWorkflowMain, `org.apache.commons.lang3.StringUtils.reverse("avaj")`, `LegacyPart.label()`)
	for _, name := range []string{"gradlew", "gradlew.bat", "gradle/wrapper/gradle-wrapper.jar", "gradle/wrapper/gradle-wrapper.properties"} {
		data, err := os.ReadFile(filepath.Join(wrapper, name))
		if err != nil {
			t.Fatal(err)
		}
		fixture.files[name] = string(data)
	}
	runJavaPluginWorkflow(t, fixture)
}
