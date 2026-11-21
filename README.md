# fs-backend-darwin

MIT. macOS **FSEvents** change journals for [cl-stack-pathlib](https://github.com/egao1980/cl-stack-pathlib)'s
`fs-watch` (R4b-2 of the cl-stack harness plan) and **APFS clones** for its clone protocol (R4c-1). Brief:
[cl-stack/docs/capabilities/fs-backend-darwin.md](https://github.com/egao1980/cl-stack/blob/main/docs/capabilities/fs-backend-darwin.md).

Loading the system registers the journal mechanism `:fsevents` (rank 100, above the portable `:poll`).
It is available on macOS for the local filesystem, so `fs-watch` and `fs-open-area … :journal :auto`
pick it there with no code change; elsewhere it is registered but unavailable.

```lisp
(asdf:load-system "fs-backend-darwin")
(let ((j (cl-stack-pathlib:fs-watch (cl-stack-pathlib:make-local-filesystem) #p"/Users/me/project/")))
  ;; … edits …
  (cl-stack-pathlib:journal-drain j)   ; → ("src/a.lisp" "docs") T
  (cl-stack-pathlib:journal-close j))
```

CoreServices and CoreFoundation are opened through CFFI when the system loads (system frameworks,
no native overlay). Each journal owns one FSEvents stream on the run loop of its own Lisp thread;
a drain flushes the stream (`FSEventStreamFlushSync`). Dropped or coalesced events
(MustScanSubDirs, UserDropped, KernelDropped, RootChanged, …) make the drain incomplete, so the
caller rescans.

Tests: `cl-repo test` (Rove). They include `cl-stack-pathlib/journal-suite` with `:fsevents` and
skip with a note off macOS.

## APFS clones (`:clonefile`, 0.2.0)

Loading the system also registers the clone mechanism `:clonefile` (rank 100, above `:copy`) for
cl-stack-pathlib 0.10.0's `fs-clone-tree` / `fs-clone-file`. It is available on macOS for the local
filesystem when the source volume has `VOL_CAP_INT_CLONE` (APFS) and both directories are on one
device, so `clone-tree … :mechanism :auto` and `open-area` clone there and copy elsewhere
(`:unsupported-volume` on HFS+, exFAT, SMB, …; `:cross-volume` between volumes).

Each regular file is `clonefile(2)`d with `CLONE_NOFOLLOW | CLONE_NOOWNERCOPY`; with no ignore
matcher a tree hook clones each top-level entry in one call. The clone tests make their own APFS and
HFS+ disk images with `hdiutil` (no root) and run `cl-stack-pathlib/clone-suite` there.
