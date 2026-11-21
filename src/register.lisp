(in-package #:fs-backend-darwin)

;;; Loading the system registers :FSEVENTS on every OS; FSEVENTS-AVAILABLE-P
;;; keeps it out of (WATCH-MECHANISMS fs directory) off macOS and for
;;; non-local filesystems, so FS-WATCH :AUTO and FS-OPEN-AREA :JOURNAL :AUTO
;;; pick it exactly where it works. :POLL always ranks below it.

(sp:register-watch-mechanism :fsevents 'make-fsevents-journal
                             :rank +fsevents-rank+
                             :available-p 'fsevents-available-p)
