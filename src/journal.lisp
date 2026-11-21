(in-package #:fs-backend-darwin)

;;; R4b-2: the :FSEVENTS journal.
;;;
;;; One FSEventStream per journal, over the root's truename, created with
;;; +FSEVENTS-CREATE-FLAGS+ and kFSEventStreamEventIdSinceNow. The stream is
;;; scheduled on the run loop of a Lisp thread the journal owns (made with
;;; bordeaux-threads), so the FSEvents callback only ever runs on a Lisp
;;; thread. The callback maps each event path to a root-relative path
;;; (FSEVENTS-RELATIVE-PATH) and adds it, under a lock, to the journal's
;;; pending set; an event with any of +INCOMPLETE-EVENT-FLAGS+ marks the
;;; journal incomplete instead. JOURNAL-DRAIN flushes the stream
;;; (FSEventStreamFlushSync), then takes and clears the pending set and the
;;; incomplete mark: (values paths t), or (values nil nil) when marked.
;;; JOURNAL-CLOSE stops and invalidates the stream, releases it, stops the
;;; run loop and joins the thread.

(define-condition fsevents-error (sp:journal-error)
  ((operation :initarg :operation :reader fsevents-error-operation :initform nil
              :documentation "The FSEvents / CoreFoundation call that failed, a string."))
  (:documentation "FSEvents refused a stream: create, start or schedule failed.")
  (:report (lambda (c s)
             (format s "FSEvents ~@[~A ~]failed" (fsevents-error-operation c)))))

(defvar *fsevents-latency* 0.01d0
  "Latency in seconds given to FSEventStreamCreate for new journals (a
non-negative real). A drain never waits for it: it flushes the stream.")

(defconstant +fsevents-rank+ 100
  "The rank :FSEVENTS registers with.")

(defclass fsevents-journal (sp:journal)
  ((thread :initform nil :accessor %fsevents-journal-thread
           :documentation "The Lisp thread whose run loop the stream is scheduled on; NIL once closed.")
   (stream :initform nil :accessor %fsevents-journal-stream
           :documentation "The FSEventStreamRef (a foreign pointer); NIL once closed.")
   ;; Events: the pending set and the incomplete mark, under LOCK.
   (lock :initform (bt2:make-lock :name "fsevents-journal") :reader %lock
         :documentation "Guards PENDING, INCOMPLETE and the run-loop state slots. Never held across a blocking foreign call.")
   (pending :initform (make-hash-table :test #'equal) :reader %pending
            :documentation "Root-relative paths reported since the last drain (keys).")
   (incomplete :initform nil :accessor %incomplete
               :documentation "True when an event since the last drain carried +INCOMPLETE-EVENT-FLAGS+.")
   (root-name :initform nil :accessor %root-name
              :documentation "The root's truename as a native namestring, without the trailing \"/\".")
   (case-sensitive :initform t :accessor %case-sensitive
                   :documentation "(VOLUME-CASE-SENSITIVE-P root), used to match event paths.")
   (id :initform nil :accessor %id
       :documentation "Key in *JOURNALS*, passed to FSEvents as the context info; NIL when not registered.")
   ;; The run-loop thread, under LOCK.
   (cv :initform (bt2:make-condition-variable :name "fsevents-journal") :reader %cv
       :documentation "Start handshake and close request.")
   (state :initform :starting :accessor %state
          :documentation ":STARTING, :RUNNING (inside the run loop), :FAILED or :EXITING.")
   (failure :initform nil :accessor %failure
            :documentation "The FSEvents call that failed on the run-loop thread, a string.")
   (run-loop :initform nil :accessor %run-loop
             :documentation "The CFRunLoopRef of THREAD; only used while STATE is :RUNNING.")
   (close-requested :initform nil :accessor %close-requested)
   (dead :initform nil :accessor %dead
         :documentation "True when the run loop returned on its own: every later drain is incomplete.")
   (ops-lock :initform (bt2:make-lock :name "fsevents-journal-ops") :reader %ops-lock
             :documentation "Serializes JOURNAL-DRAIN's flush with JOURNAL-CLOSE's teardown."))
  (:default-initargs :mechanism :fsevents)
  (:documentation "A change journal fed by an FSEvents stream. Made by
MAKE-FSEVENTS-JOURNAL (FS-WATCH ... :MECHANISM :FSEVENTS). The
implementation adds the slots it needs."))

(defun fsevents-journal-thread (journal)
  "The thread running JOURNAL's run loop, or NIL once JOURNAL is closed."
  (%fsevents-journal-thread journal))

(defun fsevents-journal-stream (journal)
  "JOURNAL's FSEventStreamRef, or NIL once JOURNAL is closed."
  (%fsevents-journal-stream journal))

(defun fsevents-available-p (fs directory)
  "The AVAILABLE-P probe of :FSEVENTS: true on macOS for a local filesystem."
  (declare (ignorable fs directory))
  #+darwin (typep fs 'sp:local-filesystem)
  #-darwin nil)


;;; --- registry: callback info -> journal, and the stream count -------------------------
;;;
;;; FSEvents hands the callback the context's info pointer. It carries an
;;; integer id (never a Lisp object address, which the GC may move); the
;;; callback looks the journal up here. A journal is registered from just
;;; before its stream starts until JOURNAL-CLOSE, so a late callback after
;;; close finds nothing and drops its events. Registered journals are the
;;; streams this image holds open.

(defvar *journals-lock* (bt2:make-lock :name "fsevents-journals"))
(defvar *journals* (make-hash-table) "id -> open FSEVENTS-JOURNAL.")
(defvar *next-journal-id* 0)

(defun %register-journal (journal)
  (bt2:with-lock-held (*journals-lock*)
    (let ((id (incf *next-journal-id*)))  ; from 1: info is never NULL
      (setf (gethash id *journals*) journal
            (%id journal) id))))

(defun %unregister-journal (journal)
  (bt2:with-lock-held (*journals-lock*)
    (let ((id (%id journal)))
      (when id
        (remhash id *journals*)
        (setf (%id journal) nil)))))

(defun %find-journal (id)
  (bt2:with-lock-held (*journals-lock*)
    (values (gethash id *journals*))))

(defun fsevents-stream-count ()
  "Number of FSEvents streams this image holds open (journals made and not
yet closed)."
  (bt2:with-lock-held (*journals-lock*)
    (hash-table-count *journals*)))

;;; --- events: the callback's code, shared with the test hook --------------------------

(defun %record-events (journal paths flags)
  "Add PATHS (absolute native namestrings) with their FSEvents FLAGS to
JOURNAL: an event with any of +INCOMPLETE-EVENT-FLAGS+ sets the incomplete
mark; another one adds its root-relative path to the pending set (the root
itself as \"\", which the drain's :AROUND turns into a rescan); paths
outside the root are dropped."
  (let ((root (%root-name journal))
        (case-sensitive (%case-sensitive journal))
        (relative '())
        (incomplete nil))
    (loop for path in paths
          for flag in flags
          do (if (logtest flag +incomplete-event-flags+)
                 (setf incomplete t)
                 (let ((rel (fsevents-relative-path root path :case-sensitive case-sensitive)))
                   (when rel (push rel relative)))))
    (bt2:with-lock-held ((%lock journal))
      (when incomplete
        (setf (%incomplete journal) t))
      (dolist (rel relative)
        (setf (gethash rel (%pending journal)) t))))
  nil)

(defun %mark-incomplete (journal)
  (bt2:with-lock-held ((%lock journal))
    (setf (%incomplete journal) t)))

(defun fsevents-journal-inject (journal paths flags)
  "Test hook: deliver events to the open JOURNAL through the same code the
FSEvents callback runs, as if the stream had reported them. PATHS is a list
of absolute native namestrings, FLAGS an equally long list of
FSEventStreamEventFlags integers. Returns NIL. A closed JOURNAL signals
CL-STACK-PATHLIB:JOURNAL-ERROR."
  (check-type journal fsevents-journal)
  (unless (sp:journal-open-p journal)
    (error 'sp:journal-error :journal journal :message "inject into a closed FSEvents journal"))
  (assert (= (length paths) (length flags)) (paths flags)
          "~S paths but ~S flags" (length paths) (length flags))
  (%record-events journal paths flags))

#+darwin
(cffi:defcallback %fsevents-callback :void
    ((stream :pointer) (info :pointer) (n-events :size)
     (paths :pointer) (flags :pointer) (ids :pointer))
  (declare (ignore stream ids))
  (let ((journal (%find-journal (cffi:pointer-address info))))
    (when journal
      ;; This frame is entered from C: no condition may unwind out of it.
      ;; An event that cannot be recorded (an undecodable name, say) is not
      ;; dropped silently either: the next drain says "rescan".
      (handler-case
          (%record-events journal
                          (loop for i below n-events
                                collect (cffi:foreign-string-to-lisp
                                         (cffi:mem-aref paths :pointer i) :encoding :utf-8))
                          (loop for i below n-events
                                collect (cffi:mem-aref flags :uint32 i)))
        (error ()
          (%mark-incomplete journal))))))

;;; --- the stream and its run-loop thread ---------------------------------------------------

#+darwin
(defun %create-stream (journal)
  "A new, unscheduled FSEventStreamRef over JOURNAL's root, or FSEVENTS-ERROR."
  (let ((root (%root-name journal))
        (string (cffi:null-pointer))
        (array (cffi:null-pointer)))
    (flet ((fail (operation)
             (error 'fsevents-error :journal journal :operation operation
                                    :message (format nil "watching ~A" root))))
      (unwind-protect
           (cffi:with-foreign-objects ((items :pointer)
                                       (context '(:struct fsevent-stream-context)))
             (setf string (%cf-string-create (cffi:null-pointer) root +cf-string-encoding-utf8+))
             (when (cffi:null-pointer-p string) (fail "CFStringCreateWithCString"))
             (setf (cffi:mem-ref items :pointer) string
                   array (%cf-array-create (cffi:null-pointer) items 1 (%cf-type-array-callbacks)))
             (when (cffi:null-pointer-p array) (fail "CFArrayCreate"))
             (setf (cffi:foreign-slot-value context '(:struct fsevent-stream-context) 'version) 0
                   (cffi:foreign-slot-value context '(:struct fsevent-stream-context) 'info)
                   (cffi:make-pointer (%id journal))
                   (cffi:foreign-slot-value context '(:struct fsevent-stream-context) 'retain)
                   (cffi:null-pointer)
                   (cffi:foreign-slot-value context '(:struct fsevent-stream-context) 'release)
                   (cffi:null-pointer)
                   (cffi:foreign-slot-value context '(:struct fsevent-stream-context) 'copy-description)
                   (cffi:null-pointer))
             ;; FSEvents copies the context and the paths.
             (let ((stream (with-foreign-float-traps-masked
                             (%fsevent-stream-create (cffi:null-pointer)
                                                     (cffi:callback %fsevents-callback)
                                                     context array +event-id-since-now+
                                                     (coerce *fsevents-latency* 'double-float)
                                                     +fsevents-create-flags+))))
               (when (cffi:null-pointer-p stream) (fail "FSEventStreamCreate"))
               stream))
        (unless (cffi:null-pointer-p array) (%cf-release array))
        (unless (cffi:null-pointer-p string) (%cf-release string))))))

(defun %set-state (journal state &optional failure)
  "Under JOURNAL's lock already held."
  (setf (%state journal) state)
  (when failure (setf (%failure journal) failure))
  (bt2:condition-broadcast (%cv journal)))

#+darwin
(defun %run-loop-thread (journal stream)
  "The body of JOURNAL's thread: schedule and start STREAM on this
thread's run loop, run it until JOURNAL-CLOSE asks, then stop, invalidate
and release STREAM here, where no callback can be in flight."
  (let ((lock (%lock journal))
        (started nil))
    (with-foreign-float-traps-masked
      (unwind-protect
           (let ((run-loop (%cf-run-loop-get-current)))
             (%fsevent-stream-schedule-with-run-loop stream run-loop (%cf-run-loop-default-mode))
             (cond
               ((zerop (logand #xff (%fsevent-stream-start stream)))
                (bt2:with-lock-held (lock)
                  (%set-state journal :failed "FSEventStreamStart")))
               (t
                (setf started t)
                (bt2:with-lock-held (lock)
                  (setf (%run-loop journal) run-loop)
                  (%set-state journal :running))
                ;; CFRunLoopRun returns on CFRunLoopStop. A stop sent before
                ;; the run is entered is lost, so the closer repeats it while
                ;; STATE is :RUNNING; a return without a request means the
                ;; stream has gone (every drain is then incomplete) and the
                ;; thread waits for JOURNAL-CLOSE.
                (loop
                  (%cf-run-loop-run)
                  (bt2:with-lock-held (lock)
                    (unless (%close-requested journal)
                      (setf (%dead journal) t)
                      (loop until (%close-requested journal)
                            do (bt2:condition-wait (%cv journal) lock)))
                    (setf (%run-loop journal) nil)
                    (%set-state journal :exiting)
                    (return))))))
        ;; Teardown on the thread the stream is scheduled on.
        (when started
          (%fsevent-stream-stop stream))
        (%fsevent-stream-invalidate stream)
        (%fsevent-stream-release stream)
        (bt2:with-lock-held (lock)
          (setf (%run-loop journal) nil)
          (unless (member (%state journal) '(:failed :exiting))
            (%set-state journal :failed "FSEventStreamScheduleWithRunLoop")))))))

#+darwin
(defun %stop-run-loop-thread (journal)
  "Ask JOURNAL's run-loop thread to tear its stream down and exit, and join
it (unless this is that thread, which then tears down once its callback
returns)."
  (let ((thread (%fsevents-journal-thread journal))
        (lock (%lock journal)))
    (when thread
      (bt2:with-lock-held (lock)
        (setf (%close-requested journal) t)
        (bt2:condition-broadcast (%cv journal)))
      (cond
        ((eq thread (bt2:current-thread))
         (bt2:with-lock-held (lock)
           (when (eq (%state journal) :running)
             (%cf-run-loop-stop (%run-loop journal)))))
        (t
         ;; The run loop stays valid while STATE is :RUNNING (its thread
         ;; sets :EXITING under LOCK before it leaves).
         (loop (bt2:with-lock-held (lock)
                 (unless (eq (%state journal) :running) (return))
                 (%cf-run-loop-stop (%run-loop journal)))
               (sleep 0.002))
         (bt2:join-thread thread))))))

(defparameter *fsevents-minimum-settle* 0.05
  "Seconds a drain lets fseventsd catch up with the kernel, at least, whatever
its :SETTLE. FSEventStreamFlushSync only delivers the events fseventsd has
already read from the kernel, and it reads them some milliseconds (about 10
on macOS 15) after the write returned: a lone flush would report a write
one drain late.")

#+darwin
(defun %flush-stream (journal settle)
  "Flush JOURNAL's stream repeatedly for SETTLE seconds (at least
*FSEVENTS-MINIMUM-SETTLE*), so that events still on their way from the
kernel to fseventsd are delivered too. (Measured: a flush every few
milliseconds delivers them; one late flush after a sleep does not.)"
  (let ((stream (%fsevents-journal-stream journal)))
    (when stream
      (let ((deadline (+ (get-internal-real-time)
                         (ceiling (* (max settle *fsevents-minimum-settle*)
                                     internal-time-units-per-second)))))
        (loop
          (with-foreign-float-traps-masked (%fsevent-stream-flush-sync stream))
          (when (>= (get-internal-real-time) deadline) (return))
          (sleep 0.002))))))

(defun make-fsevents-journal (fs directory matcher)
  "The constructor registered for :FSEVENTS: an open FSEVENTS-JOURNAL over
the directory pathname DIRECTORY on the local filesystem FS with the ignore
MATCHER (or NIL). The stream watches DIRECTORY's truename; events from
before this returns may be reported or not, every event after it is.
FSEvents failures signal FSEVENTS-ERROR, with nothing left running."
  #-darwin
  (progn fs matcher
         (error 'fsevents-error :operation "FSEventStreamCreate"
                                :message (format nil "FSEvents is macOS only: ~A" directory)))
  #+darwin
  (let* ((truename (truename directory))
         (native (uiop:native-namestring truename))
         (journal (make-instance 'fsevents-journal :filesystem fs :root directory :ignore matcher))
         (stream nil)
         (thread nil)
         (ok nil))
    (setf (%root-name journal) (if (and (> (length native) 1)
                                        (char= #\/ (char native (1- (length native)))))
                                   (subseq native 0 (1- (length native)))
                                   native)
          (%case-sensitive journal) (volume-case-sensitive-p native))
    (%register-journal journal)
    (unwind-protect
         (progn
           (setf stream (%create-stream journal))
           (setf thread (bt2:make-thread (lambda () (%run-loop-thread journal stream))
                                         :name (format nil "fsevents ~A" (%root-name journal))))
           ;; From here the thread owns STREAM.
           (bt2:with-lock-held ((%lock journal))
             (loop while (eq (%state journal) :starting)
                   do (bt2:condition-wait (%cv journal) (%lock journal))))
           (unless (eq (%state journal) :running)
             (bt2:join-thread thread)
             (error 'fsevents-error :journal journal :operation (%failure journal)
                                    :message (format nil "watching ~A" (%root-name journal))))
           (setf (%fsevents-journal-stream journal) stream
                 (%fsevents-journal-thread journal) thread)
           ;; Writes made just before FS-WATCH may still be on their way to
           ;; fseventsd and would come in as new events: let them arrive
           ;; and drop them, so the first drain reports what follows.
           (%flush-stream journal 0)
           (bt2:with-lock-held ((%lock journal))
             (clrhash (%pending journal))
             (setf (%incomplete journal) nil))
           (setf ok t)
           journal)
      (unless ok
        (%unregister-journal journal)
        (cond ((null thread)
               ;; Never scheduled: only released.
               (when stream (%fsevent-stream-release stream)))
              ((bt2:thread-alive-p thread)
               ;; Unwound while it runs (an interrupt in the wait).
               (setf (%fsevents-journal-thread journal) thread)
               (%stop-run-loop-thread journal)))
        (setf (%fsevents-journal-thread journal) nil
              (%fsevents-journal-stream journal) nil)))))

;;; --- the protocol ---------------------------------------------------------------------

(defmethod sp:journal-drain ((journal fsevents-journal) &key settle)
  ;; FlushSync is synchronous: when it returns, the callback has run for
  ;; every event fseventsd had. The flush runs without LOCK (the callback
  ;; takes it, on the run-loop thread); OPS-LOCK keeps JOURNAL-CLOSE from
  ;; releasing the stream under it.
  #-darwin (declare (ignore settle))
  (bt2:with-lock-held ((%ops-lock journal))
    #+darwin (%flush-stream journal settle)
    ;; WatchRoot reports a moved or deleted root as RootChanged; a root that
    ;; is gone is a rescan however the event arrives.
    (let ((root-gone (not (uiop:directory-exists-p
                           (uiop:parse-native-namestring (%root-name journal)
                                                         :ensure-directory t)))))
      (bt2:with-lock-held ((%lock journal))
        (let ((incomplete (or (%incomplete journal) (%dead journal) root-gone))
              (paths (loop for path being the hash-keys of (%pending journal) collect path)))
          (clrhash (%pending journal))
          (setf (%incomplete journal) nil)
          (if incomplete
              (values nil nil)
              (values paths t)))))))

(defmethod sp:journal-close ((journal fsevents-journal))
  ;; The protocol's :AROUND has already marked JOURNAL closed and runs this
  ;; once. Nothing here touches the root, which may be gone.
  (bt2:with-lock-held ((%ops-lock journal))
    (unwind-protect
         #+darwin (%stop-run-loop-thread journal)
         #-darwin nil
      (%unregister-journal journal)
      (setf (%fsevents-journal-stream journal) nil
            (%fsevents-journal-thread journal) nil)))
  nil)
