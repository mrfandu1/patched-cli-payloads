# agy crashes with `SIGSYS: bad system call`

## Symptom

Plain prompts work. Anything that runs a *tool* — creating a file, editing one,
running a command — dies instantly:

```
$ agy -p 'Create a file at ~/page.html with a complete HTML page' \
      --dangerously-skip-permissions
$ echo $?
2
$
```

Exit code 2, no output, no error message. The file may even be created first: the
crash happens *after* the write succeeds.

To see the real error, run the binary through the glibc loader and capture stderr:

```bash
env -u LD_PRELOAD "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" \
  --library-path "$PREFIX/glibc/lib" ~/.local/bin/agy.bin \
  -p 'Create a file at ~/x.txt' --dangerously-skip-permissions 2>&1 | head
```

which prints `SIGSYS: bad system call` followed by a Go panic trace.

## Cause

The Go panic trace names the exact path:

```
syscall.Syscall6(0x1b7, 0xffffffffffffff9c, ..., 0x1, 0x200, ...)
syscall.faccessat2(...)
syscall.Faccessat(...)
internal/syscall/unix.Eaccess(...)
os/exec.findExecutable(...)
os/exec.lookPath({..., 0x4})
google3/devtools/ai/sandbox/sbox.run(...)
```

Two things combine:

1. **`faccessat2` does not exist on this kernel.** It is arm64 syscall 439,
   added in Linux 5.8. This device runs 4.14.
2. **Android's seccomp policy traps it with `SIGSYS` instead of returning
   `ENOSYS`.** Go only falls back to the older `faccessat` when it sees
   `ENOSYS`, so the fallback never happens — the process is killed instead.

Go's `internal/syscall/unix.Eaccess` calls `faccessat2` unconditionally. agy
reaches it from `sandbox/sbox.run` calling `exec.LookPath("bash")` — so the
crash fires the first time agy tries to resolve a shell to run a tool, which is
why simple prompts are unaffected.

`--sandbox` is not the trigger: the `sbox.run` path is registered regardless of
that flag, so there is no flag that avoids it.

## Fix

`faccessat` (syscall 48) performs the same access check and *does* exist here.
Each call site is a `movz x0, #439` instruction; rewriting the immediate to 48
makes agy call the older syscall.

The flag that gets dropped is `AT_EACCESS`. For a non-setuid process the real
and effective uids are identical, so the access decision is unchanged. Verified
on-device:

```python
syscall(48,  AT_FDCWD, path, X_OK)        -> 0      # works
syscall(48,  AT_FDCWD, path, X_OK, 0x200) -> 0      # extra arg ignored
syscall(48,  AT_FDCWD, missing,  X_OK)    -> -1, ENOENT   # really checking
syscall(439, AT_FDCWD, path, X_OK, 0x200) -> killed by SIGSYS
```

## Where it is applied

- **`install.sh`** — after the payload is decompressed, before the wrappers are
  installed. Inline (standalone mode has no checkout to read a script from).
- **`scripts/upgrade-all.sh`** — after `agy update`, because the update replaces
  the binary and would otherwise restore the crash.

Both run `scripts/patch-agy-faccessat2.js` (the installer carries an identical
inline copy). It patches only 4-byte-aligned matches: the same byte sequence
occurs once as unaligned *data* in the payload, and patching that would corrupt
the binary. A correct run reports 5 sites / 10 bytes.

## If agy updates and the patch stops matching

The patch is written against a specific build, so a new agy may move the call
sites. Both callers detect this and warn:

```
WARNING: agy faccessat2 patch matched nothing
```

It will not silently corrupt anything — it only rewrites an exact 4-byte
instruction pattern, so a build without that pattern is simply left alone (and
keeps crashing). To re-target it:

```bash
# find the call sites in the new binary
node -e '
const fs=require("fs"); const b=fs.readFileSync(process.argv[1]);
for(let i=0;i+4<=b.length;i+=4)
  if(b[i]===0xe0&&b[i+1]===0x36&&b[i+2]===0x80&&b[i+3]===0xd2)
    console.log("0x"+i.toString(16));
' ~/.local/bin/agy.bin
```

A newer agy may also ship a Go version that handles this properly, in which case
the patch is unnecessary — a `matched nothing` warning after an update is
harmless, but check whether the crash is actually gone before assuming it is
fixed.

## Verifying the fix

```bash
rm -f ~/agy-page.html
agy -p "Create a file at $HOME/agy-page.html with a complete HTML page" \
    --output-format text --print-timeout 180s --dangerously-skip-permissions
ls -l ~/agy-page.html
```

Exit 0 and a non-empty file means the patch is in place. Exit 2 with no output
means it is not.
