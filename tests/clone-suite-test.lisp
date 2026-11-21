(in-package #:fs-backend-darwin/tests)

;;; The R4c law (cl-stack-pathlib/clone-suite): a tree, its metadata and
;;; FS-AREA-CHANGES made with :clonefile equal those made with :copy, and a
;;; clone is independent of its source.

(defun suite-ok (failures steps expected)
  (ok (null failures) (format nil ":clonefile keeps the clone laws: ~S" failures))
  (ok (equal expected steps) (format nil "every applicable step ran: ~S" steps)))

(deftest-clone-macos clonefile-clone-suite-temp
  ;; The temp directory (the APFS Data volume).
  (multiple-value-bind (failures steps) (run-clone-suite :clonefile)
    (suite-ok failures steps (clone-suite-steps :backend :local :mechanism :clonefile))
    (ok (member :independence steps))
    (ok (member :equivalence steps))
    (ok (member :sparse steps))))

(deftest-clone-macos clonefile-clone-suite-images
  ;; In an APFS image, with an HFS+ image as the other volume: every step,
  ;; :cross-volume included.
  (with-disk-image (apfs :fs "APFS" :size "256m")
    (with-disk-image (hfs :fs "HFS+" :size "160m")
      (multiple-value-bind (failures steps)
          (run-clone-suite :clonefile :directory apfs :other-volume hfs)
        (suite-ok failures steps
                  (clone-suite-steps :backend :local :mechanism :clonefile :other-volume t))
        (ok (member :cross-volume steps))))))

(deftest-clone-macos clonefile-clone-suite-apfs-to-apfs
  ;; From the temp volume to an APFS image: two APFS volumes, no clone.
  (with-disk-image (apfs :fs "APFS" :size "160m")
    (multiple-value-bind (failures steps) (run-clone-suite :clonefile :other-volume apfs)
      (suite-ok failures steps
                (clone-suite-steps :backend :local :mechanism :clonefile :other-volume t))
      (ok (member :cross-volume steps)))))
