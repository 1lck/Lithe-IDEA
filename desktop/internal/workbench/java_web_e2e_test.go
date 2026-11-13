package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A second source proves servlet APIs resolve and a request-handling thread
// can actually stop, inspect locals, continue, and stop with its owned JVM.
type javaDocumentProbe struct {
	path           string
	completionLine int
	completionCol  int
	completion     string
	breakpointLine int
	frame          string
}

func (probe *javaDocumentProbe) prepare(t *testing.T, h *harness, p *project, main *document) {
	t.Helper()
	h.app.openFile(p, filepath.Join(p.root, probe.path))
	awaitStateWithin(t, h, 30*time.Second, "servlet source", func() bool { return p.docs.byPath(filepath.Join(p.root, probe.path)) != nil })
	d := p.docs.byPath(filepath.Join(p.root, probe.path))
	if !d.view.GoToNavigation(probe.completionLine, probe.completionCol, false) {
		t.Fatal("servlet completion caret")
	}
	h.app.startPluginCompletion(p, d, probe.completionLine, probe.completionCol)
	awaitStateWithin(t, h, 30*time.Second, "servlet API completion", func() bool {
		for _, item := range h.app.semantics.completion.items {
			if strings.Contains(item.Label, probe.completion) {
				return true
			}
		}
		return false
	})
	h.app.closeSemanticCompletion()
	if !d.view.GoToNavigation(probe.breakpointLine, 2, false) {
		t.Fatal("servlet breakpoint caret")
	}
	h.app.toggleBreakpoint(p)
	h.app.selectDocument(p, main.id)
	awaitStateWithin(t, h, 10*time.Second, "main source selected", func() bool { return p.selectedDocument(p.docs.group) == main })
	t.Log("servlet API completion and request-handler breakpoint prepared")
}

func (probe *javaDocumentProbe) awaitBreakpoint(t *testing.T, h *harness, p *project) {
	t.Helper()
	awaitStateWithin(t, h, 60*time.Second, "servlet request breakpoint", func() bool {
		return p.debug.activeSession() != nil && p.debug.state == "paused" && len(p.debug.frames) > 0 && strings.Contains(p.debug.frames[0].Name, probe.frame)
	})
	awaitStateWithin(t, h, 15*time.Second, "servlet local variable", func() bool {
		for _, scope := range p.debug.vars.scopes {
			if scope.container != nil {
				if node := findDebugVariable(scope.container.nodes, "answer"); node != nil && node.value == "41" {
					return true
				}
			}
		}
		return false
	})
	t.Log("servlet request paused with answer=41")
}

