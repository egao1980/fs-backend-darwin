(in-package #:fs-backend-darwin)

;;; R4c-1: APFS clones, the :CLONEFILE mechanism of cl-stack-pathlib's clone
;;; protocol (R4c-0, cl-stack-pathlib 0.10.0).
;;;
;;; pathlib walks the tree and calls CLONEFILE-FILE for each regular file:
;;; clonefile(2) with CLONE_NOFOLLOW | CLONE_NOOWNERCOPY. With no ignore
;;; matcher, the tree hook CLONEFILE-TREE clones each top-level entry of the
;;; source in one call (clonefile of a directory clones its whole subtree),
;;; after an lstat-only walk has shown the result equals the per-file walk.
;;; CLONEFILE-AVAILABLE-P answers for a pair of directories: macOS, a local
;;; filesystem, a source volume with VOL_CAP_INT_CLONE (getattrlist), and
;;; one device for both (stat st_dev). Anything else falls back to :COPY.
;;;
;;; clonefile, getattrlist, stat and lstat are in libSystem, which every
;;; image already has open: nothing is loaded. Off macOS each binding is a
;;; Lisp stand-in that signals CLONEFILE-ERROR, so the system loads
;;; everywhere with no undefined-alien warning.
;;;
;;; Given: the constants, CLONEFILE-ERROR, *CLONEFILE-TRACE*, the foreign
;;; declarations and their off-macOS stand-ins. The functions below the
;;; "implementation" line are the implementation's; they call
;;; %R4C1-PENDING, which the implementation removes with every call.

(defun %r4c1-pending (what &key quiet)
  "Signal that WHAT is not implemented yet; with QUIET, return NIL instead.
The stub probe is QUIET: a probe that signals would break every area
FS-OPEN-AREA opens (:mechanism :auto asks every registered probe), and with
it the R4a / R4b tests."
  (unless quiet
    (error "R4c-1 not implemented yet: ~A" what)))

;;; --- constants ------------------------------------------------------------------

(defconstant +clonefile-rank+ 100
  "The rank :CLONEFILE registers with (above :COPY, which is always last).")

;; <sys/clonefile.h>
(defconstant +clone-nofollow+ #x0001
  "CLONE_NOFOLLOW: a symlink SRC is cloned as the link, never followed.")
(defconstant +clone-noownercopy+ #x0002
  "CLONE_NOOWNERCOPY: the clone belongs to the caller, not to SRC's owner.")
(defconstant +clonefile-flags+ (logior +clone-nofollow+ +clone-noownercopy+)
  "The flags of every clonefile(2) call.")

;; <sys/attr.h>
(defconstant +attr-bit-map-count+ 5 "ATTR_BIT_MAP_COUNT, struct attrlist bitmapcount.")
(defconstant +attr-vol-info+ #x80000000 "ATTR_VOL_INFO (required with any volume attribute).")
(defconstant +attr-vol-capabilities+ #x00020000 "ATTR_VOL_CAPABILITIES: a vol_capabilities_attr_t.")
(defconstant +vol-capabilities-interfaces+ 1
  "VOL_CAPABILITIES_INTERFACES, the index of the interfaces word in
vol_capabilities_attr_t's CAPABILITIES and VALID arrays.")
(defconstant +vol-cap-int-clone+ #x00010000
  "VOL_CAP_INT_CLONE: the volume supports clonefile(2). Counts only when set
in both the CAPABILITIES and the VALID interfaces words.")

;; <sys/errno.h> (Darwin numbers)
(defconstant +eacces+ 13)
(defconstant +exdev+ 18)
(defconstant +enotsup+ 45)

;;; --- condition and trace ------------------------------------------------------

(define-condition clonefile-error (sp:clone-error)
  ()
  (:default-initargs :mechanism :clonefile)
  (:documentation "clonefile(2), getattrlist(2) or stat(2) failed for a
reason a plain copy may still get past (EACCES, EPERM, ENOSPC, EDQUOT, EIO,
ENAMETOOLONG, ...), or the call was made off macOS. CLONE-ERROR-OPERATION is
\"clonefile\", \"getattrlist\" or \"stat\"; CLONE-ERROR-CODE the errno (NIL
off macOS); PATH-ERROR-PATH the source (or the directory asked about).
Inside FS-CLONE-TREE / FS-CLONE-FILE pathlib offers the restart USE-COPY."))

(defvar *clonefile-trace* nil
  "NIL, or a function designator called as (FUNCALL *CLONEFILE-TRACE* source
destination) with the two native namestrings before every clonefile(2)
call, by CLONEFILE-FILE and by the tree hook alike. A test hook: it shows
whether the hook cloned whole subtrees or pathlib went per file.")

;;; --- foreign declarations (libSystem, macOS) ------------------------------------
;;;
;;; struct stat with 64-bit inodes: the plain symbols on arm64, the
;;; $INODE64 variants on x86_64. Only the leading fields are named; the
;;; layout (dev_t st_dev @0, mode_t st_mode @4, nlink_t st_nlink @6) is the
;;; same on both, sizeof 144.

#+darwin
(progn
  (cffi:defcstruct (attrlist :size 24)
    (bitmapcount :uint16 :offset 0)
    (reserved :uint16 :offset 2)
    (commonattr :uint32 :offset 4)
    (volattr :uint32 :offset 8)
    (dirattr :uint32 :offset 12)
    (fileattr :uint32 :offset 16)
    (forkattr :uint32 :offset 20))

  (cffi:defcstruct (vol-capabilities-buffer :size 36)
    ;; The attribute buffer for ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES: the
    ;; u_int32_t length, then vol_capabilities_attr_t.
    (length :uint32 :offset 0)
    (capabilities :uint32 :count 4 :offset 4)
    (valid :uint32 :count 4 :offset 20))

  (cffi:defcstruct (darwin-stat :size 144)
    (st-dev :int32 :offset 0)
    (st-mode :uint16 :offset 4)
    (st-nlink :uint16 :offset 6))

  (cffi:defcfun ("clonefile" %clonefile) :int
    (source :string) (destination :string) (flags :uint32))

  (cffi:defcfun ("getattrlist" %getattrlist) :int
    (path :string) (attrlist :pointer) (buffer :pointer) (size :size) (options :uint32))

  (cffi:defcfun (#+x86-64 "stat$INODE64" #-x86-64 "stat" %stat) :int
    (path :string) (buffer :pointer))

  (cffi:defcfun (#+x86-64 "lstat$INODE64" #-x86-64 "lstat" %lstat) :int
    (path :string) (buffer :pointer))

  (cffi:defcfun ("__error" %errno-location) :pointer)

  (defun %errno ()
    "errno of the calling thread, read right after a failed call."
    (cffi:mem-ref (%errno-location) :int)))

#-darwin
(progn
  (defun %macos-only (operation path)
    (error 'clonefile-error :path path :operation operation
                            :message (format nil "~A(2) is macOS only" operation)))
  (defun %clonefile (source destination flags)
    (declare (ignore destination flags))
    (%macos-only "clonefile" source))
  (defun %getattrlist (path attrlist buffer size options)
    (declare (ignore attrlist buffer size options))
    (%macos-only "getattrlist" path))
  (defun %stat (path buffer)
    (declare (ignore buffer))
    (%macos-only "stat" path))
  (defun %lstat (path buffer)
    (declare (ignore buffer))
    (%macos-only "stat" path))
  (defun %errno () nil))

;;; --- implementation -----------------------------------------------------------

(defun volume-supports-clone-p (directory)
  "True when the volume holding DIRECTORY (a pathname or native namestring;
symlinks followed) supports clonefile(2): getattrlist(ATTR_VOL_INFO |
ATTR_VOL_CAPABILITIES) has +VOL-CAP-INT-CLONE+ set in both the CAPABILITIES
and VALID words at +VOL-CAPABILITIES-INTERFACES+. APFS answers T; HFS+,
exFAT, FAT, SMB and NFS answer NIL. getattrlist(2) documents EINVAL for a
path that is not the volume's root, but macOS 26 answers for any path; on
EINVAL the implementation may ask the volume's mount point (statfs
f_mntonname) instead. Signals CLONEFILE-ERROR (operation \"getattrlist\")
for a missing DIRECTORY and off macOS."
  (declare (ignore directory))
  (%r4c1-pending 'volume-supports-clone-p))

(defun volume-device (directory)
  "st_dev of DIRECTORY (a pathname or native namestring; symlinks followed),
an integer: equal for two paths on one volume. Two APFS volumes of one
container are two devices. Signals CLONEFILE-ERROR (operation \"stat\") for
a missing DIRECTORY and off macOS."
  (declare (ignore directory))
  (%r4c1-pending 'volume-device))

(defun clonefile-available-p (fs source-dir destination-dir)
  "The AVAILABLE-P probe of :CLONEFILE → (values available-p reason), in
this order: off macOS (NIL :UNAVAILABLE); FS not a LOCAL-FILESYSTEM (NIL
:UNSUPPORTED-FILESYSTEM); the volume of SOURCE-DIR lacks VOL_CAP_INT_CLONE
(NIL :UNSUPPORTED-VOLUME); SOURCE-DIR and DESTINATION-DIR on different
devices (NIL :CROSS-VOLUME); otherwise T. Both are existing directories
(pathlib passes the destination's nearest existing ancestor). Never
signals, and caches nothing."
  (declare (ignore fs source-dir destination-dir))
  ;; Stub: unavailable everywhere until implemented, so :AUTO copies.
  (%r4c1-pending 'clonefile-available-p :quiet t)
  (values nil :unavailable))

(defun clonefile-file (fs source destination)
  "The per-file CLONE-FILE of :CLONEFILE: clonefile(SOURCE, DESTINATION,
CLONE_NOFOLLOW | CLONE_NOOWNERCOPY) on the native namestrings (UTF-8),
calling *CLONEFILE-TRACE* first. → T when DESTINATION was made; (values NIL
:UNSUPPORTED-VOLUME) on ENOTSUP; (values NIL :CROSS-VOLUME) on EXDEV; any
other errno signals CLONEFILE-ERROR (operation \"clonefile\", code errno,
path SOURCE, filesystem FS). clonefile(2) makes DESTINATION whole or not at
all, so a failure leaves nothing behind."
  (declare (ignore fs source destination))
  (%r4c1-pending 'clonefile-file))

(defun clonefile-tree (fs source destination matcher)
  "The CLONE-TREE hook of :CLONEFILE. With a MATCHER: NIL (declined;
clonefile of a directory cannot skip ignored paths). With MATCHER NIL: an
lstat-only walk of SOURCE declines (NIL) on anything the R4c-0 walk would
treat differently (an entry that is not a regular file, directory or
symlink; a regular file with more than one link; a setuid, setgid or sticky
bit). Otherwise each top-level entry of SOURCE is clonefile'd into the
empty directory DESTINATION (one call per entry, through *CLONEFILE-TRACE*),
and the result is the number of regular files the walk counted. A failing
call removes what the hook made (DESTINATION is empty again) and then
returns or signals as CLONEFILE-FILE does: ENOTSUP / EXDEV → NIL (declined),
anything else → CLONEFILE-ERROR."
  (declare (ignore fs source destination matcher))
  (%r4c1-pending 'clonefile-tree))
