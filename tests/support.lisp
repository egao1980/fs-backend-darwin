(in-package #:fs-backend-darwin/tests)

;;; Helpers. Edits go through CL:OPEN / CL:RENAME-FILE / UIOP on native
;;; pathnames, not the pathlib API, so the journal sees plain file system
;;; calls. Every work directory is a fresh subdirectory of
;;; UIOP:TEMPORARY-DIRECTORY, deleted afterwards.

(defun macos-p () (uiop:os-macosx-p))

(defparameter +skip-note+
  "FSEvents is macOS only: skipped on this OS (the :fsevents mechanism is registered but unavailable here)")

(defmacro deftest-macos (name &body body)
  "A DEFTEST whose BODY runs on macOS; elsewhere it records a skip with a note."
  `(deftest ,name
     (if (macos-p)
         (progn ,@body)
         (skip +skip-note+))))

(defvar *fs* (sp:make-local-filesystem))

(defun %fresh-name (prefix)
  (format nil "~A-~36R" prefix (random (expt 36 8) (make-random-state t))))

(defun call-with-work-dir (fn &key (prefix "fs-backend-darwin") (truename t))
  "Call FN with a new empty directory pathname under the temp directory: its
truename when TRUENAME, else as UIOP:TEMPORARY-DIRECTORY spells it."
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (%fresh-name prefix) (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    (unwind-protect (funcall fn (if truename (truename dir) dir))
      (uiop:delete-directory-tree (truename dir) :validate t :if-does-not-exist :ignore))))

(defmacro with-work-dir ((var &rest keys) &body body)
  `(call-with-work-dir (lambda (,var) ,@body) ,@keys))

(defun sub (dir rel)
  "The pathname REL (POSIX, \"/\"-terminated for a directory) below DIR."
  (merge-pathnames (uiop:parse-unix-namestring rel) (uiop:ensure-directory-pathname dir)))

(defun put (dir rel text)
  (let ((p (sub dir rel)))
    (ensure-directories-exist p)
    (with-open-file (s p :direction :output :if-exists :supersede :if-does-not-exist :create)
      (write-string text s))
    p))

(defun make-tree (dir rels)
  (dolist (r rels dir)
    (if (char= #\/ (char r (1- (length r))))
        (ensure-directories-exist (sub dir r))
        (put dir r r))))

(defun watch (dir &rest keys)
  (apply #'sp:fs-watch *fs* (uiop:ensure-directory-pathname dir) :mechanism :fsevents keys))

(defmacro with-journal ((var dir &rest keys) &body body)
  `(let ((,var (watch ,dir ,@keys)))
     (unwind-protect (progn ,@body)
       (sp:journal-close ,var))))

(defun drain (journal &rest keys)
  "(paths complete-p) of one drain."
  (multiple-value-list (apply #'sp:journal-drain journal keys)))

(defun covers-p (paths rel)
  "True when REL is one of PATHS or below one of them."
  (some (lambda (p)
          (or (string= p rel)
              (and (< (length p) (length rel))
                   (string= p rel :end2 (length p))
                   (char= #\/ (char rel (length p))))))
        paths))

(defun thread-count () (length (bt2:all-threads)))

(defun wait-until (predicate &key (timeout 3) (step 0.05))
  "Poll PREDICATE until true or TIMEOUT seconds; → its last value."
  (loop with deadline = (+ (get-internal-real-time)
                           (* timeout internal-time-units-per-second))
        for v = (funcall predicate)
        when (or v (> (get-internal-real-time) deadline)) return v
        do (sleep step)))

(defun elapsed (fn)
  "→ (values seconds result) of calling FN."
  (let* ((t0 (get-internal-real-time))
         (r (funcall fn)))
    (values (/ (- (get-internal-real-time) t0) internal-time-units-per-second) r)))

(defun native (pathname)
  (uiop:native-namestring pathname))

(defun strip-private (namestring)
  "\"/private/var/x\" → \"/var/x\" (also /tmp, /etc); other names unchanged."
  (if (and (> (length namestring) 8) (string= "/private/" namestring :end2 9))
      (subseq namestring 8)
      namestring))

;;; --- R4c-1: clones --------------------------------------------------------------
;;;
;;; Test volumes are disk images the tests make and remove themselves
;;; (hdiutil, no root needed). A failed hdiutil is a test failure, never a
;;; skip, so CI cannot pass by skipping.

(defparameter +clone-skip-note+
  "clonefile(2) is macOS only: skipped on this OS (the :clonefile mechanism is registered but unavailable here)")

(defmacro deftest-clone-macos (name &body body)
  "A DEFTEST whose BODY runs on macOS; elsewhere it records a skip with a note."
  `(deftest ,name
     (if (macos-p)
         (progn ,@body)
         (skip +clone-skip-note+))))

(defun hdiutil (&rest args)
  "Run hdiutil with ARGS (strings); signal an ERROR with its output when it fails."
  (multiple-value-bind (out err code)
      (uiop:run-program (cons "/usr/bin/hdiutil" args)
                        :output :string :error-output :string :ignore-error-status t)
    (unless (zerop code)
      (error "hdiutil ~{~A~^ ~} failed (~D): ~A~A" args code out err))
    out))

(defun call-with-disk-image (fn &key (fs "APFS") (size "64m"))
  "Make a disk image of file system FS (\"APFS\", \"HFS+\", ...) and SIZE in a
fresh temp directory, attach it on a mount point there, call FN with the
mount point's truename, and always detach and delete it afterwards."
  (let* ((work (uiop:ensure-directory-pathname
                (merge-pathnames (%fresh-name "r4c-image") (uiop:temporary-directory))))
         (image (merge-pathnames "volume.dmg" work))
         (mount (merge-pathnames "mnt/" work))
         (attached nil))
    (ensure-directories-exist mount)
    (unwind-protect
         (progn
           (hdiutil "create" "-fs" fs "-size" size
                    "-volname" (format nil "r4c-~(~4,'0X~)" (random #x10000 (make-random-state t)))
                    (native image))
           (hdiutil "attach" "-nobrowse" "-noautoopen" "-noverify"
                    "-mountpoint" (native mount) (native image))
           (setf attached t)
           (funcall fn (truename mount)))
      (when attached
        (ignore-errors (hdiutil "detach" "-force" (native mount))))
      (uiop:delete-directory-tree work :validate t :if-does-not-exist :ignore))))

(defmacro with-disk-image ((dir &key (fs "APFS") (size "64m")) &body body)
  "Run BODY with DIR bound to the mount point of a new attached disk image."
  `(call-with-disk-image (lambda (,dir) ,@body) :fs ,fs :size ,size))

(defun call-in-subdirectory (dir name fn)
  (let ((sub (sub dir (format nil "~A/" name))))
    (ensure-directories-exist sub)
    (funcall fn (truename sub))))

;;; statfs(2): free bytes of a volume. The sharing tests run on a fresh
;;; image of their own, where nothing else writes, and APFS charges blocks
;;; when they are written (measured on macOS 26: a clone of a 32 MiB file
;;; costs 0 KiB, a 1 MiB overwrite of the clone 1024 KiB, a copy 32776 KiB).
;;; A clone id (ATTR_CMNEXT_CLONEID) only shows that two files are related;
;;; free blocks show that the data is not stored twice, and that a write
;;; into the clone allocates only the blocks written.

#+darwin
(progn
  (cffi:defcstruct (test-statfs :size 2168)
    (f-bsize :uint32 :offset 0)
    (f-blocks :uint64 :offset 8)
    (f-bfree :uint64 :offset 16)
    (f-bavail :uint64 :offset 24))
  (cffi:defcfun (#+x86-64 "statfs$INODE64" #-x86-64 "statfs" %test-statfs) :int
    (path :string) (buffer :pointer)))

(defun free-bytes (dir)
  "Free bytes (f_bfree × f_bsize) of the volume holding DIR."
  #+darwin
  (cffi:with-foreign-object (buf '(:struct test-statfs))
    (assert (zerop (%test-statfs (native dir) buf)) () "statfs ~A failed" dir)
    (* (cffi:foreign-slot-value buf '(:struct test-statfs) 'f-bfree)
       (cffi:foreign-slot-value buf '(:struct test-statfs) 'f-bsize)))
  #-darwin (error "statfs is used on macOS only: ~A" dir))

(defparameter +mib+ (* 1024 1024))

(defun random-octets (n)
  (let ((v (make-array n :element-type '(unsigned-byte 8)))
        (state (make-random-state t)))
    (dotimes (i n v) (setf (aref v i) (random 256 state)))))

(defun write-octets (path octets)
  (ensure-directories-exist path)
  (with-open-file (s path :direction :output :element-type '(unsigned-byte 8)
                          :if-exists :supersede :if-does-not-exist :create)
    (write-sequence octets s))
  path)

(defun overwrite-octets (path octets &key (position 0))
  "Write OCTETS into the existing file PATH at POSITION, in place."
  (with-open-file (s path :direction :output :element-type '(unsigned-byte 8)
                          :if-exists :overwrite)
    (file-position s position)
    (write-sequence octets s))
  path)

(defun read-octets (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((v (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence v s)
      v)))

(defun file-mode (path)
  (logand #o7777 (sp:file-stat-mode (sp:fs-stat *fs* path :follow-symlinks nil))))

(defun file-mtime (path)
  (sp:file-stat-mtime (sp:fs-stat *fs* path :follow-symlinks nil)))

(defun chmod (path mode)
  #+(and sbcl darwin) (sb-posix:chmod (native path) mode)
  #-(and sbcl darwin) (sp:fs-chmod *fs* path mode))

(defun lstat-kind (native-name)
  "(values kind mode nlink) of NATIVE-NAME without following a symlink."
  #+(and sbcl darwin)
  (let* ((st (sb-posix:lstat native-name))
         (mode (sb-posix:stat-mode st)))
    (values (case (logand mode #o170000)
              (#o100000 :file) (#o040000 :directory) (#o120000 :symlink) (t :other))
            (logand mode #o7777)
            (sb-posix:stat-nlink st)))
  #-(and sbcl darwin) (error "lstat-kind needs SBCL: ~A" native-name))

(defun directory-names (dir)
  "Names of the entries of DIR (no . and ..), sorted."
  #+(and sbcl darwin)
  (let ((d (sb-posix:opendir (native dir))) (names '()))
    (unwind-protect
         (loop for ent = (sb-posix:readdir d)
               until (sb-alien:null-alien ent)
               do (let ((n (sb-posix:dirent-name ent)))
                    (unless (member n '("." "..") :test #'string=)
                      (push n names))))
      (sb-posix:closedir d))
    (sort names #'string<))
  #-(and sbcl darwin) (error "directory-names needs SBCL: ~A" dir))

(defun tree-listing (dir)
  "Everything below DIR, sorted by relative path, without following
symlinks: (rel :directory) | (rel :symlink target) | (rel :file mode mtime
octets) | (rel :other). Two trees with EQUALP listings are the same tree
with the same metadata as far as R4c-0 keeps it."
  (let ((out '()))
    (labels ((walk (native-dir prefix)
               (dolist (name (directory-names native-dir))
                 (let* ((full (concatenate 'string native-dir "/" name))
                        (rel (concatenate 'string prefix name)))
                   (multiple-value-bind (kind mode) (lstat-kind full)
                     (ecase kind
                       (:directory (push (list rel :directory) out)
                        (walk full (concatenate 'string rel "/")))
                       (:symlink (push (list rel :symlink #+(and sbcl darwin) (sb-posix:readlink full) #-(and sbcl darwin) nil) out))
                       (:file (let ((p (uiop:parse-native-namestring full)))
                                (push (list rel :file (logand mode #o777) (file-mtime p) (read-octets p))
                                      out)))
                       (:other (push (list rel :other) out))))))))
      (walk (string-right-trim "/" (native dir)) ""))
    (sort out #'string< :key #'first)))

(defmacro with-clonefile-trace ((var) &body body)
  "Run BODY with *CLONEFILE-TRACE* recording every clonefile(2) call; VAR is
bound to a function returning the (source . destination) native pairs so
far, oldest first."
  (let ((log (gensym "LOG")))
    `(let* ((,log '())
            (,var (lambda () (reverse ,log)))
            (*clonefile-trace* (lambda (s d) (push (cons s d) ,log))))
       (declare (ignorable ,var))
       ,@body)))

(defparameter +hook-tree+
  '("a.txt" "sub/b.txt" "sub/deep/c.txt" "empty/" ".git/HEAD" "x.log" "run.sh")
  "The tree of the hook tests; plus the symlink link → a.txt and run.sh #o755.")

(defun make-hook-tree (dir)
  (make-tree dir +hook-tree+)
  (chmod (sub dir "run.sh") #o755)
  (chmod (sub dir "a.txt") #o640)
  (sp:fs-set-mtime *fs* (sub dir "a.txt") (encode-universal-time 0 0 12 1 6 2001 0))
  (sp:fs-set-mtime *fs* (sub dir "sub/deep/c.txt") (encode-universal-time 0 0 12 2 6 2001 0))
  (sp:fs-create-symlink *fs* (sub dir "link") "a.txt")
  dir)
