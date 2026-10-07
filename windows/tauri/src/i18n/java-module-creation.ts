export const javaModuleEnglish = {
  "javaModule.newModule": "Module…",
  "javaModule.moduleTitle": "New Module",
  "javaModule.moduleName": "Module name",
  "javaModule.moduleHint":
    "Creates an independent Java or Spring Boot module and adds it to this workspace. Does not rewrite the parent POM or Gradle settings; configure aggregation/dependencies separately when required.",
  "javaModule.moduleCreated":
    "Module created but could not be attached. Add this folder to the workspace: {path}",
  "javaModule.workspaceChanged":
    "The active workspace changed. No module was attached. Created folder: {path}",
  "javaModule.project": "Java project",
  "javaModule.spring": "Spring Boot",
  "javaModule.typeKind": "Kind",
  "javaModule.create": "Create",
  "javaModule.cancel": "Cancel",
};

export const javaModuleChinese: Record<keyof typeof javaModuleEnglish, string> = {
  "javaModule.newModule": "模块…",
  "javaModule.moduleTitle": "新建模块",
  "javaModule.moduleName": "模块名称",
  "javaModule.moduleHint":
    "创建独立的 Java 或 Spring Boot 模块并加入当前工作区。不改写父项目 POM 或 Gradle settings；如需父工程统一构建/依赖，请另行配置聚合关系。",
  "javaModule.moduleCreated": "模块已创建但未能加入工作区，请手动添加目录：{path}",
  "javaModule.workspaceChanged": "当前工作区已切换，未添加模块。已创建目录：{path}",
  "javaModule.project": "Java 项目",
  "javaModule.spring": "Spring Boot",
  "javaModule.typeKind": "类型",
  "javaModule.create": "创建",
  "javaModule.cancel": "取消",
};
