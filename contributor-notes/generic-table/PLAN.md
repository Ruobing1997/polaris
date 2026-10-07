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

# Polaris Generic Table：两份 PR 的路线图

> 截至 2026-10-06 的工作计划，不代表社区已认可设计，也不代表代码已通过测试。
> 实验、代码状态和构建阻塞见 [DEVLOG.md](DEVLOG.md)。Part 1 源码草稿已作为
> [WIP commit `1198b143a8`](https://github.com/Ruobing1997/polaris/commit/1198b143a8626082c45b9f5480fd8b71d3547db0)
> 推送到个人 fork 的 `generic-table-location-validation` 分支；**尚未通过测试，也未开 PR**。
> 本 notes 分支不包含这些源码改动。

## 一分钟理解问题

Polaris 是 catalog／授权控制面。Generic Table 记录 `name`、`format`（如 `delta`）、可选的
`base-location` 等元数据，不负责创建 Delta 数据文件。即便如此，Polaris 也不能随意接受指向
catalog 允许存储范围以外的路径。当前本地 Generic Table create 会保存显式传入的位置，却没有像
其他 table-like entity 那样执行已有的位置限制校验。

把三个规则分开，才不会误解我们的 PR 范围：

1. **名称唯一**：同一 namespace 内不能有同名 table-like entity；现有代码已检查。
2. **位置是否被允许**：显式位置须符合 catalog `allowedLocations`，通常还须在父 namespace
   之下；这是 **Part 1**。
3. **位置是否与别的实体重叠**：两个不同名称不能在禁止重叠时共享同一路径或父子路径；这是
   **Part 2**，不会因为完成 Part 1 而自动解决。

快速阅读入口：[Generic Table 文档](../../site/content/in-dev/unreleased/generic-table.md)、
[API schema](../../spec/polaris-catalog-apis/generic-tables-api.yaml)、
[本地 create 实现](../../runtime/service/src/main/java/org/apache/polaris/service/catalog/generic/PolarisGenericTableCatalog.java)。
API 合约中的 `base-location` 是可选字段，不能为了校验而悄悄改变这个语义。

## PR 1：创建时校验显式 base-location

建议标题：`Validate Generic Table base locations on create`。

仅修改**本地（非 federated）Generic Table create**。在原有同名检查之后、构建／保存实体之前，
对非 `null`、非空字符串的 `base-location` 调用当前 main 已有的
[`CatalogUtils.validateLocationsForTableLike`](../../runtime/service/src/main/java/org/apache/polaris/service/catalog/common/CatalogUtils.java)，
传入已解析的父 namespace，使工具能从实体层级得到适用的存储及 namespace 限制。不改公开 API、
配置项或持久化格式；不加入 overlap 检查。

| 输入或配置 | Part 1 应有结果 |
|---|---|
| 不提供 `base-location`，或传空字符串 | 保持现有创建／读取行为；Polaris 不自动填位置。 |
| 位置在 allowed 范围及 namespace 内 | 创建成功。 |
| 位置在 catalog `allowedLocations` 外 | 拒绝；之后 GET 不应查到新记录。 |
| S3-only catalog 收到 `file://` 位置 | 拒绝且不保存。 |
| allowed 范围内、namespace 外，unstructured flag 关闭 | 拒绝。 |
| allowed 范围内、namespace 外，unstructured flag 开启 | 接受；allowed 限制仍然生效。 |
| 已存在的名称，加上一个无效新位置 | 仍优先返回同名冲突。 |
| 不同名称、相同的合法位置 | Part 1 可能仍接受；留给 Part 2。 |

测试分两层：[共享 Generic Catalog 测试](../../runtime/service/src/test/java/org/apache/polaris/service/catalog/generic/AbstractPolarisGenericTableCatalogTest.java)
覆盖 relational 与 NoSQL 的合法／越界／无位置／同名行为；另用 `TestServices` 经 API 比较
`ALLOW_UNSTRUCTURED_TABLE_LOCATION` 开／关，请求包含必填 `name` 与 `format`。同步更新
[Generic Table 文档](../../site/content/in-dev/unreleased/generic-table.md)和
[CHANGELOG.md](../../CHANGELOG.md)，明确“旧版本可能接受、现在拒绝”的兼容性影响。

设计参考是未合入的 [#4237](https://github.com/apache/polaris/pull/4237) 与
[#5024](https://github.com/apache/polaris/pull/5024)，**不是 cherry-pick**。#5024 的校验调用
在查同名之前；本计划把它放在查同名之后，保留原来的冲突优先级。PR 描述写明 “Part 1 of 2”、
复现、实际测试结果、引用 #4237，并明确不包含 overlap。拆成两份 PR 是我们的提议，尚需社区反馈。

## PR 2：防止 Generic Table 位置重叠

等待 PR 1 合入，再从更新的 `main` 开工。建议标题：
`Prevent overlapping Generic Table locations`。覆盖 Generic/Generic、Generic/Iceberg 及
namespace 的同路径、父子路径和“字符串前缀相似但并非 URI 父子”的边界，遵守现有 overlap 配置。

设计前先验证一个静态风险：Generic Table 的 `base-location` 位于 entity 的 internal
properties，而 JDBC／NoSQL 的优化位置索引可能只读取普通 properties；详见
[调查记录](DEVLOG.md)。这还不是经过测试证实的 bug。先建立两个后端的回归测试，再决定能否复用
optimized sibling check，或必须调整索引／fallback。PR 描述链接 Part 1、#4237、#5024；
不要直接搬入旧 PR 的大范围重构。

## 再往后：credential vending

历史 [#4128](https://github.com/apache/polaris/pull/4128) 只是设计参考。发放限定路径和动作的凭据
之前，需要先明确位置安全、无 `base-location` 时请求 delegation 的语义，以及“实体已保存、随后
发凭据失败”的处理方式。这不属于前两份 PR。

## 开 PR 1 前必须完成

1. 在**代码分支**上运行定向测试，确认测试能识别旧行为，修改后在相关持久化后端通过。
2. 按仓库 [AGENTS.md](../../AGENTS.md) 跑 `./gradlew format compileAll` 和
   `./gradlew :polaris-runtime-service:check`；逐文件审阅 diff，运行 `git diff --check`。
3. 用包含 Part 1 的构建重做 [devlog 中的两条 `gt_lab` 请求](DEVLOG.md)，同时记录 POST 与
   后续 GET。旧 `apache/polaris:latest` 镜像的结果只是 baseline，不验证新源码。
4. WIP 代码分支已在个人 fork；检查通过后，更新该分支并确认 PR 只含 Part 1，再写可独立
   理解的 PR 描述。只报告**实际运行**的检查；绝不把未运行写成通过。

截至本快照，Gradle 在 settings 插件解析阶段、Java 编译之前失败，原因未确定。因此定向测试、
format／compile 与 module check 均为**未验证**。向社区发送 Slack 消息前，必须先展示草稿并取得
贡献者明确确认。

## 个人电脑验证脚本

本学习分支保存了 [`verify-part1.sh`](verify-part1.sh)，它接收**另一份**
`generic-table-location-validation` 分支 checkout 的路径，因此不会把个人验证脚本混进 Part 1 PR。
若个人电脑上尚无这两份 checkout，先分别从个人 fork 拉取代码和学习分支；只在个人电脑、
确认代码 checkout 干净后运行：

```bash
git clone --branch generic-table-location-validation https://github.com/Ruobing1997/polaris.git polaris-part1
git clone --branch ruobing_polaris_dev_and_learn --single-branch --depth 1 https://github.com/Ruobing1997/polaris.git polaris-notes
cd polaris-notes
POLARIS_PERSONAL_MACHINE=1 bash contributor-notes/generic-table/verify-part1.sh build ../polaris-part1
```

`build` 模式先检查 JDK 21 和 Docker，再使用独立的 `~/.gradle-polaris-oss` 缓存运行三类定向测试、
`format compileAll`、`:polaris-runtime-service:check` 和 `git diff HEAD --check`。`format` 可能改动
代码；脚本不会提交或推送这些改动，会打印状态和保留在临时目录中的日志。

`api` 模式须先按仓库 README 从 **Part 1 checkout** 启动 `./gradlew run`，并在本机 9000 端口
运行 quickstart RustFS；不要把 `apache/polaris:latest` 当成待测服务：

```bash
cd ../polaris-part1
docker compose -p polaris-gt-verify -f site/content/guides/quickstart/docker-compose.yml up -d rustfs bucket-setup
AWS_REGION=us-west-2 AWS_ACCESS_KEY_ID=polaris_root AWS_SECRET_ACCESS_KEY=polaris_pass \
  ./gradlew run -Dpolaris.bootstrap.credentials=POLARIS,root,s3cr3t
```

源码版 Polaris 启动后，从另一个终端、在 `polaris-notes` checkout 运行：

```bash
POLARIS_PERSONAL_MACHINE=1 POLARIS_SOURCE_SERVER=1 \
  bash contributor-notes/generic-table/verify-part1.sh api ../polaris-part1
```

它只接受 localhost URL，使用 quickstart 演示凭据，在本地服务中新建独立 catalog／namespace，
验证成功位置、allowed locations 外、namespace 外、`file://`、缺省／空位置和重名行为，并保留
实验记录与响应文件。两个模式都**尚未在公司电脑上运行**；脚本通过语法检查不等于测试通过。
