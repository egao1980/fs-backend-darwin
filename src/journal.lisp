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
           :documentation "The FSEventStreamRef (a foreign pointer); NIL once closed."))
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

(defun make-fsevents-journal (fs directory matcher)
  "The constructor registered for :FSEVENTS: an open FSEVENTS-JOURNAL over
the directory pathname DIRECTORY on the local filesystem FS with the ignore
MATCHER (or NIL). The stream watches DIRECTORY's truename; events from
before this returns may be reported or not, every event after it is.
FSEvents failures signal FSEVENTS-ERROR, with nothing left running."
  (declare (ignore fs directory matcher))
  (%r4b2-pending 'make-fsevents-journal))

(defun fsevents-stream-count ()
  "Number of FSEvents streams this image holds open (journals made and not
yet closed)."
  (%r4b2-pending 'fsevents-stream-count))

(defun fsevents-journal-inject (journal paths flags)
  "Test hook: deliver events to the open JOURNAL through the same code the
FSEvents callback runs, as if the stream had reported them. PATHS is a list
of absolute native namestrings, FLAGS an equally long list of
FSEventStreamEventFlags integers. Returns NIL. A closed JOURNAL signals
CL-STACK-PATHLIB:JOURNAL-ERROR."
  (declare (ignore journal paths flags))
  (%r4b2-pending 'fsevents-journal-inject))

(defmethod sp:journal-drain ((journal fsevents-journal) &key settle)
  (declare (ignore settle))
  (%r4b2-pending 'journal-drain))

(defmethod sp:journal-close ((journal fsevents-journal))
  (%r4b2-pending 'journal-close))
