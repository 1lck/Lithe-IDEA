# 文件关联修复的截图证据

代码提交：9e7ce0642df634b1074d571fed6970d2631c2a55。

场景：通用设置的文件关联表格，全选、窗口激活自动回读保留选择、悬停显示默认应用替换说明。macOS arm64，无头窗口 1120×820 点，中英文与明暗四种组合。使用真实系统只读观察，开发二进制显示“需安装包”，没有执行默认应用写入。

命令：`./scripts/desktop/desktop-go.sh test -json -race -tags 'vivahead lithevisual' -p=1 -parallel=1 ./internal/fileassociations ./internal/core ./internal/settingswindow -run '^Test(FileAssociations|VisualFileAssociations$)' -count=1 -timeout=60s`

25 条父子结果均通过，未检测到竞态；逐项计时检查返回失败，原因是 TestVisualFileAssociations 总计 16.34 秒超过本地 15 秒预算。单场景为 3.57–4.85 秒。签名发布包批量写入、系统授权与 Windows 原生验收尚未完成。
