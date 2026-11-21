(in-package #:fs-backend-darwin/tests)

;;; R4c-1 on macOS: detection, the per-file clone, real sharing, the tree
;;; hook, areas. The temp directory is on the APFS Data volume; the other
;;; volumes are disk images made by WITH-DISK-IMAGE.

(defun available (src dst)
  (multiple-value-list (clonefile-available-p *fs* src dst)))

;;; --- detection ------------------------------------------------------------------

(deftest-clone-macos clonefile-detection
  (with-work-dir (tmp)
    (ok (eq t (volume-supports-clone-p tmp)) "the temp directory is on APFS")
    (ok (integerp (volume-device tmp)))
    (ensure-directories-exist (sub tmp "a/"))
    (ensure-directories-exist (sub tmp "b/"))
    (ok (= (volume-device (sub tmp "a/")) (volume-device (sub tmp "b/"))) "one volume, one device")
    (ok (eq t (first (available (sub tmp "a/") (sub tmp "b/")))) "within the temp volume: available")
    (ok (equal '(:clonefile nil) (multiple-value-list (sp:fs-clone-supported-p *fs* (sub tmp "a/"))))
        "pathlib picks :clonefile for the temp directory")
    (ok (eq :clonefile (first (sp:clone-mechanisms *fs* (sub tmp "a/") (sub tmp "b/")))))
    (with-disk-image (apfs :fs "APFS")
      (with-disk-image (hfs :fs "HFS+")
        (ok (eq t (volume-supports-clone-p apfs)) "an APFS image supports clones")
        (ok (null (volume-supports-clone-p hfs)) "an HFS+ image does not")
        (ok (/= (volume-device apfs) (volume-device tmp)) "an image is its own device")
        (ok (/= (volume-device apfs) (volume-device hfs)))
        (ok (equal '(nil :unsupported-volume) (available hfs hfs)) "HFS+ → HFS+")
        (ok (equal '(nil :unsupported-volume) (available hfs tmp))
            "the source volume's capability is checked before the device")
        (ok (equal '(nil :cross-volume) (available tmp apfs)) "temp (APFS) → APFS image")
        (ok (equal '(nil :cross-volume) (available apfs tmp)))
        (ok (equal '(nil :cross-volume) (available tmp hfs)))
        (ensure-directories-exist (sub apfs "x/"))
        (ok (eq t (first (available apfs (sub apfs "x/")))) "within the APFS image: available")
        (ok (equal '(nil :unsupported-volume)
                   (multiple-value-list (sp:fs-clone-supported-p *fs* hfs))))
        (ok (equal '(nil :cross-volume)
                   (multiple-value-list (sp:fs-clone-supported-p *fs* tmp apfs))))))
    ;; Missing directories signal; the probe itself never does (pathlib only
    ;; passes existing directories).
    (let ((missing (sub tmp "missing/")))
      (ok (handler-case (progn (volume-device missing) nil)
            (clonefile-error (c) (equal "stat" (sp:clone-error-operation c))))
          "volume-device of a missing directory → clonefile-error \"stat\"")
      (ok (signals (volume-supports-clone-p missing) 'clonefile-error)))
    ;; Symlinks are followed.
    (sp:fs-create-symlink *fs* (sub tmp "alias") (native (sub tmp "a/")))
    (ok (= (volume-device (sub tmp "a/")) (volume-device (native (sub tmp "alias")))))
    (ok (eq t (volume-supports-clone-p (native (sub tmp "alias")))))))

;;; --- per file -------------------------------------------------------------------

(deftest-clone-macos clonefile-file-basics
  (with-work-dir (tmp)
    (let* ((src (write-octets (sub tmp "src/data.bin") (random-octets 100000)))
           (dst (sub tmp "dst/data.bin"))
           (mtime (encode-universal-time 0 0 12 3 6 2001 0)))
      (chmod src #o640)
      (sp:fs-set-mtime *fs* src mtime)
      (ensure-directories-exist dst)
      (with-clonefile-trace (calls)
        (ok (eq t (clonefile-file *fs* src dst)) "a clone on APFS → T")
        (ok (equal (list (cons (native src) (native dst))) (funcall calls))
            "*clonefile-trace* sees the native names of the one call"))
      (ok (equalp (read-octets src) (read-octets dst)) "content")
      (ok (= #o640 (file-mode dst)) "mode kept")
      (ok (= mtime (file-mtime dst)) "mtime kept")
      ;; CLONE_NOFOLLOW: a symlink source is cloned as the link.
      (sp:fs-create-symlink *fs* (sub tmp "src/link") "data.bin")
      (ok (eq t (clonefile-file *fs* (sub tmp "src/link") (sub tmp "dst/link"))))
      (ok (eq :symlink (lstat-kind (native (sub tmp "dst/link")))) "a symlink stays a link")
      (ok (equal "data.bin" #+(and sbcl darwin) (sb-posix:readlink (native (sub tmp "dst/link"))) #-(and sbcl darwin) nil))
      ;; Non-ASCII names go through as UTF-8.
      (let ((u (write-octets (sub tmp "src/naïve файл.txt") (random-octets 10))))
        (ok (eq t (clonefile-file *fs* u (sub tmp "dst/naïve файл.txt"))))
        (ok (equalp (read-octets u) (read-octets (sub tmp "dst/naïve файл.txt")))))
      ;; EEXIST is an error (pathlib guarantees DESTINATION is absent).
      (ok (handler-case (progn (clonefile-file *fs* src dst) nil)
            (clonefile-error (c) (eql 17 (sp:clone-error-code c))))
          "an existing destination → clonefile-error with errno EEXIST"))))

(deftest-clone-macos clonefile-file-fallback-reasons
  (with-work-dir (tmp)
    (let ((src (write-octets (sub tmp "data.bin") (random-octets 5000))))
      (with-disk-image (apfs :fs "APFS")
        (with-disk-image (hfs :fs "HFS+")
          ;; ENOTSUP: HFS+ to HFS+, called directly (pathlib would not ask).
          (let ((h (write-octets (sub hfs "h.bin") (random-octets 5000))))
            (ok (equal '(nil :unsupported-volume)
                       (multiple-value-list (clonefile-file *fs* h (sub hfs "h2.bin"))))
                "ENOTSUP → (nil :unsupported-volume)")
            (ok (not (probe-file (sub hfs "h2.bin"))) "nothing made"))
          ;; EXDEV: temp to the APFS image.
          (ok (equal '(nil :cross-volume)
                     (multiple-value-list (clonefile-file *fs* src (sub apfs "x.bin"))))
              "EXDEV → (nil :cross-volume)")
          (ok (not (probe-file (sub apfs "x.bin"))) "nothing made"))))))

(deftest-clone-macos clonefile-file-eacces
  (with-work-dir (tmp)
    (let* ((src (write-octets (sub tmp "src/a.bin") (random-octets 5000)))
           (locked (sub tmp "locked/")))
      (ensure-directories-exist locked)
      (chmod locked #o555)
      (unwind-protect
           (progn
             (ok (handler-case (progn (clonefile-file *fs* src (sub locked "a.bin")) nil)
                   (clonefile-error (c)
                     (and (eql 13 (sp:clone-error-code c))
                          (equal "clonefile" (sp:clone-error-operation c))
                          (eq :clonefile (sp:clone-error-mechanism c))
                          (equal (native src) (native (sp:path-error-path c))))))
                 "EACCES → clonefile-error: errno 13, \"clonefile\", the source path")
             ;; Through pathlib: USE-COPY is offered; once the directory is
             ;; writable again, the copy goes through.
             (let* ((offered nil)
                    (report (handler-bind
                                ((clonefile-error
                                   (lambda (c)
                                     (setf offered (and (find-restart 'sp:use-copy c) t))
                                     (chmod locked #o755)
                                     (sp:invoke-use-copy c))))
                              (sp:fs-clone-file *fs* src (sub locked "a.bin") :mechanism :clonefile))))
               (ok offered "use-copy offered around the clonefile call")
               (ok (eq :clonefile (sp:clone-report-mechanism report)))
               (ok (= 1 (sp:clone-report-copied report)))
               (ok (equal '(("a.bin" . :clone-failed)) (sp:clone-report-fallbacks report)))
               (ok (equalp (read-octets src) (read-octets (sub locked "a.bin"))))))
        (chmod locked #o755)))))

;;; --- sharing is real ------------------------------------------------------------

(deftest-clone-macos clonefile-shares-blocks
  (with-disk-image (apfs :fs "APFS" :size "160m")
    (let* ((size (* 32 +mib+))
           (data (random-octets size))
           (src (write-octets (sub apfs "src.bin") data))
           (f0 (free-bytes apfs)))
      (ok (eq t (clonefile-file *fs* src (sub apfs "clone.bin"))))
      (let ((f1 (free-bytes apfs)))
        (ok (< (- f0 f1) +mib+)
            (format nil "a clone of 32 MiB costs < 1 MiB of free space (cost ~D bytes)" (- f0 f1)))
        ;; A write into the clone allocates only what it writes.
        (overwrite-octets (sub apfs "clone.bin") (random-octets +mib+) :position (* 8 +mib+))
        (let ((f2 (free-bytes apfs)))
          (ok (<= (floor +mib+ 2) (- f1 f2) (* 3 +mib+))
              (format nil "a 1 MiB write into the clone costs about 1 MiB (cost ~D bytes)" (- f1 f2)))
          (ok (equalp data (read-octets src)) "the source is unchanged")
          (ok (not (equalp data (read-octets (sub apfs "clone.bin")))) "the clone changed")
          ;; A plain copy, for contrast, pays in full.
          (uiop:copy-file src (sub apfs "copy.bin"))
          (let ((f3 (free-bytes apfs)))
            (ok (>= (- f2 f3) size)
                (format nil "a copy costs at least 32 MiB (cost ~D bytes)" (- f2 f3))))))
      ;; Through pathlib: FS-CLONE-FILE :AUTO clones, so it costs nothing either.
      (let* ((f4 (free-bytes apfs))
             (report (sp:fs-clone-file *fs* src (sub apfs "sub/clone2.bin"))))
        (ok (eq :clonefile (sp:clone-report-mechanism report)))
        (ok (= 1 (sp:clone-report-cloned report)))
        (ok (< (- f4 (free-bytes apfs)) +mib+) "fs-clone-file :auto shares blocks too")
        (ok (equalp data (read-octets (sub apfs "sub/clone2.bin"))))))))

;;; --- the tree hook --------------------------------------------------------------

(defun top-level-calls (calls src dst)
  "True when CALLS clone exactly the top-level entries of SRC into DST."
  (let ((names (directory-names src))
        (s (string-right-trim "/" (native src)))
        (d (string-right-trim "/" (native dst))))
    (equal (sort (mapcar (lambda (n) (cons (concatenate 'string s "/" n)
                                           (concatenate 'string d "/" n)))
                         names)
                 #'string< :key #'car)
           (sort (copy-list calls) #'string< :key #'car))))

(deftest-clone-macos clonefile-tree-hook
  (with-work-dir (tmp)
    (let ((src (make-hook-tree (sub tmp "src/")))
          (dst (sub tmp "dst/"))
          (ref (sub tmp "ref/")))
      (sp:fs-clone-tree *fs* src ref :mechanism :copy)
      (with-clonefile-trace (calls)
        (let ((report (sp:fs-clone-tree *fs* src dst :mechanism :clonefile)))
          (ok (top-level-calls (funcall calls) src dst)
              (format nil "one clonefile per top-level entry: ~S" (funcall calls)))
          (ok (eq :clonefile (sp:clone-report-mechanism report)))
          (ok (= 6 (sp:clone-report-cloned report)) "the hook counts the regular files")
          (ok (= 0 (sp:clone-report-copied report)))
          (ok (null (sp:clone-report-fallbacks report)))))
      (ok (equalp (tree-listing ref) (tree-listing dst))
          "the hook's tree equals the per-file one (content, modes, mtimes, links, empty dirs)")
      ;; With a matcher the hook declines and pathlib goes per file.
      (ok (null (clonefile-tree *fs* src (sub tmp "declined/") (sp:parse-ignore '("*.log"))))
          "a matcher → declined")
      (let ((dst2 (sub tmp "dst2/")))
        (with-clonefile-trace (calls)
          (let ((report (sp:fs-clone-tree *fs* src dst2 :mechanism :clonefile
                                                  :ignore (sp:parse-ignore '("*.log")))))
            (ok (= (sp:clone-report-cloned report) (length (funcall calls)))
                "one call per regular file")
            (ok (every (lambda (c) (eq :file (lstat-kind (cdr c)))) (funcall calls))
                "per-file calls only")))
        (ok (not (probe-file (sub dst2 "x.log"))) "ignored paths left out")))))

(defun declines-p (src dst)
  "True when the hook declines SRC (MATCHER NIL) without a clonefile call
and leaves DST empty."
  (ensure-directories-exist dst)
  (with-clonefile-trace (calls)
    (and (null (clonefile-tree *fs* src dst nil))
         (null (funcall calls))
         (null (directory-names dst)))))

(deftest-clone-macos clonefile-tree-hook-declines
  (with-work-dir (tmp)
    ;; A FIFO: the walk leaves it out, clonefile of its directory would not.
    (let ((src (make-hook-tree (sub tmp "fifo/"))))
      #+(and sbcl darwin) (sb-posix:mkfifo (native (sub src "sub/pipe")) #o644)
      (ok (declines-p src (sub tmp "fifo-dst/")) "a FIFO → declined")
      (sp:fs-clone-tree *fs* src (sub tmp "fifo-tree/") :mechanism :clonefile)
      (ok (not (probe-file (sub tmp "fifo-tree/sub/pipe"))) "the per-file walk leaves the FIFO out")
      (ok (probe-file (sub tmp "fifo-tree/sub/b.txt"))))
    ;; A hard link: the walk makes two files, a directory clone keeps one inode.
    (let ((src (make-hook-tree (sub tmp "hard/"))))
      #+(and sbcl darwin) (sb-posix:link (native (sub src "a.txt")) (native (sub src "sub/a-link.txt")))
      (ok (declines-p src (sub tmp "hard-dst/")) "a file with two links → declined")
      (sp:fs-clone-tree *fs* src (sub tmp "hard-tree/") :mechanism :clonefile)
      (ok (= 1 (nth-value 2 (lstat-kind (native (sub tmp "hard-tree/a.txt")))))
          "each link becomes its own file"))
    ;; setuid / setgid / sticky: the walk drops them, a clone keeps them.
    (dolist (bits '(#o4000 #o2000 #o1000))
      (let ((src (make-hook-tree (sub tmp (format nil "bits-~O/" bits)))))
        (chmod (sub src "run.sh") (logior #o755 bits))
        (ok (declines-p src (sub tmp (format nil "bits-~O-dst/" bits)))
            (format nil "mode bit #o~O → declined" bits))))
    (let ((src (make-hook-tree (sub tmp "setuid/"))))
      (chmod (sub src "run.sh") #o4755)
      (sp:fs-clone-tree *fs* src (sub tmp "setuid-tree/") :mechanism :clonefile)
      (ok (= #o755 (file-mode (sub tmp "setuid-tree/run.sh"))) "per file: the setuid bit is dropped"))
    ;; A plain tree is not declined.
    (let ((src (make-hook-tree (sub tmp "plain/"))))
      (ensure-directories-exist (sub tmp "plain-dst/"))
      (ok (eql 6 (clonefile-tree *fs* src (sub tmp "plain-dst/") nil)) "a plain tree → its file count"))))

(deftest-clone-macos clonefile-tree-hook-failure
  (with-work-dir (tmp)
    (let ((src (make-hook-tree (sub tmp "src/")))
          (dst (sub tmp "dst/")))
      (ensure-directories-exist dst)
      ;; The second clonefile call finds its destination taken (EEXIST): the
      ;; hook removes what it made and signals; the intruder stays.
      (let* ((n 0)
             (intruder nil)
             (*clonefile-trace* (lambda (s d)
                                  (declare (ignore s))
                                  (when (= 2 (incf n))
                                    (setf intruder (car (last (uiop:split-string d :separator "/"))))
                                    (write-octets (uiop:parse-native-namestring d) (random-octets 3))))))
        (ok (handler-case (progn (clonefile-tree *fs* src dst nil) nil)
              (clonefile-error (c) (eql 17 (sp:clone-error-code c))))
            "a failing call → clonefile-error (EEXIST)")
        (ok (equal (list intruder) (directory-names dst))
            (format nil "the hook removed what it made: ~S" (directory-names dst)))))
    ;; Through pathlib (no USE-COPY around a hook): the error propagates and
    ;; the destination is as it was (absent).
    (let* ((src (sub tmp "src/"))
           (dst (sub tmp "dst-pathlib/"))
           (n 0)
           (*clonefile-trace* (lambda (s d)
                                (declare (ignore s))
                                (when (= 2 (incf n))
                                  (write-octets (uiop:parse-native-namestring d) (random-octets 3))))))
      (ok (signals (sp:fs-clone-tree *fs* src dst :mechanism :clonefile) 'clonefile-error))
      (ok (not (uiop:directory-exists-p dst)) "the destination is absent again"))))

;;; --- areas ----------------------------------------------------------------------

(deftest-clone-macos clonefile-areas
  (with-work-dir (tmp)
    (let ((base (make-hook-tree (sub tmp "base/"))))
      (sp:with-area (a base)
        (ok (eq :clone (sp:area-mechanism a)) "open-area on APFS clones")
        (ok (eq :clonefile (sp:clone-report-mechanism (sp:area-clone-report a))))
        (ok (null (sp:clone-report-reason (sp:area-clone-report a)))))))
  (with-disk-image (hfs :fs "HFS+")
    (let ((base (make-hook-tree (sub hfs "base/"))))
      (sp:with-area (a base :directory (sub hfs "area/"))
        (ok (eq :copy (sp:area-mechanism a)) "open-area on HFS+ copies")
        (ok (eq :unsupported-volume (sp:clone-report-reason (sp:area-clone-report a))))))))
