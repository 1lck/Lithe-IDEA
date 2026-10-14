export const javaProjectEnglish = {
  "javaProject.project": "Java project",
  "javaProject.projectDescription":
    "A plain Java project with Main.java. Uses your configured JDK.",
  "javaProject.spring": "Spring Boot",
  "javaProject.springDescription":
    "Generate a Maven or Gradle project with official Spring Initializr.",
  "javaProject.group": "Group ID",
  "javaProject.artifact": "Artifact ID",
  "javaProject.package": "Package name",
  "javaProject.bootVersion": "Spring Boot version",
  "javaProject.javaVersion": "Java version",
  "javaProject.buildTool": "Build tool",
  "javaProject.dependencies": "Dependencies",
  "javaProject.searchDependencies": "Search dependencies…",
  "javaProject.loading": "Loading available versions from start.spring.io…",
  "javaProject.retry": "Retry",
  "javaProject.online":
    "Requires Internet access. Generates Java / JAR projects using start.spring.io; no build scripts are executed during creation.",
  "javaProject.invalidPackage": "Use dot-separated Java identifiers, for example com.example.app.",
};

export const javaProjectChinese: Record<keyof typeof javaProjectEnglish, string> = {
  "javaProject.project": "Java 项目",
  "javaProject.projectDescription": "创建包含 Main.java 的普通 Java 项目，使用设置中的 JDK。",
  "javaProject.spring": "Spring Boot",
  "javaProject.springDescription": "通过官方 Spring Initializr 生成 Maven 或 Gradle 项目。",
  "javaProject.group": "Group ID（组织）",
  "javaProject.artifact": "Artifact ID（模块）",
  "javaProject.package": "包名",
  "javaProject.bootVersion": "Spring Boot 版本",
  "javaProject.javaVersion": "Java 版本",
  "javaProject.buildTool": "构建工具",
  "javaProject.dependencies": "依赖",
  "javaProject.searchDependencies": "搜索依赖…",
  "javaProject.loading": "正在从 start.spring.io 获取可用版本…",
  "javaProject.retry": "重试",
  "javaProject.online":
    "需要联网。使用 start.spring.io 生成 Java / JAR 项目；创建时不执行构建脚本。",
  "javaProject.invalidPackage": "请使用点分隔的合法 Java 包名，例如 com.example.app。",
};
