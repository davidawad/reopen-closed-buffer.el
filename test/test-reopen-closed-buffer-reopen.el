;;; test-reopen-closed-buffer-reopen.el --- reopening through terra-emacs -*- lexical-binding: t; -*-

;;; Commentary:
;; Reopening recreates the buffer through the engine's leaf restore: a
;; file at its position, an eat terminal re-running its command, a
;; Claude session resumed by its id.  It comes back in its old
;; workspace (tab-bar and persp-mode) and window when they still exist,
;; else in the selected window; `-list' picks any entry.

;;; Code:

(require 'reopen-closed-buffer-test-helper
         (expand-file-name "reopen-closed-buffer-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))

(ert-deftest reopen-closed-buffer-reopens-in-the-selected-window ()
  (rcb-test-reset-tabs)
  (rcb-test-with-ring
    (let ((f (rcb-test-file "a.txt")))
      (with-current-buffer (find-file-noselect f)
        (goto-char (point-min)) (forward-line 2)
        (kill-buffer))
      (should-not (get-file-buffer f))
      (let ((buf (reopen-closed-buffer)))
        (should (eq (window-buffer (selected-window)) buf))
        (should (equal (buffer-file-name buf) f))
        (should (= (line-number-at-pos (window-point)) 3))
        ;; Reopened: off the ring.
        (should-not reopen-closed-buffer-ring)
        (should-error (reopen-closed-buffer) :type 'user-error)))))

(ert-deftest reopen-closed-buffer-reopens-in-its-old-tab-and-window ()
  (rcb-test-reset-tabs)
  (rcb-test-with-ring
    (let ((f (rcb-test-file "b.txt")))
      (terra-emacs-backend-create 'tab-bar "work")
      (terra-emacs-backend-select 'tab-bar "work")
      (switch-to-buffer "*scratch*")
      (select-window (split-window-right))
      (find-file f)
      (kill-buffer)
      (terra-emacs-backend-select 'tab-bar "main")
      (let ((buf (reopen-closed-buffer)))
        (should (equal (terra-emacs-backend-current 'tab-bar) "work"))
        (should (eq (selected-window) (nth 1 (window-list nil 'nomini (frame-first-window)))))
        (should (eq (window-buffer (selected-window)) buf)))
      ;; Its tab gone, it comes back in the selected window.
      (kill-buffer (get-file-buffer f))
      (terra-emacs-backend-select 'tab-bar "main")
      (terra-emacs-backend-kill 'tab-bar "work")
      (let ((buf (reopen-closed-buffer)))
        (should (equal (terra-emacs-backend-current 'tab-bar) "main"))
        (should (equal (buffer-file-name (window-buffer (selected-window))) f))
        (should (eq (window-buffer (selected-window)) buf))))))

(ert-deftest reopen-closed-buffer-reopens-in-its-old-perspective ()
  (skip-unless (rcb-test-have 'persp-mode))
  (rcb-test-persp-on)
  (unwind-protect
      (rcb-test-with-ring
        (let ((terra-emacs-backend 'persp-mode)
              (f (rcb-test-file "c.txt")))
          (persp-add-new "code")
          (persp-add-new "mail")
          (persp-switch "code")
          (find-file f)
          (kill-buffer)
          (should (equal (plist-get (car reopen-closed-buffer-ring) :workspace) "code"))
          (persp-switch "mail")
          (let ((buf (reopen-closed-buffer)))
            (should (equal (terra-emacs-backend-current 'persp-mode) "code"))
            (should (eq (window-buffer (selected-window)) buf))
            (should (memq buf (persp-buffers (persp-get-by-name "code")))))))
    (rcb-test-persp-off)))

(ert-deftest reopen-closed-buffer-reopens-eat-running-its-command ()
  (skip-unless (rcb-test-have 'eat))
  (rcb-test-reset-tabs)
  (rcb-test-with-ring
    (let* ((buf (get-buffer-create "*rcb-eat*"))
           (dir (rcb-test-tmpdir))
           (out (expand-file-name "pwd" (rcb-test-tmpdir)))
           (script (format "pwd > %s; sleep 30" (shell-quote-argument out)))
           (pwd (lambda ()
                  (cl-loop repeat 100 until (and (file-exists-p out)
                                                 (> (file-attribute-size (file-attributes out)) 0))
                           do (accept-process-output nil 0.05))
                  (prog1 (with-temp-buffer (insert-file-contents out) (string-trim (buffer-string)))
                    (delete-file out)))))
      (unwind-protect
          (progn
            (with-current-buffer buf
              (setq default-directory dir)
              (eat-mode)
              (eat-exec buf "rcb-eat" "/bin/sh" nil (list "-c" script)))
            (funcall pwd)
            (rcb-test-kill buf)
            (setq buf (reopen-closed-buffer))
            (should (equal (buffer-name buf) "*rcb-eat*"))
            (should (eq (window-buffer (selected-window)) buf))
            (should (eq (buffer-local-value 'major-mode buf) 'eat-mode))
            (should (process-live-p (get-buffer-process buf)))
            ;; The command runs again, in its directory.
            (should (equal (file-truename (file-name-as-directory (funcall pwd)))
                           (file-truename dir)))
            (should (equal (terra-emacs-leaf-prop (terra-emacs-capture-leaf buf) 'argv)
                           (list "/bin/sh" "-c" script))))
        (rcb-test-kill buf)))))

(defun rcb-test--fake-claude (out sessions)
  "A fake claude writing its argv to OUT and its session file to SESSIONS."
  (let ((bin (expand-file-name "claude" (rcb-test-tmpdir))))
    (with-temp-file bin
      (insert "#!/bin/sh\n"
              "sid=none; prev=\n"
              "for a in \"$@\"; do echo \"$a\" >> " (shell-quote-argument out) "/argv.tmp;"
              " [ \"$prev\" = --resume ] && sid=\"$a\"; prev=\"$a\"; done\n"
              "printf '{\"pid\":%d,\"sessionId\":\"%s\",\"cwd\":\"%s\",\"status\":\"idle\"}'"
              " $$ \"$sid\" \"$PWD\" > " (shell-quote-argument sessions) "/$$.json\n"
              "mv " (shell-quote-argument out) "/argv.tmp " (shell-quote-argument out) "/argv\n"
              "sleep 30\n"))
    (set-file-modes bin #o755)
    bin))

(defun rcb-test--argv (out)
  "The argv file the fake claude wrote in OUT, waiting up to 5s; its lines."
  (let ((file (expand-file-name "argv" out)))
    (cl-loop repeat 100 until (file-exists-p file) do (accept-process-output nil 0.05))
    (prog1 (with-temp-buffer (insert-file-contents file) (split-string (buffer-string) "\n" t))
      (delete-file file))))

(ert-deftest reopen-closed-buffer-resumes-a-claude-session-by-id ()
  (skip-unless (rcb-test-have 'eat))
  (rcb-test-reset-tabs)
  (rcb-test-with-ring
    (let* ((out (rcb-test-tmpdir))
           (terra-emacs-claude-sessions-directory (rcb-test-tmpdir))
           (fake (rcb-test--fake-claude out terra-emacs-claude-sessions-directory))
           (rec (terra-emacs-leaf-make "*claude rcb*" 'handler 'terra-emacs-claude-bookmark-handler
                                       'buffer-name "*claude rcb*" 'session-id "sess-rcb"
                                       'cwd temporary-file-directory 'argv (list fake "--model" "opus")))
           (buf (terra-emacs-leaf-restore rec)))
      (unwind-protect
          (progn
            (should (equal (rcb-test--argv out) '("--model" "opus" "--resume" "sess-rcb")))
            (rcb-test-kill buf)
            (let ((e (car reopen-closed-buffer-ring)))
              (should (equal (terra-emacs-leaf-key (plist-get e :record)) '(claude "sess-rcb"))))
            (setq buf (reopen-closed-buffer))
            (should (equal (buffer-name buf) "*claude rcb*"))
            (should (equal (rcb-test--argv out) '("--model" "opus" "--resume" "sess-rcb"))))
        (rcb-test-kill buf)))))

(ert-deftest reopen-closed-buffer-list-picks-any-entry ()
  (rcb-test-reset-tabs)
  (rcb-test-with-ring
    (let ((dir (rcb-test-tmpdir)))
      (dolist (n '("one.txt" "two.txt" "three.txt"))
        (kill-buffer (find-file-noselect (rcb-test-file n dir))))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _)
                   (let ((all (all-completions "" table)))
                     ;; Newest first, as the ring is.
                     (should (string-prefix-p "three.txt" (car all)))
                     (cl-find-if (lambda (c) (string-prefix-p "two.txt" c)) all)))))
        (call-interactively #'reopen-closed-buffer-list))
      (should (equal (buffer-name (window-buffer (selected-window))) "two.txt"))
      (should (equal (mapcar (lambda (e) (plist-get e :name)) reopen-closed-buffer-ring)
                     '("three.txt" "one.txt"))))))

(provide 'test-reopen-closed-buffer-reopen)
;;; test-reopen-closed-buffer-reopen.el ends here
