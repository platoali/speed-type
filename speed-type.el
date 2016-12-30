;;; speed-type.el --- Practice touch and speed typing

;; Copyright (C) 2015 Gunther Hagleitner

;; Author: Gunther Hagleitner
;; Maintainer: Julien Pagès <j.parkouss@gmail.com>
;; Version: 1.0
;; Keywords: games
;; URL: https://github.com/parkouss/speed-type
;; Package-Requires: ((cl-lib "0.3"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Speed-type allows you to practice your touch typing skills.  You can
;; test yourself by typing snippets from online books or use any piece
;; of text or code you have in emacs.  Speed-type keeps track of your
;; stats (WPM, CPM, accuracy) while you are typing.

;;; Code:

(require 'url)
(require 'cl-lib)

(defgroup speed-type nil
  "Practice touch-typing in emacs."
  :group 'games)

(defcustom speed-type-min-chars 200
  "The minimum number of chars to type required when the text to type is picked randomly."
  :group 'speed-type
  :type 'integer)

(defcustom speed-type-max-chars 450
  "The maximum number of chars to type required when the text to type is picked randomly."
  :group 'speed-type
  :type 'integer)

(defcustom speed-type-gb-book-list
  '(1342 11 1952 1661 74 1232 23 135 5200 2591 844 84 98 2701 1400 16328 174
         46 4300 345 1080 2500 829 1260 6130 1184 768 32032 521 1399 55)
  "List of book numbers to use from the gutemberg web site.

Book numbers can be picked from https://www.gutenberg.org, when looking at
a book url.  E.G, https://www.gutenberg.org/ebooks/14577."
  :group 'speed-type
  :type '(repeat integer))

;; internal variables

(defvar speed-type--gb-url-format
  "https://www.gutenberg.org/cache/epub/%d/pg%d.txt")

(defvar speed-type-explaining-message "
Gross wpm/cpm ignore uncorrected errors and indicate raw speed.
Net wpm/cpm take uncorrected errors into account and are a measure
of effective or net speed.")

(defvar speed-type-stats-format "\n
Skill:        %s
Net WPM:      %d
Net CPM:      %d
Gross WPM:    %d
Gross CPM:    %d
Accuracy:     %.2f%%
Total time:   %s
Total chars:  %d
Corrections:  %d
Total errors: %d
%s")

(defvar speed-type--completed-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") 'kill-this-buffer)
    (define-key map (kbd "r") 'speed-type--replay)
    (define-key map (kbd "n") 'speed-type--play-next)
    map))

;; buffer local internal variables

(defvar speed-type--start-time nil)
(make-variable-buffer-local 'speed-type--start-time)

(defvar speed-type--orig-text nil)
(make-variable-buffer-local 'speed-type--orig-text)

(defvar speed-type--entries 0)
(make-variable-buffer-local 'speed-type--entries)

(defvar speed-type--errors 0)
(make-variable-buffer-local 'speed-type--errors)

(defvar speed-type--remaining 0)
(make-variable-buffer-local 'speed-type--remaining)

(defvar speed-type--mod-str nil)
(make-variable-buffer-local 'speed-type--mod-str)

(defvar speed-type--corrections 0)
(make-variable-buffer-local 'speed-type--corrections)

(defvar speed-type--title nil)
(make-variable-buffer-local 'speed-type--title)

(defvar speed-type--author nil)
(make-variable-buffer-local 'speed-type--author)

(defvar speed-type--opened-on-buffer nil)
(make-variable-buffer-local 'speed-type--opened-on-buffer)

;; save-mark-and-excursion in Emacs 25.1 and above works like save-excursion did before
(eval-when-compile
  (when (or
         (< emacs-major-version 25)
         (and (= emacs-major-version 25) (< emacs-minor-version 1)))
    (defmacro save-mark-and-excursion (&rest body)
`(save-excursion ,@body))))

(defun speed-type--seconds-to-minutes (seconds)
  "Return minutes in float for SECONDS."
  (/ seconds 60.0))

(defun speed-type--gross-wpm (entries seconds)
  "Return gross words-per-minute.

Computes words-per-minute as (ENTRIES/5) / (SECONDS/60)."
  (round (/ (/ entries 5.0)
            (speed-type--seconds-to-minutes seconds))))

(defun speed-type--gross-cpm (entries seconds)
  "Return gross characters-per-minute.

Computes characters-per-minute as ENTRIES / (SECONDS/60)."
  (round (/ entries (speed-type--seconds-to-minutes seconds))))

(defun speed-type--net-wpm (entries uncorrected-errors seconds)
  "Return net words-per-minute.

Computes net words-per-minute as:
  ((ENTRIES/5) - UNCORRECTED-ERRORS) / (SECONDS/60)."
  (let ((net-wpm (round (- (speed-type--gross-wpm entries seconds)
                           (/ uncorrected-errors
                              (speed-type--seconds-to-minutes seconds))))))
    (if (> 0 net-wpm) 0 net-wpm)))

(defun speed-type--net-cpm (entries uncorrected-errors seconds)
  "Return net characters-per-minute.

Computes net characters-per-minute as:
  (ENTRIES - UNCORRECTED-ERRORS) / (SECONDS/60)."
  (let ((net-cpm (round (- (speed-type--gross-cpm entries seconds)
                           (/ uncorrected-errors
                              (speed-type--seconds-to-minutes seconds))))))
    (if (> 0 net-cpm) 0 net-cpm)))

(defun speed-type--accuracy (total-entries correct-entries corrections)
  "Return accuracy.

Accuracy is computed as (CORRECT-ENTRIES - CORRECTIONS) / TOTAL-ENTRIES."
  (let* ((correct-entries (- correct-entries corrections))
         (correct-entries (if (> correct-entries 0) correct-entries 0)))
    (* (round (* (/ correct-entries (float total-entries)) 100.0) 0.01) 0.01)))

(defun speed-type--skill (wpm)
  "Return skill for WPM."
  (cond ((< wpm 25) "Beginner")
        ((< wpm 30) "Intermediate")
        ((< wpm 40) "Average")
        ((< wpm 55) "Pro")
        ((< wpm 80) "Master")
        (t          "Racer")))

(defun speed-type--generate-stats (entries errors corrections seconds)
  "Return string of statistics."
  (format speed-type-stats-format
          (speed-type--skill (speed-type--net-wpm entries errors seconds))
          (speed-type--net-wpm entries errors seconds)
          (speed-type--net-cpm entries errors seconds)
          (speed-type--gross-wpm entries seconds)
          (speed-type--gross-cpm entries seconds)
          (speed-type--accuracy entries (- entries errors) corrections)
          (format-seconds "%M %z%S" seconds)
          entries
          corrections
          (+ errors corrections)
          speed-type-explaining-message))

(defun speed-type--gb-url (book-num)
  "Return url for BOOK-NUM."
  (format speed-type--gb-url-format book-num book-num))

(defun speed-type--gb-retrieve (book-num)
  "Return buffer with book number BOOK-NUM in it."
  (let ((dr (locate-user-emacs-file (format "speed-type")))
        (fn (locate-user-emacs-file (format "speed-type/%d.txt" book-num)))
        (url-request-method "GET"))
    (if (file-readable-p fn)
        (find-file-noselect fn t)
      (let ((buf (url-retrieve-synchronously (speed-type--gb-url book-num)))
            (new-buf (generate-new-buffer "temp-speed-type")))
        ;; decoding the buffer content must be done in a new buffer
        ;; to work properly
        (with-current-buffer buf
          (delete-trailing-whitespace)
          (decode-coding-region (point-min) (point-max) 'utf-8 new-buf))
        (kill-buffer buf)
        (with-current-buffer new-buf
          (when (not (file-exists-p dr))
            (make-directory dr))
          (write-file fn)
          new-buf)))))

(defun speed-type--elapsed-time ()
  "Return float with the total time since start."
  (let ((end-time (float-time)))
    (if (not speed-type--start-time)
        0 (- end-time speed-type--start-time))))

(defun speed-type--check-same (pos a b)
  "Return true iff both A[POS] B[POS] are white space or if they are the same."
  (let ((q (aref a pos))
        (p (aref b pos)))
    (or (and (= (char-syntax p) ?\s)
             (= (char-syntax q) ?\s))
        (= p q))))

(defun speed-type--handle-del (start end)
  "Keep track of the statistics when a deletion occurs between START and END."
  (delete-region start end)
  (dotimes (i (- end start) nil)
    (let* ((pos (+ (1- start) i))
           (q (aref speed-type--mod-str pos)))
      (cond ((= q 0) ())
            ((= q 1) (progn (cl-decf speed-type--entries)
                            (cl-incf speed-type--remaining)))
            ((= q 2) (progn (cl-decf speed-type--entries)
                            (cl-incf speed-type--remaining)
                            (cl-decf speed-type--errors)
                            (cl-incf speed-type--corrections))))
      (store-substring speed-type--mod-str pos 0))))

(defun speed-type--replay ()
  (interactive)
  (let ((text speed-type--orig-text))
    (kill-this-buffer)
    (speed-type--setup text)))

(defun speed-type--play-next ()
  (interactive)
  (let ((opened-on-buffer speed-type--opened-on-buffer))
    (kill-this-buffer)
    (if opened-on-buffer
        (with-current-buffer opened-on-buffer
          (speed-type-buffer nil))
      (speed-type-text))))

(defun speed-type--handle-complete ()
  "Remove typing hooks from the buffer and print statistics."
  (remove-hook 'after-change-functions 'speed-type--change)
  (remove-hook 'first-change-hook 'speed-type--first-change)
  (goto-char (point-max))
  (when (and speed-type--title speed-type--author)
    (insert "\n\n")
    (insert (propertize
             (format "%s, by %s" speed-type--title speed-type--author)
             'face 'italic)))
  (insert (speed-type--generate-stats
           speed-type--entries
           speed-type--errors
           speed-type--corrections
           (speed-type--elapsed-time)))
  (insert "\n\n")
  (insert (format "    [%s]uit\n"
                  (propertize "q" 'face 'highlight)))
  (insert (format "    [%s]eplay this sample\n"
                  (propertize "r" 'face 'highlight)))
  (insert (format "    [%s]ext random sample\n"
                  (propertize "n" 'face 'highlight)))
  (read-only-mode)
  (use-local-map speed-type--completed-keymap))

(defun speed-type--diff (orig new start end)
  "Update stats and buffer contents with result of changes in text."
  (let ((start0 (1- start))
        (end0 (1- end))
        (correct nil))
    (dotimes (i (- end start) nil)
      (let ((pos0 (+ start0 i))
            (pos (+ start i)))
        (if (speed-type--check-same i orig new)
            (progn (setq correct t)
                   (store-substring speed-type--mod-str pos0 1))
          (progn (cl-incf speed-type--errors)
                 (store-substring speed-type--mod-str pos0 2)))
        (cl-incf speed-type--entries)
        (cl-decf speed-type--remaining)
        (speed-type--set-char-color pos correct)))))

(defun speed-type--set-char-color (pos correct)
  (let* ((syntax
          (char-syntax (aref (buffer-substring pos (1+ pos)) 0)))
         (attrs
          (if (and (not correct) (= syntax ?\s))
              '(:underline "red")
            `(:underline nil :foreground ,(if correct "green" "red")))))
    (if (fboundp 'add-face-text-property)
        (add-face-text-property pos (1+ pos) attrs)
      (add-text-properties pos (1+ pos) `(face ,@attrs)))))

(defun speed-type--change (start end length)
  "Handle buffer changes.

Make sure that the contents don't actually change, but rather the contents
are color coded and stats are gathered about the typing performance."
  (let ((len (length speed-type--orig-text)))
    (when (<= start len)
      (let* ((end (if (> end (1+ len)) len end))
             (length (if (> (+ start length) len) (1+ (- len start)) length))
             (start0 (1- start))
             (end0 (1- end))
             (new-text (buffer-substring start end))
             (old-text (substring speed-type--orig-text
                                  start0 (+ start0 length)))
             (orig (substring speed-type--orig-text start0 end0)))
        (speed-type--handle-del start end)
        (insert old-text)
        (speed-type--diff orig new-text start end)
        (goto-char end)
        (when (= speed-type--remaining 0)
          (speed-type--handle-complete))))))

(defun speed-type--first-change ()
  "Start the timer."
  (when (not speed-type--start-time)
    (setq speed-type--start-time (float-time))))

(defun speed-type--trim (str)
  "Trim leading and tailing whitespace from STR."
  (replace-regexp-in-string (rx (or (: bos (* (any "\n")))
                                    (: (* (any " \t\n")) eos)))
                            ""
                            str))

(defun speed-type--setup (text &optional author title)
  "Set up a new buffer for the typing exercise on TEXT."
  (with-temp-buffer
    (insert text)
    (delete-trailing-whitespace)
    (setq text (speed-type--trim (buffer-string))))
  (let ((buf (generate-new-buffer "speed-type"))
        (len (length text)))
    (set-buffer buf)
    (setq speed-type--orig-text text)
    (setq speed-type--mod-str (make-string len 0))
    (setq speed-type--remaining len)
    (setq speed-type--author author)
    (setq speed-type--title title)
    (insert text)
    (set-buffer-modified-p nil)
    (switch-to-buffer buf)
    (goto-char 0)
    (add-hook 'after-change-functions 'speed-type--change nil t)
    (add-hook 'first-change-hook 'speed-type--first-change nil t)
    (message "Timer will start when you type the first character.")))

(defun speed-type--pick-text-to-type (&optional start end)
  "Returns a random section of the buffer usable for playing

START and END allow to limit to a buffer section - they default
to (point-min) and (point-max)"
  (unless start (setq start (point-min)))
  (unless end (setq end (point-max)))
  (save-mark-and-excursion
    (goto-char start)
    (forward-paragraph
     ;; count the paragraphs, and pick a random one
     (random (let ((nb 0))
               (while (< (point) end)
                 (forward-paragraph)
                 (setq nb (+ 1 nb)))
               (goto-char start)
               nb)))
    (mark-paragraph)
    ;; select more paragraphs until there are more than speed-type-min-chars
    ;; chars in the selection
    (while (and (< (mark) end)
                (< (- (mark) (point)) speed-type-min-chars))
      (mark-paragraph 1 t))
    (exchange-point-and-mark)
    ;; and remove sentences if we are above speed-type-max-chars
    (let ((continue t)
          (sentence-end-double-space nil)
          (fwd nil))
      (while (and (< (point) end)
                  (> (- (point) (mark)) speed-type-max-chars)
                  continue)
        (setq continue (re-search-backward (sentence-end) (mark) t))
        (when continue (setq fwd t)))
      (when fwd (forward-char)))
    (buffer-substring-no-properties (region-beginning) (region-end))))

;;;###autoload
(defun speed-type-region (start end)
  "Open copy of [START,END] in a new buffer to speed type the text."
  (interactive "r")
  (speed-type--setup (buffer-substring-no-properties start end)))

;;;###autoload
(defun speed-type-buffer (full)
  "Open copy of buffer contents in a new buffer to speed type the text.

If using a prefix while calling this function (C-u), then the full text
will be used. Else some text will be picked randomly."
  (interactive "P")
  (if full
      (speed-type--setup (buffer-substring-no-properties
                          (point-min) (point-max)))
    (let ((buf (current-buffer)))
      (speed-type--setup (speed-type--pick-text-to-type))
      (setq speed-type--opened-on-buffer buf))))

;;;###autoload
(defun speed-type-text ()
  "Setup a new text sample to practice touch or speed typing."
  (interactive)
  (let ((book-num (nth (random (length speed-type-gb-book-list))
                       speed-type-gb-book-list))
        (author nil)
        (title nil))
    (with-current-buffer (speed-type--gb-retrieve book-num)
      (goto-char 0)
      (when (re-search-forward "^Title: " nil t)
        (setq title (buffer-substring (point) (line-end-position))))
      (when (re-search-forward "^Author: " nil t)
        (setq author (buffer-substring (point) (line-end-position))))

      (speed-type--setup (speed-type--pick-text-to-type (point))
                         author title))))

(provide 'speed-type)

;;; speed-type.el ends here
