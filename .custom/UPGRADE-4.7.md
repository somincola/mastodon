# Somincola Garden：4.6.7 → 4.7.0 → 4.7.1

## 范围与依据

生产目录为 `ssh mastodon` 上的 `/opt/mastodon`，使用 Docker Compose 和 Caddy。2026-09-06 已完成备份、构建、隔离演练、生产 4.7.0 前后迁移，并以 4.7.1 恢复服务。公网实例 API 已确认版本为 4.7.1、字数上限为 5000。

官方说明：

- https://github.com/mastodon/mastodon/releases/tag/v4.7.0
- https://github.com/mastodon/mastodon/releases/tag/v4.7.1

4.7.0 的标准在线流程是：前迁移 → 重启全部 Mastodon 进程 → 后迁移。4.7.1 从 4.7.0 更新时，Docker 部署只要求切换镜像并重启全部 Mastodon 进程。

本文采用**停写维护窗口**：停止 web、streaming、Sidekiq 后，用 4.7.0 临时容器分别执行前、后迁移，再统一以 4.7.1 启动。两个迁移阶段之间维持应用停止，因此没有旧进程继续访问新结构，也不对外开放中间版本。数据库、Redis、Elasticsearch 和 Caddy 保持运行。

## 正式执行结果

| 阶段 | UTC 时间（2026-09-06） | 结果 |
| --- | --- | --- |
| 开始维护 / 全部应用停止 | 04:47:59 / 04:48:07 | Web、Sidekiq、Streaming 停止写入 |
| 最终备份本机校验完成 | 05:13:57 | 数据库、Redis、配置等 SHA-256 全部一致 |
| 4.7.0 前迁移 | 05:14:15–05:14:41 | 退出码 0 |
| 4.7.0 后迁移 | 05:14:41–05:14:56 | 退出码 0 |
| 两版本只读检查完成 | 05:15:55 | 数据、私钥、定制设置全部通过 |
| 启动 4.7.1 / 全部应用健康 | 05:16:24 / 05:16:57 | 三个应用使用固定 digest，重启次数均为 0 |

从开始维护到全部应用健康约 29 分钟，北京时间为 12:47:59–13:16:57。主要等待项是最终数据库备份的异地传输；分段复制后对完整文件重新校验，未跳过备份就迁移。

- 冻结时与迁移后均为 63,340 个账户、1,551,685 条帖子。迁移记录从 588 增至 615，4.7.1 无待执行迁移。
- 37 组本地账户私钥全部迁入加密存储，均可解密且与公钥匹配，原字段已清空。
- 5000 字限制保留；热门帖子阈值 3、分数半衰期 3 小时、标签阈值 3、链接阈值 5 保留。生产验证使用数据库只读事务，未发布测试帖子或修改设置。
- 服务器本地与公网实例 API 验证通过；本地与公网 Streaming 健康端点返回 HTTP 200。Web、Sidekiq、Streaming、PostgreSQL、Redis、Elasticsearch 均 healthy，启动日志未发现检查范围内的异常。
- Sidekiq 有 1 个工作进程，验收时 scheduler/default/mailers/push/pull/ingress 队列待处理数均为 0。定时与重试任务仍按自身计划处理。
- 服务器原健康检查、每日备份和镜像清理 crontab 已原样恢复。旧 GitHub 升级工作流保持 `disabled_manually`；本分支已记录实际生产版本 `v4.7.1`，尚未合并 main。
- 修复了原健康检查脚本的 HTTP 403 误报：本机 Web 请求补上站点 Host 和 HTTPS 转发头，使用 `/health`；Streaming 使用 `/api/v1/streaming/health`，两者要求 HTTP 200 并设置请求超时。升级前的日志也存在同一误报。原脚本私有备份为 `/opt/mastodon/upgrade-20260906/mastodon-healthcheck.before-4.7.1.sh`，通知开关保持关闭。

最终停写备份：`/opt/mastodon/upgrade-20260906/final-4.6.7-20260906T044809Z`。

本机最终副本：`/Users/nagihsu/Backups/mastodon/final-4.6.7-20260906T044809Z`。数据库 dump 为 579,795,842 字节；数据库、Redis、环境配置、Compose、全局角色与冻结基线均通过双端校验。早期完整应用备份和 4.6.7 回滚镜像继续保留。

生产日志与阶段退出码保存在 `/opt/mastodon/upgrade-20260906/production-*.log`、`production-*.exit`。本机 `output/upgrade-20260906/production-result.json` 保存脱敏验收结果；敏感配置和数据库只保存在私有备份目录。

