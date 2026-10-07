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

# Generic Table location validation: contributor test runbook

This is a temporary, branch-specific runbook for Part 1 of the Generic Table
location work. Run the commands from the Polaris repository root on the machine
where you will build and test. Remove this personal workflow note from the final
Apache Polaris pull request unless the community wants to retain it.

## 1. Confirm checkout and Java

```bash
git status --short --branch
git branch --show-current
git remote -v
java -version
./gradlew --version
```

Expected branch: `generic-table-location-validation`. Confirm that `origin` is
your personal fork, not `apache/polaris`. The build requires Java 21 or newer.
On macOS, if you have JDK 21 installed but it is not active, you can select it
for the current shell only:

```bash
export JAVA_HOME=$(/usr/libexec/java_home -v 21)
export PATH="$JAVA_HOME/bin:$PATH"
java -version
./gradlew --version
```

These exports do not change your persistent Java configuration. Gradle may
write build outputs and its user cache and start a daemon.

## 2. Run focused tests

```bash
./gradlew :polaris-runtime-service:test \
  --tests 'org.apache.polaris.service.catalog.generic.PolarisGenericTableCatalogNoSqlInMemTest' \
  --tests 'org.apache.polaris.service.catalog.generic.PolarisGenericTableCatalogRelationalTest' \
  --tests 'org.apache.polaris.service.catalog.generic.GenericTableAllowedLocationTest'
```

The first two classes run the shared Generic Table tests against NoSQL and
relational persistence. The third exercises the namespace-location rule with
`ALLOW_UNSTRUCTURED_TABLE_LOCATION` both off and on.

Continue only if Gradle reports `BUILD SUCCESSFUL`. If resolution of the
`com.gradle.develocity` plugin fails before tests begin, do not count that as a
test result. Record the error and investigate the build environment separately;
do not disable XML security checks, clear caches, or change repositories as an
unreviewed workaround.

## 3. Run the repository gates

```bash
./gradlew format compileAll
./gradlew :polaris-runtime-service:check
```

Both commands must succeed before this change is ready for review. `format`
may modify source files; inspect any resulting diff. The contribution guide
also recommends `./gradlew check` for a full-repository check when practical.

## 4. Review and push to the personal fork

```bash
git diff --check
git diff --check upstream/main...HEAD
git status --short --branch
git diff --stat
git diff
```

If formatting or test fixes changed files, review and commit only the intended
changes before pushing. Do not stage unrelated files. After all required checks
pass and the working tree is clean:

```bash
git push origin HEAD:generic-table-location-validation
```

`Everything up-to-date` is expected when no new commit was needed. A successful
push only updates the personal fork; it does not open a pull request or prove
that checks passed. Keep the command outputs for the eventual PR description.
