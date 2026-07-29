# Lithe-IDEA 页面原型

这是 Lithe-IDEA 的第一版高保真工作台原型，用于验证 IDEA 风格的布局、密度、颜色层级和页面状态，不连接真实项目、Git 或语言服务器。

## 运行

在本目录执行：

```bash
python3 -m http.server 4173
```

然后打开 <http://127.0.0.1:4173>。

## 当前包含

- IDEA 风格顶部项目、分支与运行配置栏
- Welcome Screen 与最近项目列表
- 左侧 Project 文件树
- 左侧 ToolWindow 活动栏
- 中央编辑器、面包屑、标签页、折叠标记和 minimap 示意
- 底部 Run、Debug、Git、Terminal、Problems 工具窗口
- 右侧精简工具栏
- IDEA 风格状态栏
- 内置 SVG 图标系统与高保真视觉覆盖层（`styles-refined.css`）
- 文件切换、文件夹折叠、底部面板收起、Welcome/项目页切换
- 运行与停止按钮的状态反馈

## 当前不包含

- 真实文件读写
- 真实 Git 操作
- 真实项目运行
- LSP 与 Debugger
- AI 或 Codex 集成

这些功能会在页面结构确认后，再接入选定的底层实现。
