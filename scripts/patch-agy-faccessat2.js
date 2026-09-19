#!/usr/bin/env node
// Rewrite agy's faccessat2 syscall to faccessat so it survives Android seccomp.
//
// Android's seccomp policy traps faccessat2 (arm64 syscall 439) with SIGSYS
// rather than returning ENOSYS, and this kernel (4.14) predates the syscall
// anyway -- faccessat2 only arrived in Linux 5.8. Go's
// internal/syscall/unix.Eaccess calls it unconditionally, with no fallback, so
// agy dies with "SIGSYS: bad system call" the first time it resolves `bash`:
// that is any task that runs a tool, which is why plain prompts work and
// file-creating ones do not.
//
// faccessat (syscall 48) performs the same access check. It has no flags
// argument on arm64, so the AT_EACCESS flag is dropped -- for a non-setuid
// process the real and effective uids are the same, so the decision is
// unchanged. Verified on-device: syscall(48, AT_FDCWD, path, X_OK, 0x200)
// returns 0, syscall(439, ...) is killed by SIGSYS.
//
// Each call site is `movz x0, #439` (0xd28036e0). Only 4-byte-aligned matches
// are rewritten: the same byte sequence also occurs once as unaligned data in
// the payload, and patching that would corrupt the binary.
//
// Usage: node patch-agy-faccessat2.js <path-to-agy-binary>
// Prints the number of patched sites. Exits non-zero only on I/O failure.

const fs = require("fs");

const path = process.argv[2];
if (!path) {
  console.error("usage: patch-agy-faccessat2.js <agy-binary>");
  process.exit(2);
}

const OLD = [0xe0, 0x36, 0x80, 0xd2]; // movz x0, #439  (SYS_faccessat2)
const NEW = [0x00, 0x06, 0x80, 0xd2]; // movz x0, #48   (SYS_faccessat)

const buf = fs.readFileSync(path);
let patched = 0;

for (let i = 0; i + 4 <= buf.length; i += 4) {
  if (OLD.every((b, k) => buf[i + k] === b)) {
    NEW.forEach((b, k) => {
      buf[i + k] = b;
    });
    patched++;
  }
}

if (patched > 0) {
  fs.writeFileSync(path, buf);
}

console.log(patched);
