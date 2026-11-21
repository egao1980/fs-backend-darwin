(in-package #:fs-backend-darwin/tests)

;;; The :fsevents journal on macOS: what drains report, the incomplete
;;; flags, path canonicalisation, flush on drain, close, leaks.

(defparameter +tree+ '("sub/a.txt" "sub/deep/c.txt" "other/b.txt" "top.txt" "empty/"))

;;; --- basics ------------------------------------------------------------------------

(deftest-macos fsevents-journal-basics
  (with-work-dir (dir)
    (make-tree dir +tree+)
    (let ((streams (fsevents-stream-count))
          (j (watch dir)))
      (unwind-protect
           (progn
             (ok (typep j 'fsevents-journal))
             (ok (eq :fsevents (sp:journal-mechanism j)))
             (ok (sp:journal-open-p j))
             (ok (eq *fs* (sp:journal-filesystem j)))
             (ok (fsevents-journal-stream j) "a stream while open")
             (ok (and (fsevents-journal-thread j) (bt2:thread-alive-p (fsevents-journal-thread j)))
                 "its run-loop thread is alive")
             (ok (= (1+ streams) (fsevents-stream-count)))
             (ok (equal '(nil t) (drain j)) "nothing touched: complete and empty")
             ;; A file modified in a subdirectory: reported, and precisely.
             (put dir "sub/a.txt" "edited")
             (destructuring-bind (paths complete-p) (drain j)
               (ok complete-p "a plain edit needs no rescan")
               (ok (covers-p paths "sub/a.txt") (format nil "sub/a.txt reported: ~S" paths))
               (ok (not (covers-p paths "other/b.txt")) "an untouched sibling directory is not covered")
               (ok (not (covers-p paths "top.txt"))))
             (ok (equal '(nil t) (drain j)) "a drain consumes what it reported")
             ;; Create, delete, mkdir, rename: each touched path is covered.
             (put dir "new.txt" "n")
             (delete-file (sub dir "top.txt"))
             (ensure-directories-exist (sub dir "made/"))
             (rename-file (sub dir "sub/deep/c.txt") (sub dir "other/c2.txt"))
             (destructuring-bind (paths complete-p) (drain j)
               (ok complete-p)
               (dolist (rel '("new.txt" "top.txt" "made" "sub/deep/c.txt" "other/c2.txt"))
                 (ok (covers-p paths rel) (format nil "~A covered by ~S" rel paths)))
               (ok (not (covers-p paths "sub/a.txt")) "an entry untouched since the last drain"))
             ;; Paths are relative, POSIX, no trailing "/" (the :around normalizes).
             (put dir "empty/x.txt" "x")
             (destructuring-bind (paths complete-p) (drain j)
               (ok complete-p)
               (ok (every (lambda (p) (and (plusp (length p)) (char/= #\/ (char p 0)))) paths))
               (ok (covers-p paths "empty/x.txt"))))
        (sp:journal-close j)))))

(deftest-macos fsevents-journal-ignore
  (with-work-dir (dir)
    (put dir ".gitignore" (format nil "*.log~%build/~%"))
    (make-tree dir '("a.txt" "build/o"))
    (with-journal (j dir :ignore :auto)
      (put dir "x.log" "l")
      (put dir "build/new.o" "o")
      (put dir "a.txt" "edited")
      (ok (equal '(("a.txt") t) (drain j)) "ignored paths never show up"))))

(deftest-macos fsevents-journal-after-fs-watch-only
  ;; Events from before FS-WATCH may be reported or not; after it, always.
  (with-work-dir (dir)
    (put dir "before.txt" "b")
    (with-journal (j dir)
      (drain j)
      (put dir "after.txt" "a")
      (destructuring-bind (paths complete-p) (drain j)
        (ok complete-p)
        (ok (covers-p paths "after.txt"))
        (ok (not (covers-p paths "before.txt")) "a drain only reports what changed since the previous one")))))

;;; --- incomplete: dropped events, MustScanSubDirs, root changes ------------------------

(deftest-parametrize fsevents-incomplete-flag
    ((flag)
     :ids ("must-scan-sub-dirs" "user-dropped" "kernel-dropped" "event-ids-wrapped"
           "root-changed" "mount" "unmount" "must-scan+item-flags")
     ;; FSEvents.h values (the given constants): MustScanSubDirs, UserDropped,
     ;; KernelDropped, EventIdsWrapped, RootChanged, Mount, Unmount, and
     ;; MustScanSubDirs | ItemCreated | ItemIsDir.
     (#x1) (#x2) (#x4) (#x8) (#x20) (#x40) (#x80) (#x20101))
  (if (not (macos-p))
      (skip +skip-note+)
      (with-work-dir (dir)
        (make-tree dir +tree+)
        (with-journal (j dir)
          (drain j)
          ;; A real edit plus an injected event carrying FLAG: the drain is incomplete.
          (put dir "sub/a.txt" "edited")
          (fsevents-journal-inject j (list (native (sub dir "sub/")))
                                   (list flag))
          (ok (equal '(nil nil) (drain j))
              (format nil "flag #x~X → complete-p NIL" flag))
          ;; The mark is consumed: the journal recovers on the next drain.
          (put dir "other/b.txt" "edited")
          (destructuring-bind (paths complete-p) (drain j)
            (ok complete-p "the drain after an incomplete one is complete again")
            (ok (covers-p paths "other/b.txt")))))))

(deftest-macos fsevents-inject-plain-events
  ;; The hook runs the callback's code: canonical paths, the /var alias and
  ;; paths outside the root are handled as for real events.
  (with-work-dir (dir)
    (make-tree dir '("w/a.txt"))
    (let ((root (sub dir "w/")))
      (with-journal (j root)
        (drain j)
        (fsevents-journal-inject
         j
         (list (native (sub root "x/y.txt"))
               (strip-private (native (sub root "z.txt")))
               (native (sub dir "w2/outside.txt"))
               (native (sub dir "elsewhere.txt")))
         (list (logior +event-flag-item-created+ +event-flag-item-is-file+)
               (logior +event-flag-item-modified+ +event-flag-item-is-file+)
               +event-flag-item-created+
               +event-flag-item-created+))
        (ok (equal '(("x/y.txt" "z.txt") t) (drain j))
            "inside paths reported (either spelling of /var); w2/ and siblings are outside")
        (fsevents-journal-inject j (list (native root)) (list +event-flag-item-inode-meta-mod+))
        (ok (equal '(nil nil) (drain j)) "an event on the root itself: rescan everything")
        (fsevents-journal-inject j '() '())
        (ok (equal '(nil t) (drain j)))))))

(deftest-macos fsevents-root-renamed
  (with-work-dir (dir)
    (make-tree dir '("w/a.txt"))
    (let ((j (watch (sub dir "w/"))))
      (unwind-protect
           (progn
             (drain j)
             (rename-file (sub dir "w/") (sub dir "moved/"))
             (ok (equal '(nil nil) (drain j))
                 "the root moved away (RootChanged): complete-p NIL on the next drain"))
        (sp:journal-close j)))
    (let ((j (watch (sub dir "moved/"))))
      (unwind-protect
           (progn
             (drain j)
             (uiop:delete-directory-tree (sub dir "moved/") :validate t)
             (ok (equal '(nil nil) (drain j)) "the root deleted: complete-p NIL"))
        (sp:journal-close j)))))

;;; --- canonical paths ---------------------------------------------------------------

(deftest-macos fsevents-private-var-alias
  ;; The temp directory is under /var/folders, a /private/var alias. Watch it
  ;; spelled /var/... (not the truename) and spelled /private/var/....
  (with-work-dir (dir)
    (let* ((true (native dir))
           (alias (strip-private true)))
      (ok (string/= true alias) (format nil "the temp directory ~A is under /private" true))
      (dolist (spelling (list alias true))
        (with-journal (j (uiop:parse-native-namestring spelling :ensure-directory t))
          (drain j)
          (put dir "a.txt" spelling)
          (ok (equal '(("a.txt") t) (drain j))
              (format nil "watched as ~A: a.txt relative to the root" spelling)))))))

(deftest-macos fsevents-case-insensitive-volume
  (with-work-dir (dir)
    (put dir "Probe" "x")
    (if (volume-case-sensitive-p dir)
        (skip "the temp volume is case-sensitive: no case-insensitive volume to test")
        (let ((root (sub dir "CaseRoot/")))
          (make-tree root '("README.md" "Src/x.lisp"))
          ;; Watched as spelled in lower case: events come back as on disk.
          (with-journal (j (sub dir "caseroot/"))
            (drain j)
            (put root "Src/x.lisp" "edited")
            (destructuring-bind (paths complete-p) (drain j)
              (ok complete-p)
              (ok (covers-p paths "Src/x.lisp") (format nil "on-disk spelling: ~S" paths)))
            ;; A case-only rename: both names are reported.
            (rename-file (sub root "README.md") (sub root "readme.md"))
            (destructuring-bind (paths complete-p) (drain j)
              (ok complete-p "a case-only rename needs no rescan")
              (ok (covers-p paths "README.md") (format nil "old name in ~S" paths))
              (ok (covers-p paths "readme.md") (format nil "new name in ~S" paths))))))))

;;; --- flush on drain ------------------------------------------------------------------

(deftest-macos fsevents-flush-on-drain
  ;; With a long stream latency, a drain still reports a write made just
  ;; before it, at once: it flushes (FSEventStreamFlushSync), it does not wait.
  (with-work-dir (dir)
    (let ((*fsevents-latency* 5))
      (with-journal (j dir)
        (put dir "first.txt" "1")
        (drain j)
        (dolist (settle '(0 0.05))
          (let ((name (format nil "f-~A.txt" settle)))
            (put dir name "x")
            (multiple-value-bind (seconds result) (elapsed (lambda () (drain j :settle settle)))
              (ok (second result) (format nil "settle ~A: complete" settle))
              (ok (covers-p (first result) name) (format nil "settle ~A: ~A reported at once" settle name))
              (ok (< seconds 1.5) (format nil "settle ~A: drained in ~,3F s, not after the 5 s latency"
                                          settle seconds)))))))))

(deftest-macos fsevents-burst
  (with-work-dir (dir)
    (with-journal (j dir)
      (dotimes (k 2000) (put dir (format nil "burst/f~4,'0D.txt" k) "n"))
      (destructuring-bind (paths complete-p) (drain j)
        (if complete-p
            (ok (every (lambda (k) (covers-p paths (format nil "burst/f~4,'0D.txt" k)))
                       (loop for k below 2000 collect k))
                "complete: every burst file is covered")
            (ok (null paths) "incomplete (dropped events): no paths"))))))

;;; --- close -----------------------------------------------------------------------------

(deftest-macos fsevents-close
  (with-work-dir (dir)
    (make-tree dir +tree+)
    (let* ((streams (fsevents-stream-count))
           (j (watch dir))
           (thread (fsevents-journal-thread j)))
      (ok (bt2:thread-alive-p thread))
      (ok (null (sp:journal-close j)))
      (ok (not (sp:journal-open-p j)))
      (ok (not (bt2:thread-alive-p thread)) "close joins the run-loop thread")
      (ok (null (fsevents-journal-thread j)))
      (ok (null (fsevents-journal-stream j)) "the stream is released")
      (ok (= streams (fsevents-stream-count)))
      (ok (null (sp:journal-close j)) "idempotent")
      (ok (signals (sp:journal-drain j) 'sp:journal-error))
      (ok (signals (fsevents-journal-inject j (list (native (sub dir "a"))) (list 0)) 'sp:journal-error))
      ;; Edits after close reach nothing.
      (put dir "sub/a.txt" "after close")
      (sleep 0.2)
      (ok (= streams (fsevents-stream-count))))
    ;; Close with the root already gone, and from another thread.
    (let ((j (watch (sub dir "other/"))))
      (uiop:delete-directory-tree (sub dir "other/") :validate t)
      (ok (null (sp:journal-close j)) "close after the root was deleted"))
    (let* ((j (watch (sub dir "sub/")))
           (thread (fsevents-journal-thread j))
           (closer (bt2:make-thread (lambda () (sp:journal-close j)) :name "closer")))
      (bt2:join-thread closer)
      (ok (not (sp:journal-open-p j)))
      (ok (not (bt2:thread-alive-p thread)) "closed from another thread"))))

(deftest-macos fsevents-area-auto
  ;; With fs-backend-darwin loaded, areas get an :fsevents journal by default.
  (with-work-dir (dir)
    (make-tree dir '("base/a.txt"))
    (let ((area (sp:open-area (sp:ensure-path (sub dir "base/") :directory t)
                              :directory (sp:ensure-path (sub dir "area/") :directory t))))
      (unwind-protect
           (let ((j (sp:area-journal area)))
             (ok (and j (eq :fsevents (sp:journal-mechanism j))) ":journal :auto attaches :fsevents")
             (sp:close-area area)
             (ok (not (sp:journal-open-p j)) "closing the area closes its journal"))
        (when (sp:area-open-p area) (sp:close-area area))))))

;;; --- leaks -----------------------------------------------------------------------------

(deftest-macos fsevents-no-leak-after-50-cycles
  (with-work-dir (dir)
    (make-tree dir +tree+)
    ;; One cycle first, so lazily started threads (if any) are counted in BEFORE.
    (let ((j (watch dir))) (drain j) (sp:journal-close j))
    (let ((threads (thread-count))
          (streams (fsevents-stream-count)))
      (dotimes (k 50)
        (let ((j (watch dir)))
          (put dir "sub/a.txt" (princ-to-string k))
          (drain j)
          (sp:journal-close j)))
      (ok (= streams (fsevents-stream-count)) "every stream released")
      (ok (wait-until (lambda () (<= (thread-count) threads)) :timeout 3)
          (format nil "no thread leak: ~D threads before, ~D after 50 cycles" threads (thread-count))))))