## 已核实的兼容性与自动化限制

- 真正的补丁目录是 `.custom/patches/`。`001-character-limit.patch` 和 `002-configurable-trends.patch` 均可直接应用到官方 v4.7.0、v4.7.1；差异检查、Ruby 语法、YAML 和定制字段验证通过。
- 字数限制是 5000；第二个补丁提供热门帖子、话题标签、链接阈值和帖子分数半衰期管理，保留上游审核逻辑。
- 原 main 工作流自动检测仅限 v4.6.x。显式版本输入可选择 v4.7.x，但原部署命令会在切换旧进程前直接运行所有迁移，不适合照搬到本次升级。
- 原 `skip_deploy=true` 仍会发布 `latest`、修改 `.current-version` 和创建发布记录。本次构建使用 `codex/mastodon-4.7-upgrade` 分支，修复以上构建副作用；分支已推送，未合并 main。
- 分支将手动构建默认设为跳过部署，并限制部署只能在 main 上执行。自动检测跟随 `.current-version` 的次版本系列，拒绝自动降级；生产版本记录仅在部署成功后更新。
- 正式升级后，旧 GitHub 工作流已暂停。启用自动部署前需合并并继续适配：main 仍是原工作流，且本文安装的 digest 固定配置必须由将来的自动流程显式更新。仅重新启用旧工作流无法正确更新当前生产镜像。

## 备份与演练

两组构建均成功，`deploy` 和 `post-build` 都是 skipped，构建日志确认只发布版本标签，没有发布 `latest`：

