# Agent 笔记：Windows新建菜单与Java源码模板

状态：已实现

## 先说结论

两个New菜单共享一个创建请求与对话框所有者；文件写入复用既有文件系统接口，并验证名称、同名目标及请求所属工作区；完成后不把结果打开到已切换的新工作区。切换工作区不会重定向或取消已发出的文件写入。Java模板只生成初始文本，包名建议不替代JDT源码根事实。资源树只处理物理包含在树内的DOM事件。

## 问题

File菜单与资源树入口分散，Java类型和包缺少一致的创建入口；树祖先事件还会误拦截通过portal显示的菜单。

## 决策

两个New菜单共享一个创建请求与对话框所有者；文件写入复用既有文件系统接口，并验证名称、同名目标及请求所属工作区；完成后不把结果打开到已切换的新工作区。切换工作区不会重定向或取消已发出的文件写入。Java模板只生成初始文本，包名建议不替代JDT源码根事实。资源树只处理物理包含在树内的DOM事件。

## 考虑过的备选方案

不为每个菜单维护一份创建流程；不通过正则构建Java语义索引；不移除全部树快捷键来回避portal事件冲突。

## 后果

增加模板和菜单状态测试；自定义源码根需要确认包名，非本地路径保持不可用。生成文件属于用户工作区，不写入安装目录；官方更新入口、现有快捷键和已支持菜单动作保留。

## 验证

- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/utils/java-name-validation.test.ts`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/file-explorer/lib/java-source-template.test.ts`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/file-explorer/lib/tree-dom-event.test.tsx`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/file-explorer/services/create-java-entry.test.ts`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/file-explorer/stores/new-entry.store.test.ts`

## 适用范围

- `windows/tauri/src/features/file-explorer/components/new-java-entry-dialog.tsx`
- `windows/tauri/src/features/file-explorer/components/file-explorer-tree.tsx`
- `windows/tauri/src/features/file-explorer/lib/java-source-template.ts`
- `windows/tauri/src/features/file-explorer/lib/java-source-template.test.ts`
- `windows/tauri/src/features/file-explorer/lib/tree-dom-event.ts`
- `windows/tauri/src/features/file-explorer/lib/tree-dom-event.test.tsx`
- `windows/tauri/src/features/file-explorer/services/create-java-entry.ts`
- `windows/tauri/src/features/file-explorer/services/create-java-entry.test.ts`
- `windows/tauri/src/features/file-explorer/stores/new-entry.store.ts`
- `windows/tauri/src/features/file-explorer/stores/new-entry.store.test.ts`
- `windows/tauri/src/features/file-explorer/components/new-entry-dialog-host.tsx`
- `windows/tauri/src/features/file-explorer/hooks/use-file-explorer-context-menu.tsx`
- `windows/tauri/src/features/window/components/window-menu-bar.tsx`
- `windows/tauri/src/features/window/components/title-bar/title-bar.tsx`
