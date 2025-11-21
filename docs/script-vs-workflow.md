# 脚本 vs Workflow：它们的关系和区别

## 简单总结

- **脚本 (`scripts/release-flow.sh`)**：管理 Git 操作（同步、合并、打 tag、推送）
- **Workflow (`.github/workflows/build-image.yml`)**：监听 Git 事件，自动构建 Docker 镜像

**它们不会冲突，是互补关系**：脚本触发 workflow，workflow 执行构建。

---

## 详细对比

### 脚本：`scripts/release-flow.sh`

**作用**：本地 Git 操作工具

**做什么**：
1. ✅ 同步 `upstream/main` 到你的 `main`
2. ✅ 合并 `main` 到 `custom-ui-fix` 分支
3. ✅ 创建 `stable-<version>` 分支
4. ✅ 打 tag（如 `v4.5.2`）
5. ✅ 推送到 GitHub（push 分支和 tag）

**不做什么**：
- ❌ 不构建 Docker 镜像
- ❌ 不推送镜像到 Docker Hub

**何时使用**：
- 🎯 **发布新版本时**（推荐）
- 🎯 需要创建稳定分支和版本 tag 时
- 🎯 需要同步上游更新时

**触发方式**：手动运行 `./scripts/release-flow.sh 4.5.2`

---

### Workflow：`.github/workflows/build-image.yml`

**作用**：GitHub Actions 自动化构建

**做什么**：
1. ✅ 监听 Git 事件（push 到分支或 tag）
2. ✅ 构建 Docker 镜像（web 和 streaming）
3. ✅ 推送到 Docker Hub（`bailongctui/mastodon:*`）

**不做什么**：
- ❌ 不管理 Git 分支
- ❌ 不打 tag
- ❌ 不同步上游代码

**何时触发**：
- 🎯 **自动触发**：当你 push 到 `custom-ui-fix` 分支时
- 🎯 **自动触发**：当你 push tag（如 `v4.5.2`）时
- 🎯 **手动触发**：在 GitHub Actions 页面点击 "Run workflow"

**触发方式**：
- 自动：脚本推送 tag 后自动触发
- 手动：GitHub Actions UI 中手动运行

---

## 工作流程示例

### 场景 1：发布新版本（推荐使用脚本）

```bash
# 1. 运行脚本
./scripts/release-flow.sh 4.5.2

# 脚本会自动：
# - 同步 upstream → main
# - 合并 main → custom-ui-fix
# - 创建 stable-4.5.2 分支
# - 打 tag v4.5.2
# - 推送所有内容到 GitHub

# 2. GitHub Actions 自动检测到 tag，开始构建
# - 构建 bailongctui/mastodon:v4.5.2
# - 构建 bailongctui/mastodon-streaming:v4.5.2
# - 如果 tag 是 v4.5.*，还会打 latest 标签
```

### 场景 2：开发时自动构建（不需要脚本）

```bash
# 1. 在 custom-ui-fix 分支上开发
git checkout custom-ui-fix
# ... 修改代码 ...

# 2. 提交并推送
git add .
git commit -m "Update UI"
git push origin custom-ui-fix

# 3. GitHub Actions 自动检测到 push，开始构建
# - 构建 bailongctui/mastodon:latest
# - 构建 bailongctui/mastodon-streaming:latest
```

### 场景 3：手动触发构建（不需要脚本）

1. 打开 GitHub Actions 页面
2. 选择 "Build and Push Custom Mastodon" workflow
3. 点击 "Run workflow"
4. 选择分支（如 `custom-ui-fix`）
5. 点击 "Run workflow" 按钮

---

## 常见问题

### Q: 我应该用脚本还是直接 push？

**A**: 
- **发布版本**：用脚本（确保版本管理规范）
- **日常开发**：直接 push 到 `custom-ui-fix`（workflow 会自动构建）

### Q: 两者会冲突吗？

**A**: 不会。脚本负责 Git 操作，workflow 负责构建。脚本推送 tag → workflow 检测到 tag → 自动构建。

### Q: 如果我只 push 分支，不运行脚本会怎样？

**A**: 
- Workflow 会触发，构建 `latest` 标签
- 但不会有版本号 tag（如 `v4.5.2`）
- 不会有 `stable-<version>` 分支
- 适合开发测试，不适合正式发布

### Q: 如果我只运行脚本，不 push 会怎样？

**A**: 
- 脚本会失败（需要 push 才能触发 workflow）
- 必须 push tag 才能触发构建

### Q: 可以跳过脚本，手动打 tag 吗？

**A**: 可以，但不推荐：
```bash
git tag v4.5.2
git push origin v4.5.2
# Workflow 会自动触发构建
```
**问题**：
- 不会同步 upstream
- 不会创建 stable 分支
- 不会合并最新代码
- 容易出错

---

## 推荐工作流

### 日常开发
```bash
# 1. 在 custom-ui-fix 分支开发
git checkout custom-ui-fix
# ... 修改代码 ...

# 2. 提交并推送（自动触发 latest 构建）
git push origin custom-ui-fix
```

### 发布版本
```bash
# 1. 运行脚本（自动同步、合并、打 tag、推送）
./scripts/release-flow.sh 4.5.2

# 2. 等待 GitHub Actions 完成构建

# 3. 在服务器上拉取新镜像
docker pull bailongctui/mastodon:v4.5.2
# 或
docker pull bailongctui/mastodon:latest
```

---

## 总结

| 功能 | 脚本 | Workflow |
|------|------|----------|
| Git 操作 | ✅ | ❌ |
| 同步 upstream | ✅ | ❌ |
| 创建分支 | ✅ | ❌ |
| 打 tag | ✅ | ❌ |
| 构建镜像 | ❌ | ✅ |
| 推送镜像 | ❌ | ✅ |
| 自动化 | 手动运行 | 自动触发 |

**最佳实践**：
- 🎯 日常开发：直接 push → workflow 自动构建
- 🎯 版本发布：使用脚本 → 规范管理 → workflow 自动构建

