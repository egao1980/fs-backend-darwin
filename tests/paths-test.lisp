(in-package #:fs-backend-darwin/tests)

;;; FSEVENTS-RELATIVE-PATH is pure string work: it runs on every OS.

(deftest-parametrize fsevents-relative-path-table
    ((root path case-sensitive expected)
     :ids ("child" "nested" "root-itself" "root-itself-slash" "root-no-slash"
           "outside" "sibling-prefix" "parent" "trailing-slash"
           "private-var-event" "var-event-private-root" "private-tmp" "private-etc"
           "private-not-alias" "case-root-insensitive" "case-root-sensitive"
           "case-keeps-path-spelling" "case-private-insensitive" "unicode")
     ("/private/var/folders/x/T/w/" "/private/var/folders/x/T/w/a.txt" t "a.txt")
     ("/private/var/folders/x/T/w/" "/private/var/folders/x/T/w/src/d/e.lisp" t "src/d/e.lisp")
     ("/private/var/folders/x/T/w/" "/private/var/folders/x/T/w" t "")
     ("/private/var/folders/x/T/w/" "/private/var/folders/x/T/w/" t "")
     ("/Users/u/p" "/Users/u/p/a.txt" t "a.txt")
     ("/Users/u/p/" "/Users/u/q/a.txt" t nil)
     ("/Users/u/p/" "/Users/u/pq/a.txt" t nil)
     ("/Users/u/p/" "/Users/u" t nil)
     ("/Users/u/p/" "/Users/u/p/sub/" t "sub")
     ("/var/folders/x/T/w/" "/private/var/folders/x/T/w/a.txt" t "a.txt")
     ("/private/var/folders/x/T/w/" "/var/folders/x/T/w/a.txt" t "a.txt")
     ("/tmp/w/" "/private/tmp/w/k/k2.txt" t "k/k2.txt")
     ("/private/etc/w/" "/etc/w/f" t "f")
     ("/private/opt/w/" "/opt/w/f" t nil)
     ("/Users/u/Projects/" "/users/u/projects/README.md" nil "README.md")
     ("/Users/u/Projects/" "/users/u/projects/README.md" t nil)
     ("/users/u/projects/" "/Users/u/Projects/readme.md" nil "readme.md")
     ("/var/Folders/x/" "/private/var/folders/x/a" nil "a")
     ("/Users/u/p/" "/Users/u/p/é/ü.txt" t "é/ü.txt"))
  (ok (equal expected (fsevents-relative-path root path :case-sensitive case-sensitive))
      (format nil "~S in ~S (case-sensitive ~S) → ~S" path root case-sensitive expected)))

(deftest fsevents-relative-path-default-case-sensitive
  (ok (null (fsevents-relative-path "/Users/u/P/" "/Users/u/p/a")) "the default compares case")
  (ok (equal "a" (fsevents-relative-path "/Users/u/p/" "/Users/u/p/a"))))

(deftest-macos volume-case-sensitivity
  (with-work-dir (dir)
    ;; Probe the volume the way a user would: does "Probe" answer to "probe"?
    (put dir "Probe" "x")
    (let ((insensitive (and (probe-file (sub dir "probe")) t)))
      (ok (eq (not insensitive) (and (volume-case-sensitive-p dir) t))
          (format nil "volume-case-sensitive-p agrees with the probe (insensitive ~S)" insensitive))
      (ok (eq (and (volume-case-sensitive-p (native dir)) t)
              (and (volume-case-sensitive-p dir) t))
          "a namestring and a pathname give the same answer"))))
