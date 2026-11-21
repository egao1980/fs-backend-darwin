(in-package #:fs-backend-darwin/tests)

;;; The R4b law (cl-stack-pathlib/journal-suite): an area with an :fsevents
;;; journal gives exactly the full rescan's changes after every corpus step.

(deftest-parametrize fsevents-journal-suite
    ((settle) :ids ("default-settle" "settle-0") (0.05) (0))
  (if (not (macos-p))
      (skip +skip-note+)
      (multiple-value-bind (failures steps) (run-journal-suite :fsevents :settle settle)
        (ok (null failures) (format nil ":fsevents keeps the law: ~S" failures))
        (ok (equal (journal-suite-steps :backend :local) steps) "every applicable step ran")
        (ok (member :case-only-rename steps))
        (ok (member :burst steps))
        (ok (member :child-process steps)))))

(deftest-macos fsevents-journal-suite-auto
  ;; :auto picks :fsevents (it is the best available mechanism on macOS).
  (ok (null (run-journal-suite :auto))))
