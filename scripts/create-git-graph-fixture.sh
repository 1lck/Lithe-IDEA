#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
DESTINATION="${1:-/tmp/lithe-spring-boot-git-graph}"
SOURCE_DIR="$ROOT_DIR/shared/fixtures/projects/lithe-spring-boot-git-graph"

rm -rf "$DESTINATION"
mkdir -p "$DESTINATION"
cp -R "$SOURCE_DIR/pom.xml" "$SOURCE_DIR/README.md" "$SOURCE_DIR/src" "$DESTINATION/"

cd "$DESTINATION"
git init -q
git config user.name "Lithe QA"
git config user.email "lithe-qa@example.com"
git branch -M main

git add .
git commit -q -m "chore: bootstrap Spring Boot user service"
BASE_COMMIT="$(git rev-parse HEAD)"

git switch -q -c feature/users
cp "$SOURCE_DIR/history/UserService-feature.java" src/main/java/com/example/demo/user/UserService.java
git add src/main/java/com/example/demo/user/UserService.java
git commit -q -m "feat: add user listing service"
git commit --allow-empty -q -m "test: cover user service validation"

git switch -q main
git commit --allow-empty -q -m "build: add service observability defaults"
git merge --no-ff -q feature/users -m "merge: user service into main"
git tag -a -m "Spring Boot fixture release" v0.1.0

git switch -q -c feature/orders "$BASE_COMMIT"
mkdir -p src/main/java/com/example/demo/order
cp "$SOURCE_DIR/history/OrderController-feature.java" src/main/java/com/example/demo/order/OrderController.java
git add src/main/java/com/example/demo/order/OrderController.java
git commit -q -m "feat: add order health endpoint"

git switch -q main
git commit --allow-empty -q -m "docs: describe tenant-aware API"
git switch -q feature/orders
git rebase -q main

git update-ref refs/remotes/origin/main main
git update-ref refs/remotes/origin/feature/users feature/users
git switch -q main

echo "$DESTINATION"
