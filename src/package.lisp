(defpackage #:fs-backend-darwin
  (:use #:cl)
  (:local-nicknames (#:sp #:cl-stack-pathlib))
  (:export
   ;; the mechanism
   #:+fsevents-rank+
   #:fsevents-available-p
   #:make-fsevents-journal
   #:fsevents-journal
   #:fsevents-journal-thread
   #:fsevents-journal-stream
   #:fsevents-stream-count
   #:*fsevents-latency*
   ;; paths
   #:fsevents-relative-path
   #:volume-case-sensitive-p
   ;; test hook
   #:fsevents-journal-inject
   ;; conditions
   #:fsevents-error
   #:fsevents-error-operation
   ;; FSEventStreamCreateFlags
   #:+create-flag-use-cf-types+
   #:+create-flag-no-defer+
   #:+create-flag-watch-root+
   #:+create-flag-ignore-self+
   #:+create-flag-file-events+
   #:+fsevents-create-flags+
   ;; FSEventStreamEventFlags
   #:+event-flag-none+
   #:+event-flag-must-scan-sub-dirs+
   #:+event-flag-user-dropped+
   #:+event-flag-kernel-dropped+
   #:+event-flag-event-ids-wrapped+
   #:+event-flag-history-done+
   #:+event-flag-root-changed+
   #:+event-flag-mount+
   #:+event-flag-unmount+
   #:+event-flag-item-created+
   #:+event-flag-item-removed+
   #:+event-flag-item-inode-meta-mod+
   #:+event-flag-item-renamed+
   #:+event-flag-item-modified+
   #:+event-flag-item-finder-info-mod+
   #:+event-flag-item-change-owner+
   #:+event-flag-item-xattr-mod+
   #:+event-flag-item-is-file+
   #:+event-flag-item-is-dir+
   #:+event-flag-item-is-symlink+
   #:+event-flag-own-event+
   #:+event-flag-item-is-hardlink+
   #:+event-flag-item-is-last-hardlink+
   #:+event-flag-item-cloned+
   #:+incomplete-event-flags+))
