;;; reopen-closed-buffer.el --- Reopen killed buffers, terminals and Claude sessions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (terra-emacs "0.2.0") (terra-emacs-capture "0.2.0"))
;; Keywords: convenience, frames
;; URL: https://github.com/davidawad/reopen-closed-buffer.el
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A browser's "reopen closed tab" for Emacs buffers.  With
;; `reopen-closed-buffer-mode' on, killing a buffer that terra-emacs
;; can bring back (a file, a dired, an eshell, an eat or vterm terminal
;; with its command, a Claude Code session by id, anything with bookmark
;; support) records it on a bounded ring, with the workspace and window
;; that showed it.  The ring is saved to `reopen-closed-buffer-file', so
;; it survives a restart.
;;
;;   `reopen-closed-buffer'        reopen the most recently killed one
;;   `reopen-closed-buffer-list'   pick one from the ring
;;
;; Recording is terra-emacs-capture's leaf capture
;; (`terra-emacs-capture-leaf'); reopening is the engine's leaf restore
;; (`terra-emacs-leaf-restore'), so a terminal re-runs its command in
;; its directory and a Claude session is resumed by id, never with two
;; writers.  A buffer reopens in its old workspace when that still
;; exists, in its old window when the layout still has as many windows,
;; else in the selected window.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'terra-emacs)
(require 'terra-emacs-capture)

(defgroup reopen-closed-buffer nil
  "Reopen killed buffers through terra-emacs."
  :group 'convenience
  :prefix "reopen-closed-buffer-")

(defcustom reopen-closed-buffer-size 50
  "How many killed buffers the ring keeps."
  :type 'natnum)

(defcustom reopen-closed-buffer-file (locate-user-emacs-file "reopen-closed-buffer.eld")
  "Where the ring is saved, so it survives a restart; nil keeps it in memory."
  :type '(choice (const :tag "Do not save" nil) file))

(defcustom reopen-closed-buffer-ignore-regexps
  '("\\`\\*Messages\\*\\'" "\\`\\*scratch\\*\\'" "\\`\\*Minibuf-" "\\`\\*Completions\\*\\'"
    "\\`\\*Backtrace\\*\\'" "\\`\\*Warnings\\*\\'" "\\`\\*Compile-Log\\*\\'"
    "\\`\\*Async-native-compile-log\\*\\'" "\\`\\*terra-emacs" "\\`\\*ert\\*\\'")
  "Names of buffers never recorded (`reopen-closed-buffer-ignore-p')."
  :type '(repeat regexp))

(defcustom reopen-closed-buffer-exit-wait 2.0
  "Seconds reopening waits for a killed buffer's process to finish exiting.
A process killed with its buffer can outlive it for a moment; a Claude
session still running then is live elsewhere to the engine, which opens
a read-only view instead of a second writer."
  :type 'number)

(defcustom reopen-closed-buffer-ignore-predicate #'reopen-closed-buffer-ignore-p
  "A function of a buffer: non-nil means killing it is not recorded."
  :type 'function)

(defvar reopen-closed-buffer-ring nil
  "The killed buffers, newest first.
Each entry is a plist: :time (a float), :name, :record (the leaf
record), :workspace (its name, or nil), :window (the window's index
in the layout), :windows (how many the layout had) and :pid (the id of
its process, when it ran one).")

(defvar reopen-closed-buffer--loaded nil
  "Non-nil once `reopen-closed-buffer-file' has been read.")

(defvar reopen-closed-buffer--inhibit nil
  "Non-nil while kills are not recorded.")

;;;; The ring and its file

(defun reopen-closed-buffer--readable-p (object)
  "Non-nil when OBJECT prints as something `read' gives back."
  (condition-case nil
      (equal (car (read-from-string (prin1-to-string object))) object)
    (error nil)))

(defun reopen-closed-buffer-load ()
  "Read the ring saved in `reopen-closed-buffer-file', once.
Entries already on the ring stay ahead of the saved ones."
  (unless reopen-closed-buffer--loaded
    (setq reopen-closed-buffer--loaded t)
    (let ((file reopen-closed-buffer-file))
      (when (and file (file-readable-p file))
        (let ((saved (condition-case err
                         (with-temp-buffer
                           (insert-file-contents file)
                           (read (current-buffer)))
                       (error (message "reopen-closed-buffer: cannot read %s: %s"
                                       file (error-message-string err))
                              nil))))
          (when (listp saved)
            (setq reopen-closed-buffer-ring
                  (reopen-closed-buffer--trim
                   (append reopen-closed-buffer-ring
                           (cl-remove-if-not (lambda (e) (and (consp e) (plist-get e :record)))
                                             saved))))))))))

(defun reopen-closed-buffer-save ()
  "Write the ring to `reopen-closed-buffer-file'."
  (let ((file reopen-closed-buffer-file))
    (when file
      (let ((reopen-closed-buffer--inhibit t)
            (print-length nil) (print-level nil) (print-circle nil))
        (make-directory (file-name-directory (expand-file-name file)) t)
        (with-temp-file file
          (insert ";; reopen-closed-buffer ring -*- mode: lisp-data -*-\n")
          (prin1 reopen-closed-buffer-ring (current-buffer))
          (insert "\n"))))))

(defun reopen-closed-buffer-entries ()
  "The ring, newest first (read from its file the first time)."
  (reopen-closed-buffer-load)
  reopen-closed-buffer-ring)

(defun reopen-closed-buffer--trim (entries)
  "ENTRIES without later duplicates, at most `reopen-closed-buffer-size' of them."
  (let ((seen nil) (kept nil))
    (dolist (e entries)
      (let ((key (ignore-errors (terra-emacs-leaf-key (plist-get e :record)))))
        (unless (member key seen)
          (push key seen)
          (push e kept))))
    (seq-take (nreverse kept) reopen-closed-buffer-size)))

(defun reopen-closed-buffer--push (entry)
  "Put ENTRY at the head of the ring and save it."
  (reopen-closed-buffer-load)
  (setq reopen-closed-buffer-ring (reopen-closed-buffer--trim (cons entry reopen-closed-buffer-ring)))
  (reopen-closed-buffer-save))

(defun reopen-closed-buffer-forget (predicate)
  "Drop every entry PREDICATE (a function of an entry) is non-nil for."
  (reopen-closed-buffer-load)
  (let ((kept (cl-remove-if predicate reopen-closed-buffer-ring)))
    (unless (equal kept reopen-closed-buffer-ring)
      (setq reopen-closed-buffer-ring kept)
      (reopen-closed-buffer-save))))

;;;; Recording a kill

(defun reopen-closed-buffer-ignore-p (buffer)
  "Non-nil for BUFFER when its kill is not worth recording.
Internal buffers (a name starting with a space), minibuffers, the
names in `reopen-closed-buffer-ignore-regexps' and terra-emacs
placeholders."
  (let ((name (buffer-name buffer)))
    (or (null name)
        (string-prefix-p " " name)
        (minibufferp buffer)
        (buffer-local-value 'terra-emacs-leaf-placeholder buffer)
        (cl-some (lambda (re) (string-match-p re name)) reopen-closed-buffer-ignore-regexps))))

(defun reopen-closed-buffer--windows ()
  "The selected frame's windows of its layout, side windows aside."
  (cl-remove-if (lambda (w) (window-parameter w 'window-side))
                (window-list nil 'nomini (frame-first-window))))

(defun reopen-closed-buffer--backend ()
  "The terra-emacs backend in use, or nil when there is none."
  (ignore-errors (terra-emacs-current-backend)))

(defun reopen-closed-buffer-describe (buffer)
  "The ring entry for BUFFER, or nil when terra-emacs cannot bring it back.
A buffer with nothing to restore but its name (an empty buffer would
come back) is not described."
  (let ((record (terra-emacs-leaf-clean (terra-emacs-capture-leaf buffer))))
    (unless (eq (terra-emacs-leaf-prop record 'handler) 'terra-emacs-leaf-buffer-handler)
      (let* ((windows (reopen-closed-buffer--windows))
             (window (cl-find buffer windows :key #'window-buffer))
             (backend (and window (reopen-closed-buffer--backend)))
             (process (get-buffer-process buffer))
             (entry (list :time (float-time) :name (buffer-name buffer) :record record
                          :workspace (and backend (terra-emacs-backend-current backend))
                          :window (and window (cl-position window windows))
                          :windows (and window (length windows))
                          :pid (and process (process-id process)))))
        (and (reopen-closed-buffer--readable-p entry) entry)))))

(defun reopen-closed-buffer--record ()
  "Record the buffer being killed (`kill-buffer-hook')."
  (unless (or reopen-closed-buffer--inhibit
              (funcall reopen-closed-buffer-ignore-predicate (current-buffer)))
    (let ((reopen-closed-buffer--inhibit t))
      (condition-case err
          (let ((entry (reopen-closed-buffer-describe (current-buffer))))
            (when entry (reopen-closed-buffer--push entry)))
        (error (message "reopen-closed-buffer: %s not recorded: %s"
                        (buffer-name) (error-message-string err)))))))

;;;###autoload
(define-minor-mode reopen-closed-buffer-mode
  "Record killed buffers so `reopen-closed-buffer' can bring them back."
  :global t
  :group 'reopen-closed-buffer
  (if reopen-closed-buffer-mode
      (progn (reopen-closed-buffer-load)
             (add-hook 'kill-buffer-hook #'reopen-closed-buffer--record))
    (remove-hook 'kill-buffer-hook #'reopen-closed-buffer--record)))

;;;; Reopening

(defun reopen-closed-buffer--place (entry)
  "Select where ENTRY's buffer goes: its workspace and window, when they last."
  (let* ((backend (reopen-closed-buffer--backend))
         (ws (plist-get entry :workspace)))
    (when (and backend ws (member ws (terra-emacs-backend-workspaces backend)))
      (unless (equal ws (terra-emacs-backend-current backend))
        (terra-emacs-backend-select backend ws))
      (let ((windows (reopen-closed-buffer--windows)))
        (when (and (plist-get entry :window) (eql (plist-get entry :windows) (length windows)))
          (select-window (nth (plist-get entry :window) windows))))
      (cons backend ws))))

(defun reopen-closed-buffer--await-exit (pid)
  "Wait up to `reopen-closed-buffer-exit-wait' seconds for process PID to end."
  (when pid
    (let ((end (+ (float-time) reopen-closed-buffer-exit-wait)))
      (while (and (< (float-time) end) (terra-emacs-claude-pid-live-p pid))
        (accept-process-output nil 0.02)))))

(defun reopen-closed-buffer-reopen (entry)
  "Bring ENTRY's buffer back, show it and drop ENTRY from the ring; the buffer."
  (setq reopen-closed-buffer-ring (delq entry (reopen-closed-buffer-entries)))
  (reopen-closed-buffer-save)
  (reopen-closed-buffer--await-exit (plist-get entry :pid))
  (let* ((place (reopen-closed-buffer--place entry))
         (buffer (let ((reopen-closed-buffer--inhibit t))
                   (terra-emacs-leaf-restore (plist-get entry :record)))))
    (pop-to-buffer-same-window buffer)
    (when place (terra-emacs-backend-add-buffer (car place) (cdr place) buffer))
    buffer))

;;;###autoload
(defun reopen-closed-buffer (&optional entry)
  "Reopen the most recently killed buffer (or ENTRY of the ring).
It comes back in its old workspace when that still exists, else in
the selected window.  Return the buffer."
  (interactive)
  (let ((entry (or entry (car (reopen-closed-buffer-entries))
                   (user-error "No killed buffer to reopen"))))
    (reopen-closed-buffer-reopen entry)))

(defun reopen-closed-buffer--label (entry)
  "ENTRY as a line for completion."
  (format "%s  [%s]  %s%s" (plist-get entry :name)
          (or (terra-emacs-leaf-prop (plist-get entry :record) 'filename)
              (terra-emacs-leaf-prop (plist-get entry :record) 'cwd)
              (terra-emacs-leaf-prop (plist-get entry :record) 'handler)
              "")
          (format-time-string "%F %R" (plist-get entry :time))
          (if (plist-get entry :workspace) (format "  in %s" (plist-get entry :workspace)) "")))

;;;###autoload
(defun reopen-closed-buffer-list ()
  "Pick a killed buffer from the ring and reopen it."
  (interactive)
  (let* ((entries (or (reopen-closed-buffer-entries) (user-error "No killed buffer to reopen")))
         (labels (mapcar (lambda (e) (cons (reopen-closed-buffer--label e) e)) entries))
         (table (lambda (string pred action)
                  (if (eq action 'metadata)
                      '(metadata (display-sort-function . identity))
                    (complete-with-action action labels string pred))))
         (choice (completing-read "Reopen buffer: " table nil t)))
    (reopen-closed-buffer-reopen (cdr (assoc choice labels)))))

(provide 'reopen-closed-buffer)
;;; reopen-closed-buffer.el ends here
