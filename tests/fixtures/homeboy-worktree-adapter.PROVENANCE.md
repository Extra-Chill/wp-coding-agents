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

The local `homeboy-worktree-adapter-dispatch.php` is a small MIT-owned test
harness. It loads the real WP-CLI dispatcher from the verified PHAR and the
production DMC `WorkspaceCommand` class and its synopsis dependencies from the
verified commit. The test claims compatibility with those dispatch and
command-class surfaces. It does not claim a full WordPress, Data Machine, or
Data Machine Code plugin bootstrap.

The WP-CLI project does not publish a known immutable official byte URL for the
PHAR. Its release-asset availability is therefore mutable residual risk. The
test does not vendor the binary and fails closed unless downloaded and cached
bytes match the digest above; a changed or unavailable release asset cannot be
loaded by the harness.
