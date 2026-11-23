# 使用 latest 自动更新

服务器的 Web、Sidekiq、Streaming 长期使用 `bailongctui/mastodon:latest` 和 `bailongctui/mastodon-streaming:latest`。版本标签同时保留，用于追踪构建和人工恢复。

## 定时流程

GitHub 每周一 02:00 UTC（北京时间 10:00）检查当前生产次版本系列的稳定补丁。当前生产为 4.7.1，因此自动跟进 4.7.x，不选 RC、beta，也不自动跨到 4.8 或 5.0。

1. 验证两个定制补丁；运行发布逻辑测试。
2. 分别构建 Web 和 Streaming 的版本镜像并检查实际产物。
3. 两个镜像都通过后，将它们发布为 latest，并核对仓库中的两个 digest。
4. 服务器拉取 latest，确认是本次发布的镜像、版本没有倒退。
5. 内容发生变化或存在未完成迁移时，先备份数据库、Redis、配置及旧镜像引用，再执行前迁移。
6. 以 latest 重建三个应用服务，等待健康，执行后迁移。
7. 核验版本、5000 字限制、趋势设置可读取、私钥可解密和迁移状态，再记录部署成功。

服务器临时记录每次拉取的 digest，以保证一次升级使用同一组镜像。普通 Compose 配置仍是 latest，之后每次更新都会重新拉取。Compose 2.27 的临时 `pull_policy: never` 文件只用于本次已经完成拉取的部署命令。

## 手动操作

在 GitHub Actions → **Sync, Build & Deploy Custom Mastodon** → **Run workflow**，选择 `main`。

| 用途 | 参数 |
| --- | --- |
| 正常检查、构建并部署 | 保持默认；version 留空 |
| 发布指定稳定补丁并部署 | version 填 `v4.7.x` |
| 构建并更新 latest，暂不部署服务器 | skip_deploy=true；publish_latest=true |
| 历史版本或跨次版本试构建，只生成版本标签 | skip_deploy=true；publish_latest=false |
| 重新发布已经构建好的镜像 | version 填明确版本；reuse_images=true |
| 同版本强制重新构建和部署 | force=true |

`skip_deploy` 只控制服务器，`publish_latest` 控制 Docker Hub 的 latest。这与此次升级准备阶段“跳过部署也不改 latest”的临时规则不同。非 main 分支始终不允许发布 latest 或部署。

没有新版本时不会重新构建或重启。若上次只发布了镜像、尚未部署，下次定时任务会复用已有镜像继续部署。历史版本和未经跨版本升级审查的版本不会覆盖当前生产系列的 latest。

## 版本记录和失败处理

- `.published-version`：已发布为两个 latest 的版本。
- `.published-images.json`：此次发布对应的两份 digest。
- `.current-version`：已通过服务器验收的生产版本；构建成功不会修改它。
- `/opt/mastodon/.deployed-version`：服务器本地的实际部署记录。

整个 GitHub 工作流串行执行，后来的任务不会取消正在执行的迁移。服务器部署、健康检查、每日备份和定时镜像清理共用 `/opt/mastodon/.deployment.lock`，避免互相干扰。

Docker Hub 的两个标签不支持跨仓库原子更新。脚本在普通发布失败时尝试恢复原来的两个 latest；只有两者核验一致才允许部署。服务器也会核对两个预期 digest，遇到标签变化即停止。

服务器作业以独立进程执行，SSH 断开后会继续完成；日志、状态和备份保存在 `/opt/mastodon/automation/<run-id>-<attempt>/`。若 Actions 连接中断，先查看该目录的 `phase`、`exit-code` 和 `output.log`，不能仅凭连接断开判断升级已停止。

数据库迁移失败时不会自动切回旧镜像，也不会自动删除或恢复数据库。保留现场和备份供排查。自动备份是在运行中的数据库上生成的一致性数据库快照，Redis 单独取快照；不是整机快照，也不复制 R2 媒体。备份保存在服务器，现有每日备份和此次 4.7 升级的本机备份继续保留。磁盘不足时部署会停止，不自动删除历史备份。

修改服务器 SSH 主机密钥后，需要核对并更新 `.custom/server-host-key.pub`；它仅保存经过验证的公开主机密钥，不包含登录私钥。

## 非 root SSH 部署

`SERVER_USER` 继续从 Repository secrets 读取。关闭 root SSH 登录后，可使用已获准非交互 sudo 的部署账号；无需重新开放 root 登录。本流程沿用该账号已有的权限，不会创建 sudoers 规则，也不提供最小权限隔离。不要在日志或聊天中输出登录私钥。

传输脚本使用 `sudo -n` 创建 root 私有运行目录，通过 SSH 标准输入上传 root 所有的部署脚本并核对 SHA256，再交给 root systemd 临时服务执行。上传和状态查询会使用 stdin，不能加 `ssh -n`。服务器需要 systemd 249 或兼容其 `Type=exec`、`StandardOutput=append:` 的版本，以及 `/usr/bin/docker`。这仍会完整执行备份、迁移、健康等待和应用验收，不只是运行 `pull` 和 `up -d`。

服务名为 `mastodon-deploy-<run-id>-<attempt>.service`。SSH 断开后，服务由 systemd 继续管理；查看状态和私有日志需要 sudo。若启动结果不明确，先核对服务、`phase`、`exit-code` 和 `output.log`，不要盲目重复部署。已有运行目录不会被覆盖；确认现场后，需要用新的 GitHub run attempt 重试。修改代码后要从新提交发起运行，重跑旧 run 不会采用新补丁。

`Test custom deployment controls` 工作流只运行 Bash 语法检查和离线 unittest，不读取 Secrets、不连接生产服务器、不构建或发布镜像。它包含模拟传输与失败路径测试，但不能替代实际 SSH、sudo 和生产部署验收。不要通过运行完整的发布工作流来测试 SSH；`skip_deploy=true` 也可能继续发布 latest。

## 当前切换

2026-09-06 已完成切换：复用已经完整演练的 4.7.1 镜像发布 latest，并归档此前只包含固定镜像的 `docker-compose.override.yml`。服务器默认 Compose 和三个实际运行容器均使用 latest。两份镜像内容没有变化，本次未重复执行数据库迁移。

- [发布 latest 的验证任务](https://github.com/somincola/mastodon/actions/runs/34017264910)通过。
- [GitHub 实际部署任务](https://github.com/somincola/mastodon/actions/runs/34017458082)完成服务器部署与验收。
- 六个服务均 healthy；三个应用容器的异常重启数为 0。公网 API 返回 4.7.1 / 5000 字，Streaming 健康检查返回 HTTP 200，37 组私钥验证通过。
- 版本记录已同步为 v4.7.1，工作流已启用。维护 crontab 已接入共享部署锁。
- 原固定镜像配置与原 crontab 保存在 `/opt/mastodon/automation/latest-setup-20260906/`。此次 GitHub 部署日志保存在 `/opt/mastodon/automation/34017458082-1/`。

参考：[Docker 镜像标签发布](https://docs.docker.com/reference/cli/docker/buildx/imagetools/create/)、[Compose pull](https://docs.docker.com/reference/cli/docker/compose/pull/)、[GitHub 工作流串行控制](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)。
