(defsystem "fs-backend-darwin"
  :version "0.2.0"
  :description "macOS FSEvents change journals (:fsevents) and APFS clones (:clonefile) for cl-stack-pathlib"
  :author "egao1980"
  :license "MIT"
  :depends-on ((:version "cl-stack-pathlib" "0.10.0") "cffi" "bordeaux-threads" "uiop")
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "ffi")            ; CoreFoundation + CoreServices, loaded here (macOS)
               (:file "paths")
               (:file "journal")
               (:file "clone")          ; clonefile(2), getattrlist(2), stat(2) (libSystem)
               (:file "register"))      ; register :fsevents and :clonefile at load
  :in-order-to ((test-op (test-op "fs-backend-darwin/tests"))))

(defsystem "fs-backend-darwin/tests"
  :depends-on ("fs-backend-darwin" "cl-stack-pathlib/journal-suite" "cl-stack-pathlib/clone-suite"
               "cffi" "bordeaux-threads" (:feature :sbcl "sb-posix") "rove")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "support")
               (:file "registry-test")
               (:file "paths-test")
               (:file "journal-test")
               (:file "suite-test")
               (:file "clone-registry-test")
               (:file "clone-test")
               (:file "clone-suite-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
