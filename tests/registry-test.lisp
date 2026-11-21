(in-package #:fs-backend-darwin/tests)

;;; Registration at load time and availability (every OS).

(deftest fsevents-registered
  (let ((names (sp:watch-mechanisms)))
    (ok (member :fsevents names) "loading fs-backend-darwin registers :fsevents")
    (ok (< (position :fsevents names) (position :poll names)) ":fsevents ranks above :poll")
    (ok (= 100 +fsevents-rank+))
    (ok (eql (logior +create-flag-no-defer+ +create-flag-watch-root+ +create-flag-file-events+)
             +fsevents-create-flags+))
    (ok (= #x20 +event-flag-root-changed+))
    (ok (zerop (logand +incomplete-event-flags+
                       (logior +event-flag-item-created+ +event-flag-item-modified+
                               +event-flag-item-removed+ +event-flag-item-renamed+
                               +event-flag-history-done+)))
        "item events and HistoryDone never make a drain incomplete")))

(deftest fsevents-availability
  (let ((memory (sp:make-memory-filesystem)))
    (sp:with-filesystem (memory)
      (sp:mkdir "/w" :parents t))
    (ok (not (fsevents-available-p memory #p"/w/")) "never on a memory filesystem")
    (ok (not (member :fsevents (sp:watch-mechanisms memory #p"/w/"))))
    (ok (signals (sp:fs-watch memory #p"/w/" :mechanism :fsevents) 'sp:unsupported-operation)))
  (with-work-dir (dir)
    (if (macos-p)
        (progn
          (ok (fsevents-available-p *fs* dir))
          (ok (eq :fsevents (first (sp:watch-mechanisms *fs* dir)))
              ":auto picks :fsevents for a local directory on macOS"))
        (progn
          (ok (not (fsevents-available-p *fs* dir)) "unavailable off macOS")
          (ok (equal '(:poll) (sp:watch-mechanisms *fs* dir)))
          (ok (signals (sp:fs-watch *fs* dir :mechanism :fsevents) 'sp:unsupported-operation))
          (let ((j (sp:fs-watch *fs* dir)))
            (ok (eq :poll (sp:journal-mechanism j)) ":auto falls back to :poll off macOS")
            (sp:journal-close j))))))
