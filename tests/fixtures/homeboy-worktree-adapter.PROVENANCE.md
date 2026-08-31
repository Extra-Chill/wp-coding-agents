# Homeboy Worktree Adapter Integration Provenance

The integration test downloads these upstream artifacts into a user cache and
verifies their pinned SHA-256 digests before loading or extracting them:

- WP-CLI `2.12.0` PHAR:
  `https://github.com/wp-cli/wp-cli/releases/download/v2.12.0/wp-cli-2.12.0.phar`
  (`ce34ddd838f7351d6759068d09793f26755463b4a4610a5a5c0a97b68220d85c`)
- Data Machine Code `0.74.1` commit
  `f9509db9168cdc1274237ce2e32f1179647bb756` archive:
  `https://codeload.github.com/Extra-Chill/data-machine-code/tar.gz/f9509db9168cdc1274237ce2e32f1179647bb756`
  (`45107900643a74e6a76b51b28cd7332aea68756ddb2eaac5f9360e0f9823b62b`)
- Homeboy `0.367.3` official release archive selected for the host platform:
  - `aarch64-apple-darwin`: `634731246fb92bc6846e2576552dc2c903f990b2252e161cf77645020e1e59e8`
  - `x86_64-unknown-linux-gnu`: `cd373e81613de9140e5ada23189cca408ddd06a8160fb7cc4031cf536b9ea6e4`
  - `aarch64-unknown-linux-gnu`: `c0726076f8ab6620e50e761a534240ee49e49b0046732474ed20ba974e1cf764`

The local `homeboy-worktree-adapter-dispatch.php` is a small MIT-owned test
harness. It loads the real WP-CLI dispatcher from the verified PHAR and the
production DMC `WorkspaceCommand` class and its synopsis dependencies from the
verified commit. The test claims compatibility with those dispatch and
command-class surfaces. It does not claim a full WordPress, Data Machine, or
Data Machine Code plugin bootstrap.

On supported CI and development platforms, the harness also executes the
checksum-verified official Homeboy binary and requires its exact
`homeboy 0.367.3+3fa0c185d41b` version result before using that result in the
repository-path capability fixture. Other platforms retain deterministic
metadata-format coverage without claiming official-binary execution.

The WP-CLI project does not publish a known immutable official byte URL for the
PHAR. Its release-asset availability is therefore mutable residual risk. The
test does not vendor the binary and fails closed unless downloaded and cached
bytes match the digest above; a changed or unavailable release asset cannot be
loaded by the harness.
