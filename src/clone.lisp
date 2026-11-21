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
;;; declarations and their off-macOS stand-ins.

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

;; <removefile.h>
(defconstant +removefile-recursive+ #x0001 "REMOVEFILE_RECURSIVE.")

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

  ;; <removefile.h>: removes a file, a symlink (never followed) or, with
  ;; REMOVEFILE_RECURSIVE, a whole tree. The hook's cleanup.
  (cffi:defcfun ("removefile" %removefile) :int
    (path :string) (state :pointer) (flags :uint32))

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
  (defun %removefile (path state flags)
    (declare (ignore state flags))
    (%macos-only "removefile" path))
  (defun %errno () nil))

;;; --- implementation -----------------------------------------------------------

(defun %native (x)
  "The native namestring of X (a native namestring is kept as is), without a
trailing slash (except for the root)."
  (let ((s (if (stringp x) x (uiop:native-namestring x))))
    (if (and (> (length s) 1) (char= #\/ (char s (1- (length s)))))
        (let ((trimmed (string-right-trim "/" s)))
          (if (string= trimmed "") "/" trimmed))
        s)))

(defun %join (directory name)
  "The native name of NAME inside the native DIRECTORY (no trailing slash)."
  (concatenate 'string (if (string= directory "/") "" directory) "/" name))

(defun %fail (operation path fs errno)
  "Signal CLONEFILE-ERROR for OPERATION on PATH, errno ERRNO."
  (error 'clonefile-error :operation operation :code errno :path path :filesystem fs
                          :message (format nil "~A(2) failed~@[ (errno ~D)~]" operation errno)))

(defun %clone-call (source destination)
  "clonefile(2) of the native namestrings SOURCE and DESTINATION with
+CLONEFILE-FLAGS+, calling *CLONEFILE-TRACE* first. → (values T NIL) or
(values NIL errno); errno is read right after the call."
  (when *clonefile-trace*
    (funcall *clonefile-trace* source destination))
  (if (zerop (%clonefile source destination +clonefile-flags+))
      (values t nil)
      (values nil (%errno))))

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
  #-darwin (%getattrlist (%native directory) nil nil 0 0)
  #+darwin
  (cffi:with-foreign-objects ((al '(:struct attrlist))
                              (buf '(:struct vol-capabilities-buffer)))
    (dotimes (i (cffi:foreign-type-size '(:struct attrlist)))
      (setf (cffi:mem-aref al :uint8 i) 0))
    (setf (cffi:foreign-slot-value al '(:struct attrlist) 'bitmapcount) +attr-bit-map-count+
          (cffi:foreign-slot-value al '(:struct attrlist) 'volattr)
          (logior +attr-vol-info+ +attr-vol-capabilities+))
    (unless (zerop (%getattrlist (%native directory) al buf
                                 (cffi:foreign-type-size '(:struct vol-capabilities-buffer))
                                 0))
      (%fail "getattrlist" directory nil (%errno)))
    (flet ((word (slot)
             (cffi:mem-aref (cffi:foreign-slot-pointer buf '(:struct vol-capabilities-buffer) slot)
                            :uint32 +vol-capabilities-interfaces+)))
      (and (logtest +vol-cap-int-clone+ (word 'capabilities))
           (logtest +vol-cap-int-clone+ (word 'valid))
           t))))

(defun volume-device (directory)
  "st_dev of DIRECTORY (a pathname or native namestring; symlinks followed),
an integer: equal for two paths on one volume. Two APFS volumes of one
container are two devices. Signals CLONEFILE-ERROR (operation \"stat\") for
a missing DIRECTORY and off macOS."
  #-darwin (%stat (%native directory) nil)
  #+darwin
  (cffi:with-foreign-object (st '(:struct darwin-stat))
    (if (zerop (%stat (%native directory) st))
        (cffi:foreign-slot-value st '(:struct darwin-stat) 'st-dev)
        (%fail "stat" directory nil (%errno)))))

(defun clonefile-available-p (fs source-dir destination-dir)
  "The AVAILABLE-P probe of :CLONEFILE → (values available-p reason), in
this order: off macOS (NIL :UNAVAILABLE); FS not a LOCAL-FILESYSTEM (NIL
:UNSUPPORTED-FILESYSTEM); the volume of SOURCE-DIR lacks VOL_CAP_INT_CLONE
(NIL :UNSUPPORTED-VOLUME); SOURCE-DIR and DESTINATION-DIR on different
devices (NIL :CROSS-VOLUME); otherwise T. Both are existing directories
(pathlib passes the destination's nearest existing ancestor). Never
signals, and caches nothing."
  #-darwin (declare (ignore fs source-dir destination-dir))
  #-darwin (values nil :unavailable)
  #+darwin
  (if (not (typep fs 'sp:local-filesystem))
      (values nil :unsupported-filesystem)
      (handler-case
          (cond ((not (volume-supports-clone-p source-dir))
                 (values nil :unsupported-volume))
                ((/= (volume-device source-dir) (volume-device destination-dir))
                 (values nil :cross-volume))
                (t (values t nil)))
        ;; Only a directory vanishing under the probe gets here (pathlib
        ;; passes existing ones): nothing is known about the volume.
        (clonefile-error () (values nil :unavailable)))))

(defun clonefile-file (fs source destination)
  "The per-file CLONE-FILE of :CLONEFILE: clonefile(SOURCE, DESTINATION,
CLONE_NOFOLLOW | CLONE_NOOWNERCOPY) on the native namestrings (UTF-8),
calling *CLONEFILE-TRACE* first. → T when DESTINATION was made; (values NIL
:UNSUPPORTED-VOLUME) on ENOTSUP; (values NIL :CROSS-VOLUME) on EXDEV; any
other errno signals CLONEFILE-ERROR (operation \"clonefile\", code errno,
path SOURCE, filesystem FS). clonefile(2) makes DESTINATION whole or not at
all, so a failure leaves nothing behind."
  (multiple-value-bind (ok errno) (%clone-call (%native source) (%native destination))
    (cond (ok t)
          ((eql errno +enotsup+) (values nil :unsupported-volume))
          ((eql errno +exdev+) (values nil :cross-volume))
          (t (%fail "clonefile" source fs errno)))))

;;; The tree hook's walk lists names the way pathlib's per-file walk does
;;; (FS-ITERDIR), so the two agree on which entries exist, and takes every
;;; fact from lstat(2), so nothing is followed. On APFS a directory's st_nlink
;;; is 2 + its entries: when the listing shows fewer, something it hides
;;; (a dangling link) would be cloned but not walked, and the hook declines.

#+darwin
(defun %lstat-facts (native)
  "→ (values kind mode-bits nlink) of the native NATIVE, never following a
link. KIND is :FILE, :DIRECTORY, :SYMLINK, :OTHER, or :MISSING when lstat
fails."
  (cffi:with-foreign-object (st '(:struct darwin-stat))
    (if (zerop (%lstat native st))
        (let ((mode (cffi:foreign-slot-value st '(:struct darwin-stat) 'st-mode)))
          (values (case (logand mode #o170000)
                    (#o100000 :file)
                    (#o040000 :directory)
                    (#o120000 :symlink)
                    (t :other))
                  (logand mode #o7777)
                  (cffi:foreign-slot-value st '(:struct darwin-stat) 'st-nlink)))
        (values :missing 0 0))))

(defun %entries (fs directory)
  "((name . pathname) ...) of DIRECTORY as FS-ITERDIR lists it, each name cut
from the entry's native namestring, without duplicates."
  (let ((seen (make-hash-table :test 'equal))
        (out '()))
    (dolist (p (sp:fs-iterdir fs directory) (nreverse out))
      (let* ((n (%native p))
             (name (subseq n (1+ (or (position #\/ n :from-end t) -1)))))
        (unless (gethash name seen)
          (setf (gethash name seen) t)
          (push (cons name p) out))))))

#+darwin
(defun %tree-file-count (fs directory native)
  "The regular files under DIRECTORY (native NATIVE), or NIL when the
per-file walk would make a different tree. Second value: the top-level
entries."
  (multiple-value-bind (kind bits nlink) (%lstat-facts native)
    (declare (ignore bits))
    (let ((entries (and (eq kind :directory) (%entries fs directory)))
          (count 0))
      (unless (and (eq kind :directory) (= nlink (+ 2 (length entries))))
        (return-from %tree-file-count nil))
      (loop for (name . p) in entries
            for child = (%join native name)
            do (multiple-value-bind (k b n) (%lstat-facts child)
                 (when (and (member k '(:file :directory)) (logtest b #o7000))
                   (return-from %tree-file-count nil))
                 (ecase k
                   (:file (if (> n 1)
                              (return-from %tree-file-count nil)
                              (incf count)))
                   (:symlink)
                   (:directory
                    (let ((c (%tree-file-count fs (uiop:ensure-directory-pathname p) child)))
                      (if c
                          (incf count c)
                          (return-from %tree-file-count nil))))
                   ((:other :missing) (return-from %tree-file-count nil)))))
      (values count entries))))

(defun %remove-made (natives)
  "Remove what the hook made (native names), never following a link. A
failing removal is dropped: the outcome the caller sees is the clone's."
  (dolist (n natives)
    (%removefile n (cffi:null-pointer) +removefile-recursive+)))

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
  #-darwin (declare (ignore fs source destination matcher))
  #-darwin nil                          ; the probe says :UNAVAILABLE: never called
  #+darwin
  (unless matcher
    (let ((src (%native source))
          (dst (%native destination)))
      (multiple-value-bind (count entries)
          ;; A tree changing under the walk: decline, the per-file walk reports it.
          (handler-case (%tree-file-count fs (uiop:ensure-directory-pathname source) src)
            (sp:path-error () nil))
        (when count
          (let ((made '()))
            (unwind-protect
                 (progn
                   (loop for (name . p) in entries
                         do (let ((to (%join dst name)))
                              (multiple-value-bind (ok errno) (%clone-call (%join src name) to)
                                (if ok
                                    (push to made)
                                    (progn
                                      ;; Never the failing entry: it may be
                                      ;; someone else's. Clean up, then report.
                                      (%remove-made (shiftf made '()))
                                      (if (or (eql errno +enotsup+) (eql errno +exdev+))
                                          (return-from clonefile-tree nil)
                                          (%fail "clonefile" p fs errno)))))))
                   (setf made '())
                   count)
              ;; A non-local exit (out of *CLONEFILE-TRACE*) cleans up too.
              (%remove-made made))))))))

