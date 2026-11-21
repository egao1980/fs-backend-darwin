(in-package #:fs-backend-darwin)

;;; R4b-2: the FSEvents FFI (CoreServices) and CoreFoundation, through CFFI.
;;;
;;; The frameworks are system libraries (in the dyld shared cache), so there
;;; is no native overlay: they are opened at ASDF load time by absolute path
;;; (AGENTS.md CFFI rule), on macOS only. Elsewhere this file defines the
;;; constants and nothing foreign.
;;;
;;; Given: the constants below and the library loading. The foreign
;;; functions, the callback and the CF helpers are the implementation's
;;; (CFFI DEFCFUN / DEFCALLBACK, under #+darwin).

;;; --- FSEventStreamCreateFlags (FSEvents.h) ---------------------------------------

(defconstant +create-flag-use-cf-types+ #x00000001)
(defconstant +create-flag-no-defer+ #x00000002)
(defconstant +create-flag-watch-root+ #x00000004)
(defconstant +create-flag-ignore-self+ #x00000008)
(defconstant +create-flag-file-events+ #x00000010)

(defconstant +fsevents-create-flags+
  (logior +create-flag-no-defer+ +create-flag-watch-root+ +create-flag-file-events+)
  "The flags every journal's stream is created with: per-file events, the
first event of a batch delivered at once, and RootChanged when the watched
root (or an ancestor) is moved or deleted.")

;;; --- FSEventStreamEventFlags (FSEvents.h) ------------------------------------------

(defconstant +event-flag-none+ #x00000000)
(defconstant +event-flag-must-scan-sub-dirs+ #x00000001)
(defconstant +event-flag-user-dropped+ #x00000002)
(defconstant +event-flag-kernel-dropped+ #x00000004)
(defconstant +event-flag-event-ids-wrapped+ #x00000008)
(defconstant +event-flag-history-done+ #x00000010)
(defconstant +event-flag-root-changed+ #x00000020)
(defconstant +event-flag-mount+ #x00000040)
(defconstant +event-flag-unmount+ #x00000080)
(defconstant +event-flag-item-created+ #x00000100)
(defconstant +event-flag-item-removed+ #x00000200)
(defconstant +event-flag-item-inode-meta-mod+ #x00000400)
(defconstant +event-flag-item-renamed+ #x00000800)
(defconstant +event-flag-item-modified+ #x00001000)
(defconstant +event-flag-item-finder-info-mod+ #x00002000)
(defconstant +event-flag-item-change-owner+ #x00004000)
(defconstant +event-flag-item-xattr-mod+ #x00008000)
(defconstant +event-flag-item-is-file+ #x00010000)
(defconstant +event-flag-item-is-dir+ #x00020000)
(defconstant +event-flag-item-is-symlink+ #x00040000)
(defconstant +event-flag-own-event+ #x00080000)
(defconstant +event-flag-item-is-hardlink+ #x00100000)
(defconstant +event-flag-item-is-last-hardlink+ #x00200000)
(defconstant +event-flag-item-cloned+ #x00400000)

(defconstant +incomplete-event-flags+
  (logior +event-flag-must-scan-sub-dirs+ +event-flag-user-dropped+
          +event-flag-kernel-dropped+ +event-flag-event-ids-wrapped+
          +event-flag-root-changed+ +event-flag-mount+ +event-flag-unmount+)
  "An event with any of these flags makes the next drain incomplete
(COMPLETE-P NIL): events were coalesced or lost, the root moved, or a volume
appeared or vanished under the root.")

;;; --- libraries -------------------------------------------------------------------

#+darwin
(progn
  (cffi:define-foreign-library core-foundation
    (:darwin "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"))
  (cffi:define-foreign-library core-services
    (:darwin "/System/Library/Frameworks/CoreServices.framework/CoreServices"))
  (cffi:use-foreign-library core-foundation)
  (cffi:use-foreign-library core-services))

;;; --- foreign functions (macOS) ------------------------------------------------------
;;;
;;; Only what the journal needs. Global CF values (kCFRunLoopDefaultMode,
;;; kCFTypeArrayCallBacks) are read when a journal is made, never at load
;;; time, so a saved image does not keep stale addresses.

(defconstant +event-id-since-now+ #xFFFFFFFFFFFFFFFF
  "kFSEventStreamEventIdSinceNow: a new stream reports events from now on.")

(defconstant +cf-string-encoding-utf8+ #x08000100
  "kCFStringEncodingUTF8.")

(defconstant +pc-case-sensitive+ 11
  "_PC_CASE_SENSITIVE (<sys/unistd.h>, Darwin), the pathconf name.")

#+darwin
(progn
  ;; CoreFoundation
  (cffi:defcfun ("CFStringCreateWithCString" %cf-string-create) :pointer
    (allocator :pointer) (cstring :string) (encoding :uint32))
  (cffi:defcfun ("CFArrayCreate" %cf-array-create) :pointer
    (allocator :pointer) (items :pointer) (n-items :long) (callbacks :pointer))
  (cffi:defcfun ("CFRelease" %cf-release) :void
    (cf :pointer))
  (cffi:defcfun ("CFRunLoopGetCurrent" %cf-run-loop-get-current) :pointer)
  (cffi:defcfun ("CFRunLoopRun" %cf-run-loop-run) :void)
  (cffi:defcfun ("CFRunLoopStop" %cf-run-loop-stop) :void
    (run-loop :pointer))

  (defun %cf-type-array-callbacks ()
    "&kCFTypeArrayCallBacks."
    (cffi:foreign-symbol-pointer "kCFTypeArrayCallBacks" :library 'core-foundation))

  (defun %cf-run-loop-default-mode ()
    "The CFStringRef kCFRunLoopDefaultMode."
    (cffi:mem-ref (cffi:foreign-symbol-pointer "kCFRunLoopDefaultMode" :library 'core-foundation)
                  :pointer))

  ;; CoreServices (FSEvents)
  (cffi:defcstruct fsevent-stream-context
    (version :long)                     ; CFIndex, 0
    (info :pointer)                     ; the journal's registry id
    (retain :pointer)
    (release :pointer)
    (copy-description :pointer))

  (cffi:defcfun ("FSEventStreamCreate" %fsevent-stream-create) :pointer
    (allocator :pointer) (callback :pointer) (context :pointer)
    (paths-to-watch :pointer) (since-when :uint64) (latency :double) (flags :uint32))
  (cffi:defcfun ("FSEventStreamScheduleWithRunLoop" %fsevent-stream-schedule-with-run-loop) :void
    (stream :pointer) (run-loop :pointer) (run-loop-mode :pointer))
  (cffi:defcfun ("FSEventStreamStart" %fsevent-stream-start) :uint8 ; Boolean
    (stream :pointer))
  (cffi:defcfun ("FSEventStreamFlushSync" %fsevent-stream-flush-sync) :void
    (stream :pointer))
  (cffi:defcfun ("FSEventStreamStop" %fsevent-stream-stop) :void
    (stream :pointer))
  (cffi:defcfun ("FSEventStreamInvalidate" %fsevent-stream-invalidate) :void
    (stream :pointer))
  (cffi:defcfun ("FSEventStreamRelease" %fsevent-stream-release) :void
    (stream :pointer))

  ;; libc
  (cffi:defcfun ("pathconf" %pathconf) :long
    (path :string) (name :int)))

(defmacro with-foreign-float-traps-masked (&body body)
  "Run BODY, which calls into CoreFoundation / FSEvents, with IEEE float
traps masked: C code is entitled to produce inexact or infinite results
(CFRunLoopRun's 1e10 s timeout, the latency arithmetic) that SBCL's
default enabled traps would turn into Lisp errors."
  #+sbcl `(sb-int:with-float-traps-masked (:invalid :inexact :overflow :divide-by-zero) ,@body)
  #-sbcl `(progn ,@body))
