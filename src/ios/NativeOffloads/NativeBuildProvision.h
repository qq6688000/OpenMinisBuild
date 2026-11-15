/* [T-native-build] On-device toolchain provisioning.
 *
 * Why unpack at runtime instead of shipping Toolchain/ in the bundle:
 *   - a framework directory inside the .app made TrollStore's recursive
 *     `ldid -s` fail (install error 175) — observed on device;
 *   - the app bundle is read-only, and clang needs to write temp files.
 *
 * So the archives ride along as flat resources and are expanded into a
 * writable workspace once. Everything here is idempotent and verifies what it
 * produced: a "deployed" answer that was not checked is worse than none.
 */
#import <Foundation/Foundation.h>

/* Extract <bundle>/ToolchainResources/<name> (tar+gzip) into <dest>/<strip>.
 * `strip` is the leading path component inside the archive to discard.
 * Returns a dictionary: ok, entries, bytes, error. */
NSDictionary *NBExtractArchive(NSString *archivePath, NSString *destDir,
                               NSString *stripFirstComponent);

/* Same bundled archives, extraction checks and cache layout as native provision.
 * Blocking: call on a worker queue. ok includes BOTH archive results and paths;
 * ready describes files only. exec_probe is a clang --version launch, not a build. */
NSDictionary *NBProvisionBundledToolchain(void);
