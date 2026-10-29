;;; reopen-closed-buffer-test-helper.el --- shared setup for reopen-closed-buffer ERT -*- lexical-binding: t; -*-

;;; Commentary:
;; Load paths (the package, the engine from TERRA_EMACS_DIR, the exporter
;; from TERRA_EMACS_CAPTURE_DIR, each defaulting to a sibling checkout,
;; and the pinned test packages for eat and persp-mode when present) and
;; the resets every suite uses.  Batch Emacs has one 80x25 frame; tab-bar
;; works there, and so does persp-mode.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defconst rcb-test-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "This directory.")

(add-to-list 'load-path (expand-file-name ".." rcb-test-dir))

(dolist (spec '(("TERRA_EMACS_DIR" . "../../terra-emacs.el")
                ("TERRA_EMACS_CAPTURE_DIR" . "../../terra-emacs-capture.el")))
  (add-to-list 'load-path (expand-file-name (or (getenv (car spec))
                                                (expand-file-name (cdr spec) rcb-test-dir)))))

(defconst rcb-test-packages
  (or (getenv "TERRA_EMACS_TEST_PACKAGES") "/opt/emacs-test-packages")
  "Where the pinned third-party test packages live.")

(dolist (dir (append (list (expand-file-name "eat-0.9.4" rcb-test-packages)
                           (expand-file-name "external/pkg-persp-mode" rcb-test-packages))
                     (split-string (or (getenv "TERRA_EMACS_TEST_LOAD_PATH") "") ":" t)))
  (when (file-directory-p dir) (add-to-list 'load-path (expand-file-name dir) t)))

(require 'reopen-closed-buffer)

(defun rcb-test-have (feature)
  "Non-nil when FEATURE loads."
  (ignore-errors (require feature) t))

(defun rcb-test-tmpdir ()
  "A fresh temporary directory (with a trailing slash)."
  (file-name-as-directory (make-temp-file "reopen-closed-buffer-test" t)))

(defun rcb-test-file (name &optional dir)
  "A fresh file NAME (in DIR, else a new temp dir) with three lines; its path."
  (let ((f (expand-file-name name (or dir (rcb-test-tmpdir)))))
    (with-temp-file f (insert "line one\nline two\nline three\n"))
    f))

(defun rcb-test-reset-tabs ()
  "Leave one tab, named \"main\", showing *scratch* in one window."
  (require 'tab-bar)
  (while (> (length (funcall tab-bar-tabs-function)) 1)
    (tab-bar-close-tab 2))
  (tab-bar-rename-tab "main")
  (delete-other-windows)
  (switch-to-buffer "*scratch*"))

(defun rcb-test-persp-on ()
  "Turn persp-mode on with no autosave/resume; kill every perspective."
  (require 'persp-mode)
  (setq persp-auto-resume-time -1 persp-auto-save-opt 0)
  (unless (bound-and-true-p persp-mode) (persp-mode 1))
  (dolist (name (persp-names))
    (unless (equal name persp-nil-name) (persp-kill name t)))
  (delete-other-windows)
  (switch-to-buffer "*scratch*"))

(defun rcb-test-persp-off ()
  "Turn persp-mode off."
  (when (bound-and-true-p persp-mode) (persp-mode -1)))

(defun rcb-test-kill (buffer)
  "Kill BUFFER and its process quietly."
  (when (buffer-live-p buffer)
    (let ((p (get-buffer-process buffer)))
      (when p (set-process-query-on-exit-flag p nil)))
    (let ((kill-buffer-query-functions nil)) (kill-buffer buffer))))

(defmacro rcb-test-with-ring (&rest body)
  "Run BODY with the mode on, an empty ring and a fresh ring file."
  (declare (indent 0))
  `(let ((reopen-closed-buffer-file (expand-file-name "ring.eld" (rcb-test-tmpdir)))
         (reopen-closed-buffer-ring nil)
         (reopen-closed-buffer--loaded nil)
         (terra-emacs-backend 'tab-bar))
     (reopen-closed-buffer-mode 1)
     (unwind-protect (progn ,@body)
       (reopen-closed-buffer-mode -1))))

(provide 'reopen-closed-buffer-test-helper)
;;; reopen-closed-buffer-test-helper.el ends here
