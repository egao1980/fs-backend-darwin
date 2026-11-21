(in-package #:fs-backend-darwin)

;;; --- canonical paths --------------------------------------------------------------
;;;
;;; FSEvents reports absolute, canonical paths: /var, /tmp and /etc come back
;;; as /private/var, /private/tmp, /private/etc, and on a case-insensitive
;;; volume the case of a path component is the case on disk, not the case
;;; the caller spelled. The journal maps each event path to a path relative
;;; to its root with FSEVENTS-RELATIVE-PATH, against the root's truename.

(defparameter +private-aliases+ '("var" "tmp" "etc")
  "The top-level directories that are symlinks into /private on macOS.")

(defun %path-components (namestring)
  "The non-empty \"/\"-separated components of NAMESTRING."
  (remove "" (uiop:split-string namestring :separator "/") :test #'string=))

(defun %unalias-private (components test)
  "COMPONENTS without a leading \"private\" that is followed by one of
+PRIVATE-ALIASES+ (compared with TEST)."
  (if (and (rest components)
           (funcall test "private" (first components))
           (member (second components) +private-aliases+ :test test))
      (rest components)
      components))

(defun fsevents-relative-path (root path &key (case-sensitive t))
  "The POSIX path string of PATH relative to the directory ROOT, \"\" when
PATH is ROOT itself, or NIL when PATH is not at or below ROOT.
ROOT and PATH are absolute native namestrings (ROOT with or without a
trailing \"/\"). Either may use the /private aliases: \"/var/x\",
\"/tmp/x\" and \"/etc/x\" are the same as \"/private/var/x\",
\"/private/tmp/x\" and \"/private/etc/x\". The comparison is by whole
components (root \"/a/b\" does not contain \"/a/bc/f\"), ignoring case in
ROOT's components unless CASE-SENSITIVE. The relative part keeps PATH's
spelling, with no leading or trailing \"/\"."
  (check-type root string)
  (check-type path string)
  (let* ((test (if case-sensitive #'string= #'string-equal))
         (r (%unalias-private (%path-components root) test))
         (p (%unalias-private (%path-components path) test))
         (n (length r)))
    (when (and (<= n (length p))
               (every test r p))
      (format nil "~{~A~^/~}" (nthcdr n p)))))

(defun volume-case-sensitive-p (directory)
  "True when the volume holding the existing directory DIRECTORY (a
pathname or native namestring) compares names case-sensitively
(pathconf _PC_CASE_SENSITIVE on macOS). T off macOS. NIL when pathconf
cannot tell: matching case-insensitively can only keep more events, never
drop one."
  #+darwin
  (let ((name (if (stringp directory) directory (uiop:native-namestring directory))))
    (eql 1 (%pathconf name +pc-case-sensitive+)))
  #-darwin
  (progn directory t))
