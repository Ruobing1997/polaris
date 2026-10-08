<!--
  Licensed to the Apache Software Foundation (ASF) under one
  or more contributor license agreements.  See the NOTICE file
  distributed with this work for additional information
  regarding copyright ownership.  The ASF licenses this file
  to you under the Apache License, Version 2.0 (the
  "License"); you may not use this file except in compliance
  with the License.  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing,
  software distributed under the License is distributed on an
  "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
  KIND, either express or implied.  See the License for the
  specific language governing permissions and limitations
  under the License.
-->

# 问题总结

以 Apache Polaris Generic Table 作为首次较完整的开源 feature work：当前本地 Generic Table
create 可以保存越过 catalog allowed locations 或父 namespace 的显式 `base-location`。目标分
两份 PR：**Part 1 校验位置是否被允许，Part 2 校验位置是否与其他实体重叠**。credential vending
再往后讨论。[PLAN.md](PLAN.md) 写目标行为和验收门槛；本文记录已经观察到什么、改了什么、
哪些事情**尚未验证**。下方 2026-10-06 的 WIP／构建阻塞是历史记录；最新状态见
[2026-10-08 的正式分支与验收](#2026-10-08thursday正式分支与最终验收)。

# work directory

在 Apache Polaris checkout 中区分当前分支与历史分支：

- 个人 fork 的 `ruobing_polaris_dev_and_learn`：只有这份学习／续接文档和计划。
- 个人 fork 的 [`generic-table-location-validation-part1`](https://github.com/Ruobing1997/polaris/tree/generic-table-location-validation-part1)：
  当前正式 Part 1 代码，commit [`6af9614d61`](https://github.com/Ruobing1997/polaris/commit/6af9614d6138ebc3b4b0547a863fc36f91d09e26)，
  基于验收 main `768fd7f95b`；已通过本地验收，尚未开 Part 1 PR。另一台电脑应拉取此分支。
- 个人 fork 的 [`generic-table-location-validation`](https://github.com/Ruobing1997/polaris/tree/generic-table-location-validation)：
  Part 1 源码 WIP 分支，建立于当时的 `upstream/main` commit `243ec7c94d`，后以
  [commit `1198b143a8`](https://github.com/Ruobing1997/polaris/commit/1198b143a8626082c45b9f5480fd8b71d3547db0)
  推送。这是历史 WIP 分支，不再用作最终候选；当时尚未完成编译和测试。仅拉取 notes 分支
  不会得到任何功能源码。

再次开始工作时，先检查 `git status`、远端引用和最新 upstream，不要假设本文快照仍是现状。

## 2026-10-06（Tuesday）：背景与依据

日期和星期已用 `date`、`cal` 按 America/Los_Angeles 时区核对。

### Generic Table 到底是什么

Polaris 管理 catalog／namespace／table 身份、元数据与权限，不是查询引擎或对象存储。
Generic Table entry 记录必填 `name`、`format`（例如 `delta`）和可选 `base-location`、
properties、doc；创建 entry 不会创建 Delta 的数据文件或 `_delta_log`。不传位置时，响应里的
`base-location` 仍可为 `null`，不会自动继承 namespace 位置。阅读入口：
[Generic Table 文档](../../site/content/in-dev/unreleased/generic-table.md)、
[API schema](../../spec/polaris-catalog-apis/generic-tables-api.yaml)、
[`GenericTableEntity`](../../polaris-core/src/main/java/org/apache/polaris/core/entity/table/GenericTableEntity.java)。

本地 create 链是 [REST adapter](../../runtime/service/src/main/java/org/apache/polaris/service/catalog/generic/GenericTableCatalogAdapter.java)
→ [handler](../../runtime/service/src/main/java/org/apache/polaris/service/catalog/generic/GenericTableCatalogHandler.java)
→ [local catalog](../../runtime/service/src/main/java/org/apache/polaris/service/catalog/generic/PolarisGenericTableCatalog.java)
→ entity／persistence。local catalog 已检查 table-like **名称**是否冲突，然后构建、保存
Generic Table entity；在 Part 1 之前，没有校验显式路径。现有
[`CatalogUtils.validateLocationsForTableLike`](../../runtime/service/src/main/java/org/apache/polaris/service/catalog/common/CatalogUtils.java)
从 resolved entity path 找存储限制；
[`LocationRestrictions`](../../polaris-core/src/main/java/org/apache/polaris/core/storage/LocationRestrictions.java)
检查 allowed locations，以及需要结构化位置时的父路径。**名字唯一、位置被允许、位置不重叠**
是三个不同不变量。

### 旧 PR 为什么只能作参考

在 2026-10-01 的调查中，[#4237](https://github.com/apache/polaris/pull/4237)、
[#5024](https://github.com/apache/polaris/pull/5024)、
[#4128](https://github.com/apache/polaris/pull/4128) 均为 closed、未 merged；未来引用状态前应重查。

- #4237 同时尝试 Generic create 位置校验与 Generic/Iceberg overlap，并提取共享 overlap
  工具；其[历史 create 代码](https://github.com/apache/polaris/blob/62404e71a3e89e383aa52c0ac1bb76bdb4181deb/runtime/service/src/main/java/org/apache/polaris/service/catalog/generic/PolarisGenericTableCatalog.java#L104-L139)
  在查同名之前调用当时的 `validateLocationForTableLike`。
- #5024 也将两类检查放在一起；其[历史 create 代码](https://github.com/apache/polaris/blob/5279534e4f7207715c118c27e6e1526f8593f1f1/runtime/service/src/main/java/org/apache/polaris/service/catalog/generic/PolarisGenericTableCatalog.java#L107-L112)
  调用当前风格的 `validateLocationsForTableLike` 后检查 overlap，同样发生在查同名之前。
  Part 1 借鉴校验调用，但移到同名检查之后，且**没有** overlap 代码。
- #4128 探索 Generic Table credential vending。缺少或未经验证的位置如何发 scoped 凭据，
  以及失败时 API 语义，都需要另行设计，故延后。

这些不是被 cherry-pick 的补丁。先前由贡献者转述的社区交流建议先做 location validation、
再做 credential vending，并在新 PR 引用旧 PR；“overlap 单独作为 Part 2”仍是我们的提议，
**尚无已记录的社区认可**。

### `gt_lab` 实验：现有行为与应有行为

此前对话中，贡献者提供了 Postman 实测：在 `gt_lab` 中不指定 `base-location` 创建，响应为
`null`；显式位置 `s3://bucket123/gt_lab/delta_with_location` 创建成功；另一个名字指定同一路径
也返回 HTTP 200；再次使用已存在的表名则返回 409。**同路径不同名**是 Part 2 的复现，
不能说 Part 1 会修复它。

2026-10-06，我们读取仍在运行的 `polaris-gt-lab` 容器与 API 配置，并经正确的 Generic Table
路由 `/api/catalog/polaris/v1/quickstart_catalog/namespaces/gt_lab/generic-tables` 补测。
Management GET 显示 INTERNAL/S3 catalog，`allowedLocations=["s3://bucket123"]`，
`default-base-location=s3://bucket123`，响应中没有 catalog 级 unstructured-location override；
namespace GET 显示 `location=s3://bucket123/gt_lab/`。运行镜像是 `apache/polaris:latest`，本地
image ID 为 `sha256:347615e736cab2c9be0d8c464552ac930be4755302bb0aeb745216bbae99ba5b`；
镜像 label 未标出 Polaris 源码 revision，因此这些结果**不是本地源码修改的验证**。

| POST body 中的关键字段（`format=delta`） | POST | 随后 GET | Part 1 预期 |
|---|---|---|---|
| `name=delta_outside_allowed_p1_20261006`；`base-location=s3://other-bucket/gt_lab/delta_outside_allowed_p1_20261006` | 200；request ID 尾号 `0040` | 200；`0041`，回显同一路径 | 拒绝：不在 catalog allowed 范围。 |
| `name=delta_outside_namespace_p1_20261006`；`base-location=s3://bucket123/elsewhere/delta_outside_namespace_p1_20261006` | 200；`0042` | 200；`0043`，回显同一路径 | 结构化位置规则下拒绝：在 allowed bucket 内，但在 namespace 外。 |

两次请求都包含必填 `name`、`format`；GET 200 证明两条记录确实被保存。记录仍留在独立的
`gt_lab` namespace 中供对照；这些 Generic Table API 请求没有创建实际表文件。未经明确清理
决定，不删除它们。最初误用 Iceberg `/v1` 路由的四个请求只得到路由层 404，没有业务证据也
没有创建记录；上表来自改用文档指定的 `/polaris/v1` 后的请求。

### Part 1 源码改动：已推送 WIP，尚未验证

WIP [commit `1198b143a8`](https://github.com/Ruobing1997/polaris/commit/1198b143a8626082c45b9f5480fd8b71d3547db0)
包含：

1. [Local create](https://github.com/Ruobing1997/polaris/blob/generic-table-location-validation/runtime/service/src/main/java/org/apache/polaris/service/catalog/generic/PolarisGenericTableCatalog.java)：
   完成同名检查后、构建／持久化 entity 前，对非 `null`、非空位置调用
   `CatalogUtils.validateLocationsForTableLike(callContext.getRealmConfig(), identifier,
   Set.of(baseLocation), resolvedParent)`。没有加入 overlap。
2. [共享 Generic 测试](https://github.com/Ruobing1997/polaris/blob/generic-table-location-validation/runtime/service/src/test/java/org/apache/polaris/service/catalog/generic/AbstractPolarisGenericTableCatalogTest.java)：
   保留 null／空字符串和同名行为；增加合法 S3、越界 bucket、`file://`，并检查拒绝后无法 load。
3. 新建 [GenericTableAllowedLocationTest](https://github.com/Ruobing1997/polaris/blob/generic-table-location-validation/runtime/service/src/test/java/org/apache/polaris/service/catalog/generic/GenericTableAllowedLocationTest.java)：
   用 `TestServices` 测 `ALLOW_UNSTRUCTURED_TABLE_LOCATION` 开／关；每个 create request 都有
   必填的 `name` 和 `format`。
4. [Generic Table 文档](https://github.com/Ruobing1997/polaris/blob/generic-table-location-validation/site/content/in-dev/unreleased/generic-table.md)与
   [Unreleased changelog](https://github.com/Ruobing1997/polaris/blob/generic-table-location-validation/CHANGELOG.md)：
   说明显式位置限制及旧请求可能被拒绝的变化。

这是 WIP 而非“代码已正确”的结论；恢复工作时应在**代码分支**重新检查 commit、`git status`
和相对最新 upstream 的 diff。本 notes 分支不包含这些源码改动。

### 构建与验证状态

源码分支的 `git diff --check` 曾通过。用仅对单条命令有效的 JDK 21 尝试定向测试时，
Gradle 9.7.1 在 `settings.gradle.kts:123` 解析 `com.gradle.develocity:4.6.0` 就停止：

```text
[Fatal Error] com.gradle.develocity.gradle.plugin-4.6.0.pom:1:10:
DOCTYPE is disallowed when the feature
"http://apache.org/xml/features/disallow-doctype-decl" set to true.
```

这发生在 Java 编译之前。公开 plugin marker POM 能读到有效 XML，但 Gradle 实际解析到哪份
异常响应尚未定位；**不能断言是 JDK 或功能代码的根因**。没有修改持久 JDK、代理、仓库或项目构建
配置；Gradle 可能更新了 cache／daemon。定向测试、`./gradlew format compileAll` 和
`./gradlew :polaris-runtime-service:check` 全部仍是**未验证**，不是通过。开 ready-for-review
PR 前必须完成仓库 [AGENTS.md](../../AGENTS.md) 的硬门槛。

### Part 2 需要验证的静态风险

静态阅读提示：Generic Table 的 `base-location` 位于 internal properties，而 JDBC／NoSQL 的
某些 optimized overlap 索引从普通 properties 派生位置。若优化检查看不到 Generic 位置，
开启该模式时就可能漏报冲突。**这只是代码推导，尚无复现测试**；先为两种持久化后端建立测试，
再决定如何处理索引或 fallback。阅读
[`GenericTableEntity`](../../polaris-core/src/main/java/org/apache/polaris/core/entity/table/GenericTableEntity.java)、
[`ModelEntity`](../../persistence/relational-jdbc/src/main/java/org/apache/polaris/persistence/relational/jdbc/models/ModelEntity.java)和
[`LocalIcebergCatalog`](../../runtime/service/src/main/java/org/apache/polaris/service/catalog/iceberg/LocalIcebergCatalog.java)。

## 2026-10-06 快照：当时下次接手的顺序

1. 检查 notes 与代码两个分支的 Git 状态；另一台电脑上需从 fork **单独拉取代码分支**。
   确认个人 Git 身份、`origin` 为个人 fork、`upstream` 为 Apache Polaris，并核对最新 main。
2. 在代码分支逐文件审阅 Part 1 diff；排查 Gradle 插件／网络／缓存问题时，不未经告知改持久
   机器配置。能构建后运行定向测试、`./gradlew format compileAll`、module `check`。
3. 用包含 Part 1 的构建重做上表两条 API 请求，分别记录 POST 和 GET；旧 Docker 镜像的 200
   只说明旧行为，不证明修复。
4. WIP 代码分支已推送；验证完成后，修正并更新该分支，再准备引用 #4237 的 Part 1 PR，
   明确 overlap 不在范围内，也不声称社区已同意拆分。Slack 消息先展示草稿并获得明确确认，
   方可发送。

## 2026-10-06（Tuesday）后续：个人电脑验证脚本

- 在学习分支新增 [`verify-part1.sh`](verify-part1.sh)，供个人电脑上的 Part 1 checkout 使用。`build` 模式按计划运行三个定向测试类、`format compileAll`、runtime-service `check` 与 diff whitespace 检查；`api` 模式要求先由源码启动本地 Polaris，再建立独立测试 catalog 并验证正反例。脚本不会提交、推送或删除实验 catalog；API 模式会留下本地实验记录。
- 脚本要求显式设置 `POLARIS_PERSONAL_MACHINE=1`；API 模式另要求 `POLARIS_SOURCE_SERVER=1`，避免误在公司电脑构建或把旧 quickstart Docker 镜像当成新源码。当前只做了 `bash -n` 静态语法检查，**没有运行任何 Gradle 命令、服务或 API 测试**；功能结果仍为未验证。

## 2026-10-08（Thursday）：正式分支与最终验收

日期与星期已用 `date`、`cal` 核对。贡献者在本次讨论中要求：验收后新建干净分支，使用正式
commit 而非 WIP，并将本次 Polaris 工作同步至个人 fork。新分支不改写历史 WIP，也不与学习
笔记混在一起。后面的结果是最新验收快照，取代上面“尚未验证”的历史状态。

### 正式代码

- 分支：[`generic-table-location-validation-part1`](https://github.com/Ruobing1997/polaris/tree/generic-table-location-validation-part1)。
- Commit：[`6af9614d6138ebc3b4b0547a863fc36f91d09e26`](https://github.com/Ruobing1997/polaris/commit/6af9614d6138ebc3b4b0547a863fc36f91d09e26)，
  标题 `Validate Generic Table base locations on create`。
- 唯一父提交为 main `768fd7f95bb8d066bd93daffe74b6875b41da343`，已含独立构建修复
  [#5737](https://github.com/apache/polaris/pull/5737)。#5737 不是本次功能 diff。
- 恰好 7 文件、244 additions / 5 deletions：create 校验、共享测试、新 namespace 配置测试、
  两个授权夹具、Generic 文档及 CHANGELOG。没有公共 API、配置项、持久化格式或依赖变化。
- 新分支相对基线仅有一个正式提交，没有旧 WIP/runbook 提交，也没有学习笔记或 IDE 输出。
- 暂存前后完整 binary diff 与已验收候选逐字一致，正式提交 tree 为
  `b8fa53795b0a4f273e7066808db081ad87adcbb6`。新 checkout 的完整 status 为空；原 dirty
  checkout 未动。整理与推送阶段没有重新运行测试，因为完整源码及基线保持相同。

### 实际验证结果

| 检查 | 实际结果 |
|---|---|
| Generic 3 类 + event/tracing 2 类定向测试 | 60 tests，0 failures/errors/skips，1m46s |
| 旧 create 负向对照 | 6 个新测试，5 个预期失败，暴露旧实现接受非法位置 |
| `./gradlew format compileAll` | PASS，2m58s，1067 actionable tasks |
| `./gradlew :polaris-runtime-service:check` | PASS，48m10s；含 Checkstyle、Spotless 及测试任务 |
| 源码服务 HTTP | 42 个业务 POST/GET/list 请求符合预期，另有 1 次 OAuth 换 token |
| `./gradlew rat` | PASS，17s |
| diff whitespace 与范围 | PASS，仅 7 个预期文件 |

完整模块检查：test 141 suites / 22,793 cases / 55 skipped；intTest 25 suites / 2,594 cases /
78 skipped；cloudTest 9 suites / 909 cases / 全部 skipped。合计 26,296 cases，0 failures/errors；
**25,254 个未跳过用例通过，1,042 个条件跳过不算已验证**。没有为验收新增 skip 或放宽断言。
完整仓库 `./gradlew check` 未运行；本次仅修改 runtime-service，因此按仓库 AGENTS.md 执行
模块 check，并另做整体 compileAll 和 RAT。

现有 intTest 包括 JDBC/PostgreSQL、Cockroach、NoSQL 和模拟存储回归；Generic 三个专项类
仍使用其既有内存 fixtures，不把通用 JDBC 回归写成新增 Generic 场景已逐后端覆盖。实际云
路径未配置，真实云集成仍未验证。

HTTP 对照使用与正式提交相同源码启动的本地服务，不是旧 Docker latest。在两种 catalog 配置
中分别读取 management/namespace 确认有效规则，然后比较：

| 场景 | namespace 约束开启 | unstructured flag 开启 |
|---|---|---|
| 合法位置 | POST/GET 200 | POST/GET 200 |
| allowed locations 外 | POST 403，GET 404 | POST 403，GET 404 |
| allowed 内、namespace 外 | POST 403，GET 404 | POST/GET 200 |
| S3 catalog 下不允许的 file 位置 | POST 403，GET 404 | POST 403，GET 404 |
| 省略/null/空字符串 | 成功，保持原位置语义 | 相同 |
| 同名请求加非法位置 | 409，GET 保留原记录 | 相同 |

两种配置的 LIST 也确认拒绝请求没有留下记录。实验只注册元数据，不创建真实 Delta 数据文件。
本地测试服务及其临时容器已停止/清理；原 quickstart 服务与记录未动。验收没有关闭 XML 安全
保护，没有修改持久 JDK、IDE、代理或系统配置。环境隔离只作用于测试子进程。

### 代码理解与后续

人类作者在开 PR 前应能解释：为何只验证非 null/非空位置、为何传已解析父 namespace、为何
同名检查优先、为何校验在实体构造/保存之前，以及为何授权夹具需要改为合法位置而非放宽权限。

1. 人类审阅正式 commit，按模板创建 Part 1 PR，说明 “Part 1 of 2 / Related to #4237”。
2. 不声称 Part 1 修复不同表名共享位置；overlap 留给 Part 2，待 Part 1 合入后再从更新 main
   设计 Generic/Generic、Generic/Iceberg、双向创建顺序、配置和优化索引测试。
3. Credential vending 再往后，参考 #4128。拆分仍是我们的提议，不写成 PMC 已正式批准。
4. `verify-part1.sh` 已适配新分支与 JDK 21+，但本轮只验证语法和 guard 逻辑，没有执行脚本
   的 build/api 模式；上面的验收来自独立的实际运行，不冒充此脚本已端到端通过。

重新开始时优先拉取正式代码分支，不要继续使用旧 WIP；如源码或 main 基线变化，重新验证。