// This is a real javax Servlet/JSP application: Maven creates its WAR, embedded
// Tomcat serves HTTP, Jasper compiles JSP/EL/JSTL, and Java handlers are debugged.
// It does not claim JSP editor semantics, JSP line breakpoints or deployment
// into an externally managed application server.
func TestJavaPluginLegacyJspWar(t *testing.T) {
	if os.Getenv("LITHE_TEST_JAVA_WEB") != "1" {
		t.Skip("set LITHE_TEST_JAVA_WEB=1 and LITHE_TEST_JAVA8_HOME")
	}
	java8 := os.Getenv("LITHE_TEST_JAVA8_HOME")
	if java8 == "" {
		t.Fatal("the legacy JSP application requires LITHE_TEST_JAVA8_HOME")
	}
	fixture := standardJavaFixture()
	pom := javaFixturePOM("1.8", `<build><plugins><plugin><artifactId>maven-war-plugin</artifactId><version>3.4.0</version><configuration><failOnMissingWebXml>false</failOnMissingWebXml></configuration></plugin></plugins></build>`)
	pom = strings.Replace(pom, "<version>1.0</version>", "<version>1.0</version><packaging>war</packaging>", 1)
	pom = strings.Replace(pom, "<dependencies>", `<dependencies><dependency><groupId>org.apache.tomcat.embed</groupId><artifactId>tomcat-embed-core</artifactId><version>9.0.82</version></dependency><dependency><groupId>org.apache.tomcat.embed</groupId><artifactId>tomcat-embed-jasper</artifactId><version>9.0.82</version></dependency><dependency><groupId>javax.servlet</groupId><artifactId>jstl</artifactId><version>1.2</version></dependency>`, 1)
	fixture.files["pom.xml"] = pom
	fixture.files[fixture.mainPath] = strings.Replace(javaWorkflowMain, `org.apache.commons.lang3.StringUtils.reverse("avaj")`, "LegacyWeb.render()", 1)
	fixture.files["src/main/java/demo/ProbeServlet.java"] = `package demo;
public class ProbeServlet extends javax.servlet.http.HttpServlet {
 protected void doGet(javax.servlet.http.HttpServletRequest request, javax.servlet.http.HttpServletResponse response) throws java.io.IOException {
  int answer = 41;
  answer += 1;
  response.getWriter().print("servlet-result=" + answer);
 }
}
`
	fixture.files["src/main/java/demo/LegacyWeb.java"] = `package demo;
public class LegacyWeb {
 public static String render() {
  org.apache.catalina.startup.Tomcat server = new org.apache.catalina.startup.Tomcat();
  server.setBaseDir(new java.io.File("target/tomcat").getAbsolutePath());
  server.setPort(0);
  server.getConnector().setProperty("address", "127.0.0.1");
  org.apache.catalina.Context context = server.addWebapp("", new java.io.File("src/main/webapp").getAbsolutePath());
  context.setParentClassLoader(LegacyWeb.class.getClassLoader());
  org.apache.catalina.startup.Tomcat.addServlet(context, "probe", new ProbeServlet());
  context.addServletMappingDecoded("/probe", "probe");
  try {
   server.start();
   int port = server.getConnector().getLocalPort();
   if (!read(port, "/probe").contains("servlet-result=42")) throw new IllegalStateException("servlet response");
   String jsp = read(port, "/index.jsp");
   if (!jsp.contains("jsp-result=42;el=42;jstl=42")) throw new IllegalStateException("JSP/EL/JSTL response: " + jsp);
   return "java";
  } catch (Exception error) {
   throw new RuntimeException(error);
  } finally {
   try { server.stop(); server.destroy(); } catch (Exception error) { throw new RuntimeException(error); }
  }
 }
 private static String read(int port, String path) throws java.io.IOException {
  java.net.HttpURLConnection connection = (java.net.HttpURLConnection) new java.net.URL("http://127.0.0.1:" + port + path).openConnection();
  connection.setConnectTimeout(5000);
  connection.setReadTimeout(60000);
  try (java.io.InputStream stream = connection.getInputStream(); java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream()) {
   byte[] buffer = new byte[1024];
   for (int count; (count = stream.read(buffer)) >= 0;) {
    if (bytes.size() + count > 65536) throw new java.io.IOException("response exceeds fixture limit");
    bytes.write(buffer, 0, count);
   }
   return new String(bytes.toByteArray(), java.nio.charset.StandardCharsets.UTF_8);
  } finally { connection.disconnect(); }
 }
}
`
	fixture.files["src/main/webapp/index.jsp"] = `<%@ page contentType="text/plain; charset=UTF-8" %><%@ taglib uri="http://java.sun.com/jsp/jstl/core" prefix="c" %><%@ include file="/WEB-INF/片段 旧.jspf" %>`
	fixture.files["src/main/webapp/WEB-INF/片段 旧.jspf"] = `<% int value = 41; %>jsp-result=<%= value + 1 %>;el=${40+2};jstl=<c:out value="${40+2}"/>`
	fixture.javaHome, fixture.vmVersion, fixture.classVersion, fixture.packageGoal = java8, "1.8", 52, true
	fixture.documentProbe = &javaDocumentProbe{path: "src/main/java/demo/ProbeServlet.java", completionLine: 5, completionCol: 11, completion: "getWriter", breakpointLine: 4, frame: "ProbeServlet.doGet"}
	runJavaPluginWorkflow(t, fixture)
}
