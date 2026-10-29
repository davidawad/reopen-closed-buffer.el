;;; test-reopen-closed-buffer-capture.el --- recording a kill -*- lexical-binding: t; -*-

;;; Commentary:
;; Killing a buffer terra-emacs can bring back records its leaf, its
;; workspace and its window; internal, ignored and plain buffers are
;; not recorded; the predicate is the user's to replace.

;;; Code:

(require 'reopen-closed-buffer-test-helper
         (expand-file-name "reopen-closed-buffer-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))

(ert-deftest reopen-closed-buffer-records-a-killed-file ()
  (rcb-test-reset-tabs)
  (rcb-test-with-ring
    (let ((f (rcb-test-file "a.txt")))
      (tab-bar-rename-tab "work")
      (switch-to-buffer "*scratch*")
      (select-window (split-window-right))
      (find-file f)
      (goto-char (point-min)) (forward-line 1)
      (kill-buffer (current-buffer))
      (let ((e (car reopen-closed-buffer-ring)))
        (should (= 1 (length reopen-closed-buffer-ring)))
        (should (equal (plist-get e :name) "a.txt"))
        (should (equal (terra-emacs-leaf-key (plist-get e :record)) (list 'file f)))
        (should (= (terra-emacs-leaf-prop (plist-get e :record) 'position)
                   (with-temp-buffer (insert-file-contents f) (forward-line 1) (point))))
        (should (equal (plist-get e :workspace) "work"))
        (should (eql (plist-get e :window) 1))
        (should (eql (plist-get e :windows) 2))
        (should (floatp (plist-get e :time)))))))

(ert-deftest reopen-closed-buffer-records-dired-and-eshell ()
  (require 'eshell)
  (rcb-test-reset-tabs)
  (rcb-test-with-ring
    (let* ((dir (rcb-test-tmpdir))
           (eshell (let ((default-directory dir) (eshell-buffer-name "*eshell*<rcb>"))
                     (save-window-excursion (eshell)))))
      (kill-buffer (dired-noselect dir))
      (rcb-test-kill eshell)
      (let ((recs (mapcar (lambda (e) (plist-get e :record)) reopen-closed-buffer-ring)))
        (should (equal (terra-emacs-leaf-key (nth 1 recs)) (list 'file dir)))
        (should (eq (terra-emacs-leaf-prop (nth 0 recs) 'handler) 'terra-emacs-eshell-bookmark-handler))
        (should (equal (terra-emacs-leaf-prop (nth 0 recs) 'cwd) dir))
        ;; Not shown anywhere: no workspace, no window.
        (should-not (plist-get (car reopen-closed-buffer-ring) :workspace))))))

(ert-deftest reopen-closed-buffer-records-eat-with-its-command ()
  (skip-unless (rcb-test-have 'eat))
  (rcb-test-with-ring
    (let ((buf (get-buffer-create "*rcb-eat*")) (dir (rcb-test-tmpdir)))
      (with-current-buffer buf
        (setq default-directory dir)
        (eat-mode)
        (eat-exec buf "rcb-eat" "/bin/sh" nil '("-c" "sleep 30")))
      (rcb-test-kill buf)
      (let ((rec (plist-get (car reopen-closed-buffer-ring) :record)))
        (should (eq (terra-emacs-leaf-prop rec 'handler) 'terra-emacs-eat-bookmark-handler))
        (should (equal (terra-emacs-leaf-prop rec 'argv) '("/bin/sh" "-c" "sleep 30")))
        (should (equal (terra-emacs-leaf-prop rec 'cwd) dir))
        ;; A ring entry never says stale: reopening restarts the command anyway.
        (should-not (terra-emacs-leaf-stale-p rec))))))

(ert-deftest reopen-closed-buffer-skips-what-it-cannot-or-should-not-bring-back ()
  (rcb-test-with-ring
    (kill-buffer (get-buffer-create " *internal*"))
    (kill-buffer (get-buffer-create "*plain*"))      ; nothing but a name: not describable
    (with-current-buffer (get-buffer-create "*Backtrace*") (setq buffer-file-name nil))
    (kill-buffer "*Backtrace*")
    (with-temp-buffer (insert "x"))
    (should-not reopen-closed-buffer-ring)
    ;; Ignored by name even when it visits a file.
    (let ((reopen-closed-buffer-ignore-regexps '("\\`skip-")))
      (kill-buffer (find-file-noselect (rcb-test-file "skip-me.txt"))))
    (should-not reopen-closed-buffer-ring)
    ;; The predicate is the user's.
    (let ((reopen-closed-buffer-ignore-predicate
           (lambda (b) (string-match-p "\\.log\\'" (buffer-name b)))))
      (kill-buffer (find-file-noselect (rcb-test-file "x.log")))
      (kill-buffer (find-file-noselect (rcb-test-file "kept.txt"))))
    (should (equal (mapcar (lambda (e) (plist-get e :name)) reopen-closed-buffer-ring)
                   '("kept.txt")))
    ;; With the mode off nothing is recorded.
    (reopen-closed-buffer-mode -1)
    (kill-buffer (find-file-noselect (rcb-test-file "off.txt")))
    (should (= 1 (length reopen-closed-buffer-ring)))))

(provide 'test-reopen-closed-buffer-capture)
;;; test-reopen-closed-buffer-capture.el ends here
