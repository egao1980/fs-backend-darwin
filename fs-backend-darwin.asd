(defsystem "fs-backend-darwin"
  :version "0.1.0"
  :description "macOS FSEvents change journals (:fsevents) for cl-stack-pathlib fs-watch"
  :author "egao1980"
  :license "MIT"
  :depends-on ((:version "cl-stack-pathlib" "0.9.0") "cffi" "bordeaux-threads" "uiop")
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "ffi")            ; CoreFoundation + CoreServices, loaded here (macOS)
               (:file "paths")
               (:file "journal")
               (:file "register"))      ; register-watch-mechanism :fsevents at load
  :in-order-to ((test-op (test-op "fs-backend-darwin/tests"))))

(defsystem "fs-backend-darwin/tests"
  :depends-on ("fs-backend-darwin" "cl-stack-pathlib/journal-suite" "bordeaux-threads" "rove")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "support")
               (:file "registry-test")
               (:file "paths-test")
               (:file "journal-test")
               (:file "suite-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