| 版本 | 构建记录 | Web 镜像 | Streaming 镜像 |
| --- | --- | --- | --- |
| 4.7.0 | [34004838654](https://github.com/somincola/mastodon/actions/runs/34004838654) | `bailongctui/mastodon:4.7.0-custom` | `bailongctui/mastodon-streaming:4.7.0-custom` |
| 4.7.1 | [34004840266](https://github.com/somincola/mastodon/actions/runs/34004840266) | `bailongctui/mastodon:4.7.1-custom` | `bailongctui/mastodon-streaming:4.7.1-custom` |

四个镜像均为 `linux/amd64`，已拉取到服务器。digest 保存在服务器 `/opt/mastodon/upgrade-20260906/image-receipts.json`；该目录下 `compose.4.7.0.yml`、`compose.4.7.1.yml` 已验证只改变三个应用服务的镜像。生产已将 4.7.1 文件安装为 `/opt/mastodon/docker-compose.override.yml`，普通 `docker compose` 命令会继续使用此次核对的固定镜像。

服务器备份：`/opt/mastodon/backups/pre-4.7.0-20260906T014514Z`

本机副本：`/Users/nagihsu/Backups/mastodon/pre-4.7.0-20260906T014514Z`

目录权限为 700，文件仅所有者可读写。包含：真实业务库 `mastodon_production` 的 custom-format dump、PostgreSQL 全局角色、Redis RDB、生产环境配置及三个 Active Record Encryption 密钥、Compose、Caddy 配置与证书、crontab、软件包清单、旧容器信息和 4.6.7 回滚镜像。服务器与本机的 SHA-256 校验均通过。

完整 `pg_restore --exit-on-error` 已在独立 PostgreSQL 14 容器成功执行，恢复结果：63,303 个账户（37 个本地账户）、1,550,122 条帖子、588 项迁移。隔离网络无发布端口，应用演练没有连接生产数据库、Redis、R2 或邮件服务。

随后按 4.7.0 前迁移 → 4.7.0 后迁移 → 4.7.1 启动完成演练：迁移记录增至 615，无待执行项，账户和帖子数量不变。两个版本均通过 5000/5001 字边界、中文字符、内容警告计数、趋势表单保存与动态更新、优先级/默认值/边界检查，37 组加密私钥均可解密且与公钥匹配。原趋势设置（帖子阈值 3、半衰期 3 小时、标签阈值 3、链接阈值 5）验证后已还原。4.7.1 隔离 web API 返回版本 4.7.1 和 5000 字，streaming 健康端点返回 HTTP 200。

Redis 备份通过 `redis-check-rdb` 校验；归档中的生产环境文件与实际文件逐字节一致，三个加密密钥均存在。验证脚本在隔离库中使用真实事务提交，以覆盖 Setting 的 `after_commit` 缓存行为；没有修改补丁代码。

这是应用恢复备份，并非云厂商整机快照。媒体存放在现有 Cloudflare R2 bucket，未复制远程对象；Elasticsearch 可重建索引未做在线目录拷贝。初次备份时应用继续运行，DB 与 Redis 是分别取快照；生产迁移前已额外完成上文列出的停写最终备份及本机副本校验。

## 生产操作：逐步执行

以下为本次执行的命令参考，生产已完成升级，不应重复执行整套维护流程。服务器命令在 `ssh mastodon` 会话内执行。所有阶段共用：

```bash
set -euo pipefail
umask 077
cd /opt/mastodon
STAGE=/opt/mastodon/upgrade-20260906
dc470() { docker compose -p mastodon --project-directory /opt/mastodon -f /opt/mastodon/docker-compose.yml -f "$STAGE/compose.4.7.0.yml" "$@"; }
dc471() { docker compose -p mastodon --project-directory /opt/mastodon -f /opt/mastodon/docker-compose.yml -f "$STAGE/compose.4.7.1.yml" "$@"; }
```

### 1. 先验证已准备好的镜像和空间

```bash
test -f "$STAGE/compose.4.7.0.yml"
test -f "$STAGE/compose.4.7.1.yml"
dc470 config --images
dc471 config --images
dc470 pull web sidekiq streaming
dc471 pull web sidekiq streaming
df -h /opt/mastodon
docker compose ps
```

两个 override 文件只改 web、Sidekiq、streaming 的镜像，使用构建后核对的 digest；它们不默认生效，生产配置在本阶段保持原样。

### 2. 暂停会干扰维护的任务并停止所有应用写入

服务器每五分钟运行的 `mastodon-healthcheck.sh` 会主动重启停止的容器；周日 03:30 UTC 的 `docker system prune` 也会删除停止的容器。必须先暂停它们。

```bash
crontab -l > "$STAGE/crontab.before-maintenance"
sed -E '\@/usr/local/bin/mastodon-(healthcheck|backup)\.sh@s@^@# mastodon-upgrade-20260906: @; \@docker system prune@s@^@# mastodon-upgrade-20260906: @' \
  "$STAGE/crontab.before-maintenance" > "$STAGE/crontab.maintenance"
crontab "$STAGE/crontab.maintenance"

# 检查先前已启动的健康检查/备份已结束，再执行下面的 stop。
pgrep -af '^/bin/bash /usr/local/bin/mastodon-(healthcheck|backup)\.sh$' || true

docker compose stop -t 120 web streaming sidekiq
docker inspect mastodon-web-1 mastodon-streaming-1 mastodon-sidekiq-1 \
  --format '{{.Name}} running={{.State.Running}}'
```

三个应用容器都必须是 `running=false`。若 `pgrep` 仍有输出，先等现有脚本退出；不要让健康检查在 stop 后重新启动应用。仅停 web 不足以停止 Sidekiq、定时发布和联邦队列的写入。

### 3. 停写后再做最终恢复点

```bash
FINAL_BACKUP="$STAGE/final-4.6.7-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 "$FINAL_BACKUP"
docker exec mastodon-db-1 pg_dump -Fc -U mastodon -d mastodon_production \
  > "$FINAL_BACKUP/mastodon_production.dump.partial"
test -s "$FINAL_BACKUP/mastodon_production.dump.partial"
mv "$FINAL_BACKUP/mastodon_production.dump.partial" "$FINAL_BACKUP/mastodon_production.dump"
docker exec -i mastodon-db-1 pg_restore --list \
  < "$FINAL_BACKUP/mastodon_production.dump" > "$FINAL_BACKUP/dump-toc.txt"
grep -q 'TABLE DATA public statuses' "$FINAL_BACKUP/dump-toc.txt"
docker exec mastodon-redis-1 redis-cli --rdb /tmp/final-pre-4.7.rdb
docker cp mastodon-redis-1:/tmp/final-pre-4.7.rdb "$FINAL_BACKUP/redis.rdb"
cp .env.production docker-compose.yml "$FINAL_BACKUP/"
if [ -f docker-compose.override.yml ]; then cp docker-compose.override.yml "$FINAL_BACKUP/"; fi
cp "$STAGE/crontab.before-maintenance" "$FINAL_BACKUP/"
(cd "$FINAL_BACKUP" && sha256sum mastodon_production.dump redis.rdb .env.production docker-compose.yml > SHA256SUMS && sha256sum -c SHA256SUMS)
printf '%s\n' "$FINAL_BACKUP" > "$STAGE/final-backup-path.txt"
```

迁移前，在本机另开终端复制这个最终恢复点并验证 SHA-256：

```bash
set -euo pipefail
umask 077
MASTODON_FINAL_REMOTE=$(ssh mastodon 'cat /opt/mastodon/upgrade-20260906/final-backup-path.txt')
MASTODON_FINAL_LOCAL="/Users/nagihsu/Backups/mastodon/${MASTODON_FINAL_REMOTE##*/}"
mkdir -m 700 "$MASTODON_FINAL_LOCAL"
rsync -a -e 'ssh -o BatchMode=yes' "mastodon:$MASTODON_FINAL_REMOTE/" "$MASTODON_FINAL_LOCAL/"
(cd "$MASTODON_FINAL_LOCAL" && shasum -a 256 -c SHA256SUMS)
```

验证成功后返回原 SSH 会话。不要使用旧的 `backup-before-4.6.0-custom.dump`：该文件只有约 1 KB，不能代表实际业务库。

### 4. 执行 4.7.0 前迁移

```bash
dc470 run --rm --no-deps -e SKIP_POST_DEPLOYMENT_MIGRATIONS=true \
  web bundle exec rails db:migrate 2>&1 | tee "$STAGE/production-4.7.0-pre.log"
```

必须等待退出码为 0。遇到错误停止在当前阶段，不继续切换镜像或恢复旧进程。本次实际使用服务器上的独立 `nohup` 作业执行，日志和退出码写入文件，SSH 断开不影响迁移。直接手动运行上述命令时应使用 tmux 保留会话。

### 5. 保持全部应用停止，执行 4.7.0 后迁移

```bash
dc470 run --rm --no-deps web env -u SKIP_POST_DEPLOYMENT_MIGRATIONS \
  bundle exec rails db:migrate 2>&1 | tee "$STAGE/production-4.7.0-post.log"
dc470 run --rm --no-deps web env -u SKIP_POST_DEPLOYMENT_MIGRATIONS \
  bundle exec rails db:migrate:status
```

确认没有 `down`。不要把 `SKIP_POST_DEPLOYMENT_MIGRATIONS` 设成字符串 `false`：该版本只检查环境变量是否存在，必须移除它。后迁移会迁移并加密本地账户私钥，因此环境配置中的三个 Active Record Encryption 密钥必须保留。

### 6. 切换到 4.7.1，再统一启动全部应用

```bash
dc471 run --rm --no-deps web env -u SKIP_POST_DEPLOYMENT_MIGRATIONS \
  bundle exec rails db:migrate:status

# 让后续普通 docker compose 命令也使用已核对的 4.7.1 固定镜像。
if [ -f docker-compose.override.yml ]; then
  cp docker-compose.override.yml "$STAGE/compose.override.before-4.7.1.yml"
fi
install -m 644 "$STAGE/compose.4.7.1.yml" docker-compose.override.yml
docker compose up -d --no-deps --wait --wait-timeout 180 web streaming sidekiq
docker compose ps
curl -fsS -H 'Host: m.somincola.org' -H 'X-Forwarded-Proto: https' \
  http://127.0.0.1:3000/api/v2/instance | python3 -c \
  'import json,sys; x=json.load(sys.stdin); print(x["version"],x["configuration"]["statuses"]["max_characters"]); assert x["version"]=="4.7.1"; assert x["configuration"]["statuses"]["max_characters"]==5000'
```

4.7.0 → 4.7.1 没有新增迁移步骤；这里查询迁移状态用于核验。`docker compose restart` 不会替换镜像，必须使用 `up -d` 重建有变化的服务。

### 7. 验收并恢复健康检查

确认 web、Sidekiq、streaming 均 healthy；查看近期日志、后台趋势设置、流式连接及队列消费。正式重新开放写入后，旧数据库恢复点将不包含新写入。

```bash
docker compose logs --since 10m --tail 100 web sidekiq streaming
crontab -l > "$STAGE/crontab.before-resume"
sed 's/^# mastodon-upgrade-20260906: //' "$STAGE/crontab.before-resume" > "$STAGE/crontab.resumed"
crontab "$STAGE/crontab.resumed"
```

不要在本次升级后清理旧镜像或删除备份。由于后迁移改变账户密钥存储，回滚不能只换回 4.6.7 镜像；必须停写并恢复匹配的数据库、Redis、环境配置和旧镜像。本文不自动执行数据库删除或恢复操作。
