# Pixel 2 ARM64 APK builder

Builds open-source userland APKs for Alpine 3.24 and postmarketOS v26.06 on GitHub Actions. The `ubuntu-24.04-arm` runner has four native ARM64 CPUs. The build verifies upstream Alpine and postmarketOS packages with their public keys. Each container signs its outputs with a one-use key. Downstream machines verify the downloaded files and re-sign them with their own keys before using them in a trusted APK repository.

In **Actions → Build ARM64 APKs → Run workflow**, enter a package or a comma-separated build order, such as `libcamera,plasma-camera`. A later build can resolve dependencies from the packages built earlier in the same run. Leave the image at `alpine:3.24` and the timestamp blank for the defaults. The timestamp defaults to the Git commit time. The successful run provides an `arm64-apks` artifact for 30 days with APKs, SHA-256 digests, a build manifest and the build log.

- `packages/` holds the APKBUILD recipes, patches and supporting source files.
- `keys/` holds the upstream postmarketOS public signing key.
- `scripts/` holds the container build entry point.
- `.github/workflows/` holds the manual build workflow.

## 中文说明

在 GitHub Actions 的四核原生 ARM64 运行器上，为 Alpine 3.24 和 postmarketOS v26.06 构建开源应用软件包。上游软件包使用 Alpine 和 postmarketOS 的公开密钥验签。每个容器用一次性密钥签名。下载方核验文件后，用自己的密钥重签，再纳入可信的软件包仓库。

在 **Actions → Build ARM64 APKs → Run workflow** 中，输入单个包名，或按构建顺序输入 `libcamera,plasma-camera` 这样的逗号分隔列表。后续构建可使用同次运行先完成的软件包。镜像默认使用 `alpine:3.24`，时间戳默认使用 Git 提交时间。构建成功后，`arm64-apks` 保留 30 天，包含软件包、SHA-256 摘要、构建清单和日志。

`packages/` 保存配方、补丁和配套源码，`keys/` 保存 postmarketOS 官方公钥，`scripts/` 保存容器构建入口，`.github/workflows/` 保存手动触发的构建任务。
