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
