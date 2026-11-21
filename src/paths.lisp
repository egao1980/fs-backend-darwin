(in-package #:fs-backend-darwin)

;;; Contract stubs: every call of %R4B2-PENDING is replaced by the
;;; implementation, and then %R4B2-PENDING itself is deleted.
(defun %r4b2-pending (what)
  (error "R4b-2 not implemented yet: ~A" what))

;;; --- canonical paths --------------------------------------------------------------
;;;
;;; FSEvents reports absolute, canonical paths: /var, /tmp and /etc come back
;;; as /private/var, /private/tmp, /private/etc, and on a case-insensitive
;;; volume the case of a path component is the case on disk, not the case
;;; the caller spelled. The journal maps each event path to a path relative
;;; to its root with FSEVENTS-RELATIVE-PATH, against the root's truename.

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
  (declare (ignore root path case-sensitive))
  (%r4b2-pending 'fsevents-relative-path))

(defun volume-case-sensitive-p (directory)
  "True when the volume holding the existing directory DIRECTORY (a
pathname or native namestring) compares names case-sensitively
(pathconf _PC_CASE_SENSITIVE on macOS). T off macOS."
  (declare (ignore directory))
  (%r4b2-pending 'volume-case-sensitive-p))
