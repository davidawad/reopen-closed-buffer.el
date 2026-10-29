;;; test-reopen-closed-buffer-ring.el --- the bounded, persisted ring -*- lexical-binding: t; -*-

;;; Commentary:
;; The ring keeps the newest `reopen-closed-buffer-size' entries, one per
;; leaf, and its file brings them back after a restart: the round trip
;; through the file is equal, and a buffer killed in one Emacs reopens
;; in the next.

;;; Code:

(require 'reopen-closed-buffer-test-helper
         (expand-file-name "reopen-closed-buffer-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))

(ert-deftest reopen-closed-buffer-ring-is-bounded-and-deduplicated ()
  (rcb-test-with-ring
    (let ((reopen-closed-buffer-size 3)
          (dir (rcb-test-tmpdir)))
      (dolist (n '("1" "2" "3" "4"))
        (kill-buffer (find-file-noselect (rcb-test-file n dir))))
      (should (equal (mapcar (lambda (e) (plist-get e :name)) reopen-closed-buffer-ring)
                     '("4" "3" "2")))
      ;; Killing "3" again moves it to the head instead of adding a second one.
      (kill-buffer (find-file-noselect (expand-file-name "3" dir)))
      (should (equal (mapcar (lambda (e) (plist-get e :name)) reopen-closed-buffer-ring)
                     '("3" "4" "2"))))))

(ert-deftest reopen-closed-buffer-ring-file-round-trip ()
  (rcb-test-with-ring
    (let ((dir (rcb-test-tmpdir)))
      (dolist (n '("a.txt" "b.txt"))
        (kill-buffer (find-file-noselect (rcb-test-file n dir))))
      (let ((before reopen-closed-buffer-ring))
        (should (file-exists-p reopen-closed-buffer-file))
        ;; A restart: nothing in memory, the file read on first use.
        (setq reopen-closed-buffer-ring nil reopen-closed-buffer--loaded nil)
        (should (equal (reopen-closed-buffer-entries) before))
        ;; Entries recorded before the file was read stay ahead of it.
        (setq reopen-closed-buffer-ring nil reopen-closed-buffer--loaded nil)
        (kill-buffer (find-file-noselect (rcb-test-file "c.txt" dir)))
        (should (equal (mapcar (lambda (e) (plist-get e :name)) (reopen-closed-buffer-entries))
                       '("c.txt" "b.txt" "a.txt")))
        ;; Forgetting saves too.
        (reopen-closed-buffer-forget (lambda (e) (equal (plist-get e :name) "b.txt")))
        (setq reopen-closed-buffer-ring nil reopen-closed-buffer--loaded nil)
        (should (equal (mapcar (lambda (e) (plist-get e :name)) (reopen-closed-buffer-entries))
                       '("c.txt" "a.txt")))))))

(ert-deftest reopen-closed-buffer-ring-file-unreadable-or-off ()
  (rcb-test-with-ring
    (with-temp-file reopen-closed-buffer-file (insert "(:unbalanced"))
    (should-not (reopen-closed-buffer-entries))
    (let ((reopen-closed-buffer-file nil))
      (kill-buffer (find-file-noselect (rcb-test-file "mem.txt")))
      (should (= 1 (length reopen-closed-buffer-ring))))))

(ert-deftest reopen-closed-buffer-survives-a-restart ()
  ;; One batch Emacs kills a file buffer and exits; the next reopens it.
  (let* ((file (rcb-test-file "restart.txt"))
         (ring (expand-file-name "ring.eld" (rcb-test-tmpdir)))
         (emacs (expand-file-name invocation-name invocation-directory))
         (args (append (list "-Q" "--batch")
                       (cl-mapcan (lambda (d) (list "-L" d)) load-path)
                       (list "--eval" (format "(setq reopen-closed-buffer-file %S)" ring)
                             "-l" "reopen-closed-buffer" "-f" "reopen-closed-buffer-mode"))))
    (should (zerop (apply #'call-process emacs nil nil nil
                          (append args (list "--eval" (format "(kill-buffer (find-file-noselect %S))"
                                                              file))))))
    (should (file-exists-p ring))
    (with-temp-buffer
      (should (zerop (apply #'call-process emacs nil '(t nil) nil
                            (append args (list "--eval"
                                               "(princ (buffer-file-name (reopen-closed-buffer)))")))))
      (should (equal (string-trim (buffer-string)) file)))))

(provide 'test-reopen-closed-buffer-ring)
;;; test-reopen-closed-buffer-ring.el ends here
