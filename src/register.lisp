(in-package #:fs-backend-darwin)

;;; Loading the system registers :FSEVENTS on every OS; FSEVENTS-AVAILABLE-P
;;; keeps it out of (WATCH-MECHANISMS fs directory) off macOS and for
;;; non-local filesystems, so FS-WATCH :AUTO and FS-OPEN-AREA :JOURNAL :AUTO
;;; pick it exactly where it works. :POLL always ranks below it.

(sp:register-watch-mechanism :fsevents 'make-fsevents-journal
                             :rank +fsevents-rank+
                             :available-p 'fsevents-available-p)

;;; R4c-1: loading the system registers :CLONEFILE on every OS too;
;;; CLONEFILE-AVAILABLE-P keeps it out of (CLONE-MECHANISMS fs src dst) off
;;; macOS, off the local filesystem, on volumes without VOL_CAP_INT_CLONE and
;;; across volumes, so FS-CLONE-TREE :AUTO and FS-OPEN-AREA (default :AUTO)
;;; clone exactly where clonefile(2) works and copy elsewhere.

(sp:register-clone-mechanism :clonefile 'clonefile-file
                             :rank +clonefile-rank+
                             :available-p 'clonefile-available-p
                             :clone-tree 'clonefile-tree)
