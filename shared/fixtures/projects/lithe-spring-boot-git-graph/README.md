# Lithe Spring Boot Git Graph Fixture

这是 Git Graph 的单一验收项目，不参与 Lithe 本身的构建。

项目模拟一个常见的 Spring Boot 用户服务，配套脚本会生成：

- `main` 主线
- `feature/users` 分支及真实 Merge Commit
- `feature/orders` 的 Rebase 历史
- Tag `v0.1.0`
- `origin/main` 远程引用

生成：

```bash
./scripts/create-git-graph-fixture.sh
```
