;;; python.el --- silly walks for Python  -*- coding: iso-8859-1 -*-

;; Copyright (C) 2003, 2004, 2005, 2006, 2007  Free Software Foundation, Inc.

;; Author: Dave Love <fx@gnu.org>
;; Maintainer: FSF
;; Created: Nov 2003
;; Keywords: languages

;; This file is part of GNU Emacs.

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; Major mode for editing Python, with support for inferior processes.

;; There is another Python mode, python-mode.el, used by XEmacs and
;; maintained with Python.  That isn't covered by an FSF copyright
;; assignment, unlike this code, and seems not to be well-maintained
;; for Emacs (though I've submitted fixes).  This mode is rather
;; simpler and is better in other ways.  In particular, using the
;; syntax functions with text properties maintained by font-lock makes
;; it more correct with arbitrary string and comment contents.

;; This doesn't implement all the facilities of python-mode.el.  Some
;; just need doing, e.g. catching exceptions in the inferior Python
;; buffer (but see M-x pdb for debugging).  [Actually, the use of
;; `compilation-shell-minor-mode' now is probably enough for that.]
;; Others don't seem appropriate.  For instance,
;; `forward-into-nomenclature' should be done separately, since it's
;; not specific to Python, and I've installed a minor mode to do the
;; job properly in Emacs 23.  [CC mode 5.31 contains an incompatible
;; feature, `c-subword-mode' which is intended to have a similar
;; effect, but actually only affects word-oriented keybindings.]

;; Other things seem more natural or canonical here, e.g. the
;; {beginning,end}-of-defun implementation dealing with nested
;; definitions, and the inferior mode following `cmuscheme'.  (The
;; inferior mode can find the source of errors from
;; `python-send-region' & al via `compilation-shell-minor-mode'.)
;; There is (limited) symbol completion using lookup in Python and
;; Eldoc support also using the inferior process.  Successive TABs
;; cycle between possible indentations for the line.

;; Even where it has similar facilities, this mode is incompatible
;; with python-mode.el in some respects.  For instance, various key
;; bindings are changed to obey Emacs conventions.

;; TODO: See various Fixmes below.

;;; Code:

(eval-when-compile
  (require 'cl)
  (require 'compile)
  (require 'comint)
  (require 'hippie-exp))

(autoload 'comint-mode "comint")

(defgroup python nil
  "Silly walks in the Python language."
  :group 'languages
  :version "22.1"
  :link '(emacs-commentary-link "python"))

;;;###autoload
(add-to-list 'interpreter-mode-alist '("jython" . jython-mode))
;;;###autoload
(add-to-list 'interpreter-mode-alist '("python" . python-mode))
;;;###autoload
(add-to-list 'auto-mode-alist '("\\.py\\'" . python-mode))

;;;; Font lock

(defvar python-font-lock-keywords
  `(,(rx symbol-start
	 ;; From v 2.5 reference, � keywords.
	 ;; def and class dealt with separately below
	 (or "and" "as" "assert" "break" "continue" "del" "elif" "else"
	     "except" "exec" "finally" "for" "from" "global" "if"
	     "import" "in" "is" "lambda" "not" "or" "pass" "print"
	     "raise" "return" "try" "while" "with" "yield"
             ;; Not real keywords, but close enough to be fontified as such
             "self" "True" "False")
	 symbol-end)
    (,(rx symbol-start "None" symbol-end) ; See � Keywords in 2.5 manual.
     . font-lock-constant-face)
    ;; Definitions
    (,(rx symbol-start (group "class") (1+ space) (group (1+ (or word ?_))))
     (1 font-lock-keyword-face) (2 font-lock-type-face))
    (,(rx symbol-start (group "def") (1+ space) (group (1+ (or word ?_))))
     (1 font-lock-keyword-face) (2 font-lock-function-name-face))
    ;; Top-level assignments are worth highlighting.
    (,(rx line-start (group (1+ (or word ?_))) (0+ space) "=")
     (1 font-lock-variable-name-face))
    (,(rx "@" (1+ (or word ?_))) ; decorators
    (0 font-lock-preprocessor-face))))

(defconst python-font-lock-syntactic-keywords
  ;; Make outer chars of matching triple-quote sequences into generic
  ;; string delimiters.  Fixme: Is there a better way?
  `((,(rx (or line-start buffer-start
	      (not (syntax escape)))	; avoid escaped leading quote
	  (group (optional (any "uUrR"))) ; prefix gets syntax property
	  (optional (any "rR"))		  ; possible second prefix
	  (group (syntax string-quote))   ; maybe gets property
	  (backref 2)			  ; per first quote
	  (group (backref 2)))		  ; maybe gets property
     (1 (python-quote-syntax 1))
     (2 (python-quote-syntax 2))
     (3 (python-quote-syntax 3)))
    ;; This doesn't really help.
;;;     (,(rx (and ?\\ (group ?\n))) (1 " "))
    ))

(defun python-quote-syntax (n)
  "Put `syntax-table' property correctly on triple quote.
Used for syntactic keywords.  N is the match number (1, 2 or 3)."
  ;; Given a triple quote, we have to check the context to know
  ;; whether this is an opening or closing triple or whether it's
  ;; quoted anyhow, and should be ignored.  (For that we need to do
  ;; the same job as `syntax-ppss' to be correct and it seems to be OK
  ;; to use it here despite initial worries.)  We also have to sort
  ;; out a possible prefix -- well, we don't _have_ to, but I think it
  ;; should be treated as part of the string.

  ;; Test cases:
  ;;  ur"""ar""" x='"' # """
  ;; x = ''' """ ' a
  ;; '''
  ;; x '"""' x """ \"""" x
  ;; Fixme:  """""" goes wrong (due to syntax-ppss not getting the string
  ;; fence context).
  (save-excursion
    (goto-char (match-beginning 0))
    (cond
     ;; Consider property for the last char if in a fenced string.
     ((= n 3)
      (let* ((font-lock-syntactic-keywords nil)
	     (syntax (syntax-ppss)))
	(when (eq t (nth 3 syntax))	; after unclosed fence
	  (goto-char (nth 8 syntax))	; fence position
	  (skip-chars-forward "uUrR")	; skip any prefix
	  ;; Is it a matching sequence?
	  (if (eq (char-after) (char-after (match-beginning 2)))
	      (eval-when-compile (string-to-syntax "|"))))))
     ;; Consider property for initial char, accounting for prefixes.
     ((or (and (= n 2)			; leading quote (not prefix)
	       (= (match-beginning 1) (match-end 1))) ; prefix is null
	  (and (= n 1)			; prefix
	       (/= (match-beginning 1) (match-end 1)))) ; non-empty
      (let ((font-lock-syntactic-keywords nil))
        (unless (nth 3 (syntax-ppss))
          (eval-when-compile (string-to-syntax "|")))))
     ;; Otherwise (we're in a non-matching string) the property is
     ;; nil, which is OK.
     )))

;; This isn't currently in `font-lock-defaults' as probably not worth
;; it -- we basically only mess with a few normally-symbol characters.

;; (defun python-font-lock-syntactic-face-function (state)
;;   "`font-lock-syntactic-face-function' for Python mode.
;; Returns the string or comment face as usual, with side effect of putting
;; a `syntax-table' property on the inside of the string or comment which is
;; the standard syntax table."
;;   (if (nth 3 state)
;;       (save-excursion
;; 	(goto-char (nth 8 state))
;; 	(condition-case nil
;; 	    (forward-sexp)
;; 	  (error nil))
;; 	(put-text-property (1+ (nth 8 state)) (1- (point))
;; 			   'syntax-table (standard-syntax-table))
;; 	'font-lock-string-face)
;;     (put-text-property (1+ (nth 8 state)) (line-end-position)
;; 			   'syntax-table (standard-syntax-table))
;;     'font-lock-comment-face))

;;;; Keymap and syntax

(defvar python-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Mostly taken from python-mode.el.
    (define-key map ":" 'python-electric-colon)
    (define-key map "\177" 'python-backspace)
    (define-key map "\C-c<" 'python-shift-left)
    (define-key map "\C-c>" 'python-shift-right)
    (define-key map "\C-c\C-k" 'python-mark-block)
    (define-key map "\C-c\C-n" 'python-next-statement)
    (define-key map "\C-c\C-p" 'python-previous-statement)
    (define-key map "\C-c\C-u" 'python-beginning-of-block)
    (define-key map "\C-c\C-f" 'python-describe-symbol)
    (define-key map "\C-c\C-w" 'python-check)
    (define-key map "\C-c\C-v" 'python-check) ; a la sgml-mode
    (define-key map "\C-c\C-s" 'python-send-string)
    (define-key map [?\C-\M-x] 'python-send-defun)
    (define-key map "\C-c\C-r" 'python-send-region)
    (define-key map "\C-c\M-r" 'python-send-region-and-go)
    (define-key map "\C-c\C-c" 'python-send-buffer)
    (define-key map "\C-c\C-z" 'python-switch-to-python)
    (define-key map "\C-c\C-m" 'python-load-file)
    (define-key map "\C-c\C-l" 'python-load-file) ; a la cmuscheme
    (substitute-key-definition 'complete-symbol 'python-complete-symbol
			       map global-map)
    (define-key map "\C-c\C-i" 'python-find-imports)
    (define-key map "\C-c\C-t" 'python-expand-template)
    (easy-menu-define python-menu map "Python Mode menu"
      `("Python"
	:help "Python-specific Features"
	["Shift region left" python-shift-left :active mark-active
	 :help "Shift by a single indentation step"]
	["Shift region right" python-shift-right :active mark-active
	 :help "Shift by a single indentation step"]
	"-"
	["Mark block" python-mark-block
	 :help "Mark innermost block around point"]
	["Mark def/class" mark-defun
	 :help "Mark innermost definition around point"]
	"-"
	["Start of block" python-beginning-of-block
	 :help "Go to start of innermost definition around point"]
	["End of block" python-end-of-block
	 :help "Go to end of innermost definition around point"]
	["Start of def/class" beginning-of-defun
	 :help "Go to start of innermost definition around point"]
	["End of def/class" end-of-defun
	 :help "Go to end of innermost definition around point"]
	"-"
	("Templates..."
	 :help "Expand templates for compound statements"
	 :filter (lambda (&rest junk)
		   (mapcar (lambda (elt)
			     (vector (car elt) (cdr elt) t))
			   python-skeletons))) ; defined later
	"-"
	["Start interpreter" run-python
	 :help "Run `inferior' Python in separate buffer"]
	["Import/reload file" python-load-file
	 :help "Load into inferior Python session"]
	["Eval buffer" python-send-buffer
	 :help "Evaluate buffer en bloc in inferior Python session"]
	["Eval region" python-send-region :active mark-active
	 :help "Evaluate region en bloc in inferior Python session"]
	["Eval def/class" python-send-defun
	 :help "Evaluate current definition in inferior Python session"]
	["Switch to interpreter" python-switch-to-python
	 :help "Switch to inferior Python buffer"]
	["Set default process" python-set-proc
	 :help "Make buffer's inferior process the default"
	 :active (buffer-live-p python-buffer)]
	["Check file" python-check :help "Run pychecker"]
	["Debugger" pdb :help "Run pdb under GUD"]
	"-"
	["Help on symbol" python-describe-symbol
	 :help "Use pydoc on symbol at point"]
	["Complete symbol" python-complete-symbol
	 :help "Complete (qualified) symbol before point"]
	["Update imports" python-find-imports
	 :help "Update list of top-level imports for completion"]))
    map))
;; Fixme: add toolbar stuff for useful things like symbol help, send
;; region, at least.  (Shouldn't be specific to Python, obviously.)
;; eric has items including: (un)indent, (un)comment, restart script,
;; run script, debug script; also things for profiling, unit testing.

(defvar python-mode-syntax-table
  (let ((table (make-syntax-table)))
    ;; Give punctuation syntax to ASCII that normally has symbol
    ;; syntax or has word syntax and isn't a letter.
    (let ((symbol (string-to-syntax "_"))
	  (sst (standard-syntax-table)))
      (dotimes (i 128)
	(unless (= i ?_)
	  (if (equal symbol (aref sst i))
	      (modify-syntax-entry i "." table)))))
    (modify-syntax-entry ?$ "." table)
    (modify-syntax-entry ?% "." table)
    ;; exceptions
    (modify-syntax-entry ?# "<" table)
    (modify-syntax-entry ?\n ">" table)
    (modify-syntax-entry ?' "\"" table)
    (modify-syntax-entry ?` "$" table)
    table))

;;;; Utility stuff

(defsubst python-in-string/comment ()
  "Return non-nil if point is in a Python literal (a comment or string)."
  ;; We don't need to save the match data.
  (nth 8 (syntax-ppss)))

(defconst python-space-backslash-table
  (let ((table (copy-syntax-table python-mode-syntax-table)))
    (modify-syntax-entry ?\\ " " table)
    table)
  "`python-mode-syntax-table' with backslash given whitespace syntax.")

(defun python-skip-comments/blanks (&optional backward)
  "Skip comments and blank lines.
BACKWARD non-nil means go backwards, otherwise go forwards.
Backslash is treated as whitespace so that continued blank lines
are skipped.  Doesn't move out of comments -- should be outside
or at end of line."
  (let ((arg (if backward
		 ;; If we're in a comment (including on the trailing
		 ;; newline), forward-comment doesn't move backwards out
		 ;; of it.  Don't set the syntax table round this bit!
		 (let ((syntax (syntax-ppss)))
		   (if (nth 4 syntax)
		       (goto-char (nth 8 syntax)))
		   (- (point-max)))
	       (point-max))))
    (with-syntax-table python-space-backslash-table
      (forward-comment arg))))

(defun python-backslash-continuation-line-p ()
  "Non-nil if preceding line ends with backslash that is not in a comment."
  (and (eq ?\\ (char-before (line-end-position 0)))
       (not (syntax-ppss-context (syntax-ppss)))))

(defun python-continuation-line-p ()
  "Return non-nil if current line continues a previous one.
The criteria are that the previous line ends in a backslash outside
comments and strings, or that point is within brackets/parens."
  (or (python-backslash-continuation-line-p)
      (let ((depth (syntax-ppss-depth
		    (save-excursion ; syntax-ppss with arg changes point
		      (syntax-ppss (line-beginning-position))))))
	(or (> depth 0)
	    (if (< depth 0)	  ; Unbalanced brackets -- act locally
		(save-excursion
		  (condition-case ()
		      (progn (backward-up-list) t) ; actually within brackets
		    (error nil))))))))

(defun python-comment-line-p ()
  "Return non-nil iff current line has only a comment."
  (save-excursion
    (end-of-line)
    (when (eq 'comment (syntax-ppss-context (syntax-ppss)))
      (back-to-indentation)
      (looking-at (rx (or (syntax comment-start) line-end))))))

(defun python-blank-line-p ()
  "Return non-nil iff current line is blank."
  (save-excursion
    (beginning-of-line)
    (looking-at "\\s-*$")))

(defun python-beginning-of-string ()
  "Go to beginning of string around point.
Do nothing if not in string."
  (let ((state (syntax-ppss)))
    (when (eq 'string (syntax-ppss-context state))
      (goto-char (nth 8 state)))))

(defun python-open-block-statement-p (&optional bos)
  "Return non-nil if statement at point opens a block.
BOS non-nil means point is known to be at beginning of statement."
  (save-excursion
    (unless bos (python-beginning-of-statement))
    (looking-at (rx (and (or "if" "else" "elif" "while" "for" "def"
			     "class" "try" "except" "finally" "with")
			 symbol-end)))))

(defun python-close-block-statement-p (&optional bos)
  "Return non-nil if current line is a statement closing a block.
BOS non-nil means point is at beginning of statement.
The criteria are that the line isn't a comment or in string and
 starts with keyword `raise', `break', `continue' or `pass'."
  (save-excursion
    (unless bos (python-beginning-of-statement))
    (back-to-indentation)
    (looking-at (rx (or "return" "raise" "break" "continue" "pass")
		    symbol-end))))

(defun python-outdent-p ()
  "Return non-nil if current line should outdent a level."
  (save-excursion
    (back-to-indentation)
    (and (looking-at (rx (and (or "else" "finally" "except" "elif")
			      symbol-end)))
	 (not (python-in-string/comment))
	 ;; Ensure there's a previous statement and move to it.
	 (zerop (python-previous-statement))
	 (not (python-close-block-statement-p t))
	 ;; Fixme: check this
	 (not (python-open-block-statement-p)))))

;;;; Indentation.

(defcustom python-indent 4
  "Number of columns for a unit of indentation in Python mode.
See also `\\[python-guess-indent]'"
  :group 'python
  :type 'integer)
(put 'python-indent 'safe-local-variable 'integerp)

(defcustom python-guess-indent t
  "Non-nil means Python mode guesses `python-indent' for the buffer."
  :type 'boolean
  :group 'python)

(defcustom python-indent-string-contents t
  "Non-nil means indent contents of multi-line strings together.
This means indent them the same as the preceding non-blank line.
Otherwise preserve their indentation.

This only applies to `doc' strings, i.e. those that form statements;
the indentation is preserved in others."
  :type '(choice (const :tag "Align with preceding" t)
		 (const :tag "Preserve indentation" nil))
  :group 'python)

(defcustom python-honour-comment-indentation nil
  "Non-nil means indent relative to preceding comment line.
Only do this for comments where the leading comment character is
followed by space.  This doesn't apply to comment lines, which
are always indented in lines with preceding comments."
  :type 'boolean
  :group 'python)

(defcustom python-continuation-offset 4
  "Number of columns of additional indentation for continuation lines.
Continuation lines follow a backslash-terminated line starting a
statement."
  :group 'python
  :type 'integer)

(defun python-guess-indent ()
  "Guess step for indentation of current buffer.
Set `python-indent' locally to the value guessed."
  (interactive)
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (let (done indent)
	(while (and (not done) (not (eobp)))
	  (when (and (re-search-forward (rx ?: (0+ space)
					    (or (syntax comment-start)
						line-end))
					nil 'move)
		     (python-open-block-statement-p))
	    (save-excursion
	      (python-beginning-of-statement)
	      (let ((initial (current-indentation)))
		(if (zerop (python-next-statement))
		    (setq indent (- (current-indentation) initial)))
		(if (and indent (>= indent 2) (<= indent 8)) ; sanity check
		    (setq done t))))))
	(when done
	  (when (/= indent (default-value 'python-indent))
	    (set (make-local-variable 'python-indent) indent)
	    (unless (= tab-width python-indent)
	      (setq indent-tabs-mode nil)))
	  indent)))))

;; Alist of possible indentations and start of statement they would
;; close.  Used in indentation cycling (below).
(defvar python-indent-list nil
  "Internal use.")
;; Length of the above
(defvar python-indent-list-length nil
  "Internal use.")
;; Current index into the alist.
(defvar python-indent-index nil
  "Internal use.")

(defun python-calculate-indentation ()
  "Calculate Python indentation for line at point."
  (setq python-indent-list nil
	python-indent-list-length 1)
  (save-excursion
    (beginning-of-line)
    (let ((syntax (syntax-ppss))
	  start)
      (cond
       ((eq 'string (syntax-ppss-context syntax)) ; multi-line string
	(if (not python-indent-string-contents)
	    (current-indentation)
	  ;; Only respect `python-indent-string-contents' in doc
	  ;; strings (defined as those which form statements).
	  (if (not (save-excursion
		     (python-beginning-of-statement)
		     (looking-at (rx (or (syntax string-delimiter)
					 (syntax string-quote))))))
	      (current-indentation)
	    ;; Find indentation of preceding non-blank line within string.
	    (setq start (nth 8 syntax))
	    (forward-line -1)
	    (while (and (< start (point)) (looking-at "\\s-*$"))
	      (forward-line -1))
	    (current-indentation))))
       ((python-continuation-line-p)   ; after backslash, or bracketed
	(let ((point (point))
	      (open-start (cadr syntax))
	      (backslash (python-backslash-continuation-line-p))
	      (colon (eq ?: (char-before (1- (line-beginning-position))))))
	  (if open-start
	      ;; Inside bracketed expression.
	      (progn
		(goto-char (1+ open-start))
		;; Look for first item in list (preceding point) and
		;; align with it, if found.
		(if (with-syntax-table python-space-backslash-table
		      (let ((parse-sexp-ignore-comments t))
			(condition-case ()
			    (progn (forward-sexp)
				   (backward-sexp)
				   (< (point) point))
			  (error nil))))
		    ;; Extra level if we're backslash-continued or
		    ;; following a key.
		    (if (or backslash colon)
			(+ python-indent (current-column))
			(current-column))
		  ;; Otherwise indent relative to statement start, one
		  ;; level per bracketing level.
		  (goto-char (1+ open-start))
		  (python-beginning-of-statement)
		  (+ (current-indentation) (* (car syntax) python-indent))))
	    ;; Otherwise backslash-continued.
	    (forward-line -1)
	    (if (python-continuation-line-p)
		;; We're past first continuation line.  Align with
		;; previous line.
		(current-indentation)
	      ;; First continuation line.  Indent one step, with an
	      ;; extra one if statement opens a block.
	      (python-beginning-of-statement)
	      (+ (current-indentation) python-continuation-offset
		 (if (python-open-block-statement-p t)
		     python-indent
		   0))))))
       ((bobp) 0)
       ;; Fixme: Like python-mode.el; not convinced by this.
       ((looking-at (rx (0+ space) (syntax comment-start)
			(not (any " \t\n")))) ; non-indentable comment
	(current-indentation))
       (t (if python-honour-comment-indentation
              ;; Back over whitespace, newlines, non-indentable comments.
              (catch 'done
                (while t
                  (if (cond ((bobp))
                            ;; not at comment start
                            ((not (forward-comment -1))
                             (python-beginning-of-statement)
                             t)
                            ;; trailing comment
                            ((/= (current-column) (current-indentation))
                             (python-beginning-of-statement)
                             t)
                            ;; indentable comment like python-mode.el
                            ((and (looking-at (rx (syntax comment-start)
                                                  (or space line-end)))
                                  (/= 0 (current-column)))))
                      (throw 'done t)))))
          (python-indentation-levels)
          ;; Prefer to indent comments with an immediately-following
          ;; statement, e.g.
          ;;       ...
          ;;   # ...
          ;;   def ...
          (when (and (> python-indent-list-length 1)
                     (python-comment-line-p))
            (forward-line)
            (unless (python-comment-line-p)
              (let ((elt (assq (current-indentation) python-indent-list)))
                (setq python-indent-list
                      (nconc (delete elt python-indent-list)
                             (list elt))))))
          (caar (last python-indent-list)))))))

;;;; Cycling through the possible indentations with successive TABs.

;; These don't need to be buffer-local since they're only relevant
;; during a cycle.

(defun python-initial-text ()
  "Text of line following indentation and ignoring any trailing comment."
  (save-excursion
    (buffer-substring (progn
			(back-to-indentation)
			(point))
		      (progn
			(end-of-line)
			(forward-comment -1)
			(point)))))

(defconst python-block-pairs
  '(("else" "if" "elif" "while" "for" "try" "except")
    ("elif" "if" "elif")
    ("except" "try" "except")
    ("finally" "try"))
  "Alist of keyword matches.
The car of an element is a keyword introducing a statement which
can close a block opened by a keyword in the cdr.")

(defun python-first-word ()
  "Return first word (actually symbol) on the line."
  (save-excursion
    (back-to-indentation)
    (current-word t)))

(defun python-indentation-levels ()
  "Return a list of possible indentations for this line.
It is assumed not to be a continuation line or in a multi-line string.
Includes the default indentation and those which would close all
enclosing blocks.  Elements of the list are actually pairs:
\(INDENTATION . TEXT), where TEXT is the initial text of the
corresponding block opening (or nil)."
  (save-excursion
    (let ((initial "")
	  levels indent)
      ;; Only one possibility immediately following a block open
      ;; statement, assuming it doesn't have a `suite' on the same line.
      (cond
       ((save-excursion (and (python-previous-statement)
			     (python-open-block-statement-p t)
			     (setq indent (current-indentation))
			     ;; Check we don't have something like:
			     ;;   if ...: ...
			     (if (progn (python-end-of-statement)
					(python-skip-comments/blanks t)
					(eq ?: (char-before)))
				 (setq indent (+ python-indent indent)))))
	(push (cons indent initial) levels))
       ;; Only one possibility for comment line immediately following
       ;; another.
       ((save-excursion
	  (when (python-comment-line-p)
	    (forward-line -1)
	    (if (python-comment-line-p)
		(push (cons (current-indentation) initial) levels)))))
       ;; Fixme: Maybe have a case here which indents (only) first
       ;; line after a lambda.
       (t
	(let ((start (car (assoc (python-first-word) python-block-pairs))))
	  (python-previous-statement)
	  ;; Is this a valid indentation for the line of interest?
	  (unless (or (if start		; potentially only outdentable
			  ;; Check for things like:
			  ;;   if ...: ...
			  ;;   else ...:
			  ;; where the second line need not be outdented.
			  (not (member (python-first-word)
				       (cdr (assoc start
						   python-block-pairs)))))
		      ;; Not sensible to indent to the same level as
		      ;; previous `return' &c.
		      (python-close-block-statement-p))
	    (push (cons (current-indentation) (python-initial-text))
		  levels))
	  (while (python-beginning-of-block)
	    (when (or (not start)
		      (member (python-first-word)
			      (cdr (assoc start python-block-pairs))))
	      (push (cons (current-indentation) (python-initial-text))
		    levels))))))
      (prog1 (or levels (setq levels '((0 . ""))))
	(setq python-indent-list levels
	      python-indent-list-length (length python-indent-list))))))

;; This is basically what `python-indent-line' would be if we didn't
;; do the cycling.
(defun python-indent-line-1 (&optional leave)
  "Subroutine of `python-indent-line'.
Does non-repeated indentation.  LEAVE non-nil means leave
indentation if it is valid, i.e. one of the positions returned by
`python-calculate-indentation'."
  (let ((target (python-calculate-indentation))
	(pos (- (point-max) (point))))
    (if (or (= target (current-indentation))
	    ;; Maybe keep a valid indentation.
	    (and leave python-indent-list
		 (assq (current-indentation) python-indent-list)))
	(if (< (current-column) (current-indentation))
	    (back-to-indentation))
      (beginning-of-line)
      (delete-horizontal-space)
      (indent-to target)
      (if (> (- (point-max) pos) (point))
	  (goto-char (- (point-max) pos))))))

(defun python-indent-line ()
  "Indent current line as Python code.
When invoked via `indent-for-tab-command', cycle through possible
indentations for current line.  The cycle is broken by a command
different from `indent-for-tab-command', i.e. successive TABs do
the cycling."
  (interactive)
  (if (and (eq this-command 'indent-for-tab-command)
	   (eq last-command this-command))
      (if (= 1 python-indent-list-length)
	  (message "Sole indentation")
	(progn (setq python-indent-index
		     (% (1+ python-indent-index) python-indent-list-length))
	       (beginning-of-line)
	       (delete-horizontal-space)
	       (indent-to (car (nth python-indent-index python-indent-list)))
	       (if (python-block-end-p)
		   (let ((text (cdr (nth python-indent-index
					 python-indent-list))))
		     (if text
			 (message "Closes: %s" text))))))
    (python-indent-line-1)
    (setq python-indent-index (1- python-indent-list-length))))

(defun python-indent-region (start end)
  "`indent-region-function' for Python.
Leaves validly-indented lines alone, i.e. doesn't indent to
another valid position."
  (save-excursion
    (goto-char end)
    (setq end (point-marker))
    (goto-char start)
    (or (bolp) (forward-line 1))
    (while (< (point) end)
      (or (and (bolp) (eolp))
	  (python-indent-line-1 t))
      (forward-line 1))
    (move-marker end nil)))

(defun python-block-end-p ()
  "Non-nil if this is a line in a statement closing a block,
or a blank line indented to where it would close a block."
  (and (not (python-comment-line-p))
       (or (python-close-block-statement-p t)
	   (< (current-indentation)
	      (save-excursion
		(python-previous-statement)
		(current-indentation))))))

;;;; Movement.

;; Fixme:  Define {for,back}ward-sexp-function?  Maybe skip units like
;; block, statement, depending on context.

(defun python-beginning-of-defun ()
  "`beginning-of-defun-function' for Python.
Finds beginning of innermost nested class or method definition.
Returns the name of the definition found at the end, or nil if
reached start of buffer."
  (let ((ci (current-indentation))
	(def-re (rx line-start (0+ space) (or "def" "class") (1+ space)
		    (group (1+ (or word (syntax symbol))))))
	found lep) ;; def-line
    (if (python-comment-line-p)
	(setq ci most-positive-fixnum))
    (while (and (not (bobp)) (not found))
      ;; Treat bol at beginning of function as outside function so
      ;; that successive C-M-a makes progress backwards.
      ;;(setq def-line (looking-at def-re))
      (unless (bolp) (end-of-line))
      (setq lep (line-end-position))
      (if (and (re-search-backward def-re nil 'move)
	       ;; Must be less indented or matching top level, or
	       ;; equally indented if we started on a definition line.
	       (let ((in (current-indentation)))
		 (or (and (zerop ci) (zerop in))
		     (= lep (line-end-position)) ; on initial line
		     ;; Not sure why it was like this -- fails in case of
		     ;; last internal function followed by first
		     ;; non-def statement of the main body.
                     ;;(and def-line (= in ci))
		     (= in ci)
		     (< in ci)))
	       (not (python-in-string/comment)))
	  (setq found t)))))

(defun python-end-of-defun ()
  "`end-of-defun-function' for Python.
Finds end of innermost nested class or method definition."
  (let ((orig (point))
	(pattern (rx line-start (0+ space) (or "def" "class") space)))
    ;; Go to start of current block and check whether it's at top
    ;; level.  If it is, and not a block start, look forward for
    ;; definition statement.
    (when (python-comment-line-p)
      (end-of-line)
      (forward-comment most-positive-fixnum))
    (if (not (python-open-block-statement-p))
	(python-beginning-of-block))
    (if (zerop (current-indentation))
	(unless (python-open-block-statement-p)
	  (while (and (re-search-forward pattern nil 'move)
		      (python-in-string/comment))) ; just loop
	  (unless (eobp)
	    (beginning-of-line)))
      ;; Don't move before top-level statement that would end defun.
      (end-of-line)
      (python-beginning-of-defun))
    ;; If we got to the start of buffer, look forward for
    ;; definition statement.
    (if (and (bobp) (not (looking-at "def\\|class")))
	(while (and (not (eobp))
		    (re-search-forward pattern nil 'move)
		    (python-in-string/comment)))) ; just loop
    ;; We're at a definition statement (or end-of-buffer).
    (unless (eobp)
      (python-end-of-block)
      ;; Count trailing space in defun (but not trailing comments).
      (skip-syntax-forward " >")
      (unless (eobp)			; e.g. missing final newline
	(beginning-of-line)))
    ;; Catch pathological cases like this, where the beginning-of-defun
    ;; skips to a definition we're not in:
    ;; if ...:
    ;;     ...
    ;; else:
    ;;     ...  # point here
    ;;     ...
    ;;     def ...
    (if (< (point) orig)
	(goto-char (point-max)))))

(defun python-beginning-of-statement ()
  "Go to start of current statement.
Accounts for continuation lines, multi-line strings, and
multi-line bracketed expressions."
  (beginning-of-line)
  (python-beginning-of-string)
  (while (python-continuation-line-p)
    (beginning-of-line)
    (if (python-backslash-continuation-line-p)
	(progn
	  (forward-line -1)
	  (while (python-backslash-continuation-line-p)
	    (forward-line -1)))
      (python-beginning-of-string)
      (python-skip-out)))
  (back-to-indentation))

(defun python-skip-out (&optional forward syntax)
  "Skip out of any nested brackets.
Skip forward if FORWARD is non-nil, else backward.
If SYNTAX is non-nil it is the state returned by `syntax-ppss' at point.
Return non-nil iff skipping was done."
  (let ((depth (syntax-ppss-depth (or syntax (syntax-ppss))))
	(forward (if forward -1 1)))
    (unless (zerop depth)
      (if (> depth 0)
	  ;; Skip forward out of nested brackets.
	  (condition-case ()		; beware invalid syntax
	      (progn (backward-up-list (* forward depth)) t)
	    (error nil))
	;; Invalid syntax (too many closed brackets).
	;; Skip out of as many as possible.
	(let (done)
	  (while (condition-case ()
		     (progn (backward-up-list forward)
			    (setq done t))
		   (error nil)))
	  done)))))

(defun python-end-of-statement ()
  "Go to the end of the current statement and return point.
Usually this is the start of the next line, but if this is a
multi-line statement we need to skip over the continuation lines.
On a comment line, go to end of line."
  (end-of-line)
  (while (let (comment)
	   ;; Move past any enclosing strings and sexps, or stop if
	   ;; we're in a comment.
	   (while (let ((s (syntax-ppss)))
		    (cond ((eq 'comment (syntax-ppss-context s))
			   (setq comment t)
			   nil)
			  ((eq 'string (syntax-ppss-context s))
			   ;; Go to start of string and skip it.
                           (let ((pos (point)))
                             (goto-char (nth 8 s))
                             (condition-case () ; beware invalid syntax
                                 (progn (forward-sexp) t)
                               ;; If there's a mismatched string, make sure
                               ;; we still overall move *forward*.
                               (error (goto-char pos) (end-of-line)))))
			  ((python-skip-out t s))))
	     (end-of-line))
	   (unless comment
	     (eq ?\\ (char-before))))	; Line continued?
    (end-of-line 2))			; Try next line.
  (point))

(defun python-previous-statement (&optional count)
  "Go to start of previous statement.
With argument COUNT, do it COUNT times.  Stop at beginning of buffer.
Return count of statements left to move."
  (interactive "p")
  (unless count (setq count 1))
  (if (< count 0)
      (python-next-statement (- count))
    (python-beginning-of-statement)
    (while (and (> count 0) (not (bobp)))
      (python-skip-comments/blanks t)
      (python-beginning-of-statement)
      (unless (bobp) (setq count (1- count))))
    count))

(defun python-next-statement (&optional count)
  "Go to start of next statement.
With argument COUNT, do it COUNT times.  Stop at end of buffer.
Return count of statements left to move."
  (interactive "p")
  (unless count (setq count 1))
  (if (< count 0)
      (python-previous-statement (- count))
    (beginning-of-line)
    (while (and (> count 0) (not (eobp)))
      (python-end-of-statement)
      (python-skip-comments/blanks)
      (unless (eobp)
	(setq count (1- count))))
    count))

(defun python-beginning-of-block (&optional arg)
  "Go to start of current block.
With numeric arg, do it that many times.  If ARG is negative, call
`python-end-of-block' instead.
If point is on the first line of a block, use its outer block.
If current statement is in column zero, don't move and return nil.
Otherwise return non-nil."
  (interactive "p")
  (unless arg (setq arg 1))
  (cond
   ((zerop arg))
   ((< arg 0) (python-end-of-block (- arg)))
   (t
    (let ((point (point)))
      (if (or (python-comment-line-p)
	      (python-blank-line-p))
	  (python-skip-comments/blanks t))
      (python-beginning-of-statement)
      (let ((ci (current-indentation)))
	(if (zerop ci)
	    (not (goto-char point))	; return nil
	  ;; Look upwards for less indented statement.
	  (if (catch 'done
;;; This is slower than the below.
;;; 	  (while (zerop (python-previous-statement))
;;; 	    (when (and (< (current-indentation) ci)
;;; 		       (python-open-block-statement-p t))
;;; 	      (beginning-of-line)
;;; 	      (throw 'done t)))
		(while (and (zerop (forward-line -1)))
		  (when (and (< (current-indentation) ci)
			     (not (python-comment-line-p))
			     ;; Move to beginning to save effort in case
			     ;; this is in string.
			     (progn (python-beginning-of-statement) t)
			     (python-open-block-statement-p t))
		    (beginning-of-line)
		    (throw 'done t)))
		(not (goto-char point))) ; Failed -- return nil
	      (python-beginning-of-block (1- arg)))))))))

(defun python-end-of-block (&optional arg)
  "Go to end of current block.
With numeric arg, do it that many times.  If ARG is negative,
call `python-beginning-of-block' instead.
If current statement is in column zero and doesn't open a block,
don't move and return nil.  Otherwise return t."
  (interactive "p")
  (unless arg (setq arg 1))
  (if (< arg 0)
      (python-beginning-of-block (- arg))
    (while (and (> arg 0)
		(let* ((point (point))
		       (_ (if (python-comment-line-p)
			      (python-skip-comments/blanks t)))
		       (ci (current-indentation))
		       (open (python-open-block-statement-p)))
		  (if (and (zerop ci) (not open))
		      (not (goto-char point))
		    (catch 'done
                      (while (zerop (python-next-statement))
			(when (or (and open (<= (current-indentation) ci))
				  (< (current-indentation) ci))
			  (python-skip-comments/blanks t)
			  (beginning-of-line 2)
			  (throw 'done t)))))))
      (setq arg (1- arg)))
    (zerop arg)))

(defvar python-which-func-length-limit 40
  "Non-strict length limit for `python-which-func' output.")

(defun python-which-func ()
  (let ((function-name (python-current-defun python-which-func-length-limit)))
    (set-text-properties 0 (length function-name) nil function-name)
    function-name))


;;;; Imenu.

(defvar python-recursing)
(defun python-imenu-create-index ()
  "`imenu-create-index-function' for Python.

Makes nested Imenu menus from nested `class' and `def' statements.
The nested menus are headed by an item referencing the outer
definition; it has a space prepended to the name so that it sorts
first with `imenu--sort-by-name' (though, unfortunately, sub-menus
precede it)."
  (unless (boundp 'python-recursing)	; dynamically bound below
    ;; Normal call from Imenu.
    (goto-char (point-min))
    ;; Without this, we can get an infloop if the buffer isn't all
    ;; fontified.  I guess this is really a bug in syntax.el.  OTOH,
    ;; _with_ this, imenu doesn't immediately work; I can't figure out
    ;; what's going on, but it must be something to do with timers in
    ;; font-lock.
    ;; This can't be right, especially not when jit-lock is not used.  --Stef
    ;; (unless (get-text-property (1- (point-max)) 'fontified)
    ;;   (font-lock-fontify-region (point-min) (point-max)))
    )
  (let (index-alist)			; accumulated value to return
    (while (re-search-forward
	    (rx line-start (0+ space)	; leading space
		(or (group "def") (group "class"))	   ; type
		(1+ space) (group (1+ (or word ?_))))	   ; name
	    nil t)
      (unless (python-in-string/comment)
	(let ((pos (match-beginning 0))
	      (name (match-string-no-properties 3)))
	  (if (match-beginning 2)	; def or class?
	      (setq name (concat "class " name)))
	  (save-restriction
	    (narrow-to-defun)
	    (let* ((python-recursing t)
		   (sublist (python-imenu-create-index)))
	      (if sublist
		  (progn (push (cons (concat " " name) pos) sublist)
			 (push (cons name sublist) index-alist))
		(push (cons name pos) index-alist)))))))
    (unless (boundp 'python-recursing)
      ;; Look for module variables.
      (let (vars)
	(goto-char (point-min))
	(while (re-search-forward
		(rx line-start (group (1+ (or word ?_))) (0+ space) "=")
		nil t)
	  (unless (python-in-string/comment)
	    (push (cons (match-string 1) (match-beginning 1))
		  vars)))
	(setq index-alist (nreverse index-alist))
	(if vars
	    (push (cons "Module variables"
			(nreverse vars))
		  index-alist))))
    index-alist))

;;;; `Electric' commands.

(defun python-electric-colon (arg)
  "Insert a colon and maybe outdent the line if it is a statement like `else'.
With numeric ARG, just insert that many colons.  With \\[universal-argument],
just insert a single colon."
  (interactive "*P")
  (self-insert-command (if (not (integerp arg)) 1 arg))
  (and (not arg)
       (eolp)
       (python-outdent-p)
       (not (python-in-string/comment))
       (> (current-indentation) (python-calculate-indentation))
       (python-indent-line)))		; OK, do it
(put 'python-electric-colon 'delete-selection t)

(defun python-backspace (arg)
  "Maybe delete a level of indentation on the current line.
Do so if point is at the end of the line's indentation outside
strings and comments.
Otherwise just call `backward-delete-char-untabify'.
Repeat ARG times."
  (interactive "*p")
  (if (or (/= (current-indentation) (current-column))
	  (bolp)
	  (python-continuation-line-p)
	  (python-in-string/comment))
      (backward-delete-char-untabify arg)
    ;; Look for the largest valid indentation which is smaller than
    ;; the current indentation.
    (let ((indent 0)
	  (ci (current-indentation))
	  (indents (python-indentation-levels))
	  initial)
      (dolist (x indents)
	(if (< (car x) ci)
	    (setq indent (max indent (car x)))))
      (setq initial (cdr (assq indent indents)))
      (if (> (length initial) 0)
	  (message "Closes %s" initial))
      (delete-horizontal-space)
      (indent-to indent))))
(put 'python-backspace 'delete-selection 'supersede)

;;;; pychecker

(defcustom python-check-command "pychecker --stdlib"
  "Command used to check a Python file."
  :type 'string
  :group 'python)

(defvar python-saved-check-command nil
  "Internal use.")

;; After `sgml-validate-command'.
(defun python-check (command)
  "Check a Python file (default current buffer's file).
Runs COMMAND, a shell command, as if by `compile'.
See `python-check-command' for the default."
  (interactive
   (list (read-string "Checker command: "
		      (or python-saved-check-command
			  (concat python-check-command " "
				  (let ((name (buffer-file-name)))
				    (if name
					(file-name-nondirectory name))))))))
  (setq python-saved-check-command command)
  (require 'compile)                    ;To define compilation-* variables.
  (save-some-buffers (not compilation-ask-about-save) nil)
  (let ((compilation-error-regexp-alist
	 (cons '("(\\([^,]+\\), line \\([0-9]+\\))" 1 2)
	       compilation-error-regexp-alist)))
    (compilation-start command)))

;;;; Inferior mode stuff (following cmuscheme).

;; Fixme: Make sure we can work with IPython.

(defcustom python-python-command "python"
  "Shell command to run Python interpreter.
Any arguments can't contain whitespace.
Note that IPython may not work properly; it must at least be used
with the `-cl' flag, i.e. use `ipython -cl'."
  :group 'python
  :type 'string)

(defcustom python-jython-command "jython"
  "Shell command to run Jython interpreter.
Any arguments can't contain whitespace."
  :group 'python
  :type 'string)

(defvar python-command python-python-command
  "Actual command used to run Python.
May be `python-python-command' or `python-jython-command', possibly
modified by the user.  Additional arguments are added when the command
is used by `run-python' et al.")

(defvar python-buffer nil
  "*The current Python process buffer.

Commands that send text from source buffers to Python processes have
to choose a process to send to.  This is determined by buffer-local
value of `python-buffer'.  If its value in the current buffer,
i.e. both any local value and the default one, is nil, `run-python'
and commands that send to the Python process will start a new process.

Whenever \\[run-python] starts a new process, it resets the default
value of `python-buffer' to be the new process's buffer and sets the
buffer-local value similarly if the current buffer is in Python mode
or Inferior Python mode, so that source buffer stays associated with a
specific sub-process.

Use \\[python-set-proc] to set the default value from a buffer with a
local value.")
(make-variable-buffer-local 'python-buffer)

(defconst python-compilation-regexp-alist
  ;; FIXME: maybe these should move to compilation-error-regexp-alist-alist.
  ;;   The first already is (for CAML), but the second isn't.  Anyhow,
  ;;   these are specific to the inferior buffer.  -- fx
  `((,(rx line-start (1+ (any " \t")) "File \""
	  (group (1+ (not (any "\"<")))) ; avoid `<stdin>' &c
	  "\", line " (group (1+ digit)))
     1 2)
    (,(rx " in file " (group (1+ not-newline)) " on line "
	  (group (1+ digit)))
     1 2)
    ;; pdb stack trace
    (,(rx line-start "> " (group (1+ (not (any "(\"<"))))
	  "(" (group (1+ digit)) ")" (1+ (not (any "("))) "()")
     1 2))
  "`compilation-error-regexp-alist' for inferior Python.")

(defvar inferior-python-mode-map
  (let ((map (make-sparse-keymap)))
    ;; This will inherit from comint-mode-map.
    (define-key map "\C-c\C-l" 'python-load-file)
    (define-key map "\C-c\C-v" 'python-check)
    ;; Note that we _can_ still use these commands which send to the
    ;; Python process even at the prompt iff we have a normal prompt,
    ;; i.e. '>>> ' and not '... '.  See the comment before
    ;; python-send-region.  Fixme: uncomment these if we address that.

    ;; (define-key map [(meta ?\t)] 'python-complete-symbol)
    ;; (define-key map "\C-c\C-f" 'python-describe-symbol)
    map))

(defvar inferior-python-mode-syntax-table
  (let ((st (make-syntax-table python-mode-syntax-table)))
    ;; Don't get confused by apostrophes in the process's output (e.g. if
    ;; you execute "help(os)").
    (modify-syntax-entry ?\' "." st)
    ;; Maybe we should do the same for double quotes?
    ;; (modify-syntax-entry ?\" "." st)
    st))

;; Fixme: This should inherit some stuff from `python-mode', but I'm
;; not sure how much: at least some keybindings, like C-c C-f;
;; syntax?; font-locking, e.g. for triple-quoted strings?
(define-derived-mode inferior-python-mode comint-mode "Inferior Python"
  "Major mode for interacting with an inferior Python process.
A Python process can be started with \\[run-python].

Hooks `comint-mode-hook' and `inferior-python-mode-hook' are run in
that order.

You can send text to the inferior Python process from other buffers
containing Python source.
 * \\[python-switch-to-python] switches the current buffer to the Python
    process buffer.
 * \\[python-send-region] sends the current region to the Python process.
 * \\[python-send-region-and-go] switches to the Python process buffer
    after sending the text.
For running multiple processes in multiple buffers, see `run-python' and
`python-buffer'.

\\{inferior-python-mode-map}"
  :group 'python
  (setq mode-line-process '(":%s"))
  (set (make-local-variable 'comint-input-filter) 'python-input-filter)
  (add-hook 'comint-preoutput-filter-functions #'python-preoutput-filter
	    nil t)
  ;; Still required by `comint-redirect-send-command', for instance
  ;; (and we need to match things like `>>> ... >>> '):
  (set (make-local-variable 'comint-prompt-regexp)
       (rx line-start (1+ (and (or (repeat 3 (any ">.")) "(Pdb)") " "))))
  (set (make-local-variable 'compilation-error-regexp-alist)
       python-compilation-regexp-alist)
  (compilation-shell-minor-mode 1))

(defcustom inferior-python-filter-regexp "\\`\\s-*\\S-?\\S-?\\s-*\\'"
  "Input matching this regexp is not saved on the history list.
Default ignores all inputs of 0, 1, or 2 non-blank characters."
  :type 'regexp
  :group 'python)

(defun python-input-filter (str)
  "`comint-input-filter' function for inferior Python.
Don't save anything for STR matching `inferior-python-filter-regexp'."
  (not (string-match inferior-python-filter-regexp str)))

;; Fixme: Loses with quoted whitespace.
(defun python-args-to-list (string)
  (let ((where (string-match "[ \t]" string)))
    (cond ((null where) (list string))
	  ((not (= where 0))
	   (cons (substring string 0 where)
		 (python-args-to-list (substring string (+ 1 where)))))
	  (t (let ((pos (string-match "[^ \t]" string)))
	       (if pos (python-args-to-list (substring string pos))))))))

(defvar python-preoutput-result nil
  "Data from last `_emacs_out' line seen by the preoutput filter.")

(defvar python-preoutput-leftover nil)
(defvar python-preoutput-skip-next-prompt nil)

;; Using this stops us getting lines in the buffer like
;; >>> ... ... >>>
(defun python-preoutput-filter (s)
  "`comint-preoutput-filter-functions' function: ignore prompts not at bol."
  (when python-preoutput-leftover
    (setq s (concat python-preoutput-leftover s))
    (setq python-preoutput-leftover nil))
  (let ((start 0)
        (res ""))
    ;; First process whole lines.
    (while (string-match "\n" s start)
      (let ((line (substring s start (setq start (match-end 0)))))
        ;; Skip prompt if needed.
        (when (and python-preoutput-skip-next-prompt
                   (string-match comint-prompt-regexp line))
          (setq python-preoutput-skip-next-prompt nil)
          (setq line (substring line (match-end 0))))
        ;; Recognize special _emacs_out lines.
        (if (and (string-match "\\`_emacs_out \\(.*\\)\n\\'" line)
                 (local-variable-p 'python-preoutput-result))
            (progn
              (setq python-preoutput-result (match-string 1 line))
              (set (make-local-variable 'python-preoutput-skip-next-prompt) t))
          (setq res (concat res line)))))
    ;; Then process the remaining partial line.
    (unless (zerop start) (setq s (substring s start)))
    (cond ((and (string-match comint-prompt-regexp s)
                ;; Drop this prompt if it follows an _emacs_out...
                (or python-preoutput-skip-next-prompt
                    ;; ... or if it's not gonna be inserted at BOL.
                    ;; Maybe we could be more selective here.
                    (if (zerop (length res))
                        (not (bolp))
                      (string-match ".\\'" res))))
           ;; The need for this seems to be system-dependent:
           ;; What is this all about, exactly?  --Stef
           ;; (if (and (eq ?. (aref s 0)))
           ;;     (accept-process-output (get-buffer-process (current-buffer)) 1))
           (setq python-preoutput-skip-next-prompt nil)
           res)
          ((let ((end (min (length "_emacs_out ") (length s))))
             (eq t (compare-strings s nil end "_emacs_out " nil end)))
           ;; The leftover string is a prefix of _emacs_out so we don't know
           ;; yet whether it's an _emacs_out or something else: wait until we
           ;; get more output so we can resolve this ambiguity.
           (set (make-local-variable 'python-preoutput-leftover) s)
           res)
          (t (concat res s)))))

(autoload 'comint-check-proc "comint")

;;;###autoload
(defun run-python (&optional cmd noshow new)
  "Run an inferior Python process, input and output via buffer *Python*.
CMD is the Python command to run.  NOSHOW non-nil means don't show the
buffer automatically.

Normally, if there is a process already running in `python-buffer',
switch to that buffer.  Interactively, a prefix arg allows you to edit
the initial command line (default is `python-command'); `-i' etc. args
will be added to this as appropriate.  A new process is started if:
one isn't running attached to `python-buffer', or interactively the
default `python-command', or argument NEW is non-nil.  See also the
documentation for `python-buffer'.

Runs the hook `inferior-python-mode-hook' \(after the
`comint-mode-hook' is run).  \(Type \\[describe-mode] in the process
buffer for a list of commands.)"
  (interactive (if current-prefix-arg
		   (list (read-string "Run Python: " python-command) nil t)
		 (list python-command)))
  (unless cmd (setq cmd python-python-command))
  (setq python-command cmd)
  ;; Fixme: Consider making `python-buffer' buffer-local as a buffer
  ;; (not a name) in Python buffers from which `run-python' &c is
  ;; invoked.  Would support multiple processes better.
  (when (or new (not (comint-check-proc python-buffer)))
    (with-current-buffer
        (let* ((cmdlist (append (python-args-to-list cmd) '("-i")))
               (path (getenv "PYTHONPATH"))
               (process-environment	; to import emacs.py
                (cons (concat "PYTHONPATH=" data-directory
                              (if path (concat path-separator path)))
                      process-environment)))
          (apply 'make-comint-in-buffer "Python"
                 (if new (generate-new-buffer "*Python*") "*Python*")
                 (car cmdlist) nil (cdr cmdlist)))
      (setq-default python-buffer (current-buffer))
      (setq python-buffer (current-buffer))
      (accept-process-output (get-buffer-process python-buffer) 5)
      (inferior-python-mode)
      ;; Load function definitions we need.
      ;; Before the preoutput function was used, this was done via -c in
      ;; cmdlist, but that loses the banner and doesn't run the startup
      ;; file.  The code might be inline here, but there's enough that it
      ;; seems worth putting in a separate file, and it's probably cleaner
      ;; to put it in a module.
      ;; Ensure we're at a prompt before doing anything else.
      (python-send-receive "import emacs; print '_emacs_out ()'")))
  (if (derived-mode-p 'python-mode)
      (setq python-buffer (default-value 'python-buffer))) ; buffer-local
  ;; Without this, help output goes into the inferior python buffer if
  ;; the process isn't already running.
  (sit-for 1 t)        ;Should we use accept-process-output instead?  --Stef
  (unless noshow (pop-to-buffer python-buffer t)))

;; Fixme: We typically lose if the inferior isn't in the normal REPL,
;; e.g. prompt is `help> '.  Probably raise an error if the form of
;; the prompt is unexpected.  Actually, it needs to be `>>> ', not
;; `... ', i.e. we're not inputting a block &c.  However, this may not
;; be the place to check it, e.g. we might actually want to send
;; commands having set up such a state.

(defun python-send-command (command)
  "Like `python-send-string' but resets `compilation-shell-minor-mode'.
COMMAND should be a single statement."
  ;; (assert (not (string-match "\n" command)))
  ;; (let ((end (marker-position (process-mark (python-proc)))))
  (with-current-buffer (process-buffer (python-proc))
    (goto-char (point-max))
    (compilation-forget-errors)
    (python-send-string command)
    (setq compilation-last-buffer (current-buffer)))
    ;; No idea what this is for but it breaks the call to
    ;; compilation-fake-loc in python-send-region.  -- Stef
    ;; Must wait until this has completed before re-setting variables below.
    ;; (python-send-receive "print '_emacs_out ()'")
    ;; (with-current-buffer python-buffer
    ;;   (set-marker compilation-parsing-end end))
    ) ;;)

(defun python-send-region (start end)
  "Send the region to the inferior Python process."
  ;; The region is evaluated from a temporary file.  This avoids
  ;; problems with blank lines, which have different semantics
  ;; interactively and in files.  It also saves the inferior process
  ;; buffer filling up with interpreter prompts.  We need a Python
  ;; function to remove the temporary file when it has been evaluated
  ;; (though we could probably do it in Lisp with a Comint output
  ;; filter).  This function also catches exceptions and truncates
  ;; tracebacks not to mention the frame of the function itself.
  ;;
  ;; The `compilation-shell-minor-mode' parsing takes care of relating
  ;; the reference to the temporary file to the source.
  ;;
  ;; Fixme: Write a `coding' header to the temp file if the region is
  ;; non-ASCII.
  (interactive "r")
  (let* ((f (make-temp-file "py"))
	 (command (format "emacs.eexecfile(%S)" f))
	 (orig-start (copy-marker start)))
    (when (save-excursion
	    (goto-char start)
	    (/= 0 (current-indentation))) ; need dummy block
      (save-excursion
	(goto-char orig-start)
	;; Wrong if we had indented code at buffer start.
	(set-marker orig-start (line-beginning-position 0)))
      (write-region "if True:\n" nil f nil 'nomsg))
    (write-region start end f t 'nomsg)
    (python-send-command command)
    (with-current-buffer (process-buffer (python-proc))
      ;; Tell compile.el to redirect error locations in file `f' to
      ;; positions past marker `orig-start'.  It has to be done *after*
      ;; `python-send-command''s call to `compilation-forget-errors'.
      (compilation-fake-loc orig-start f))))

(defun python-send-string (string)
  "Evaluate STRING in inferior Python process."
  (interactive "sPython command: ")
  (comint-send-string (python-proc) string)
  (unless (string-match "\n\\'" string)
    ;; Make sure the text is properly LF-terminated.
    (comint-send-string (python-proc) "\n"))
  (when (string-match "\n[ \t].*\n?\\'" string)
    ;; If the string contains a final indented line, add a second newline so
    ;; as to make sure we terminate the multiline instruction.
    (comint-send-string (python-proc) "\n")))

(defun python-send-buffer ()
  "Send the current buffer to the inferior Python process."
  (interactive)
  (python-send-region (point-min) (point-max)))

;; Fixme: Try to define the function or class within the relevant
;; module, not just at top level.
(defun python-send-defun ()
  "Send the current defun (class or method) to the inferior Python process."
  (interactive)
  (save-excursion (python-send-region (progn (beginning-of-defun) (point))
				      (progn (end-of-defun) (point)))))

(defun python-switch-to-python (eob-p)
  "Switch to the Python process buffer, maybe starting new process.
With prefix arg, position cursor at end of buffer."
  (interactive "P")
  (pop-to-buffer (process-buffer (python-proc)) t) ;Runs python if needed.
  (when eob-p
    (push-mark)
    (goto-char (point-max))))

(defun python-send-region-and-go (start end)
  "Send the region to the inferior Python process.
Then switch to the process buffer."
  (interactive "r")
  (python-send-region start end)
  (python-switch-to-python t))

(defcustom python-source-modes '(python-mode jython-mode)
  "Used to determine if a buffer contains Python source code.
If a file is loaded into a buffer that is in one of these major modes,
it is considered Python source by `python-load-file', which uses the
value to determine defaults."
  :type '(repeat function)
  :group 'python)

(defvar python-prev-dir/file nil
  "Caches (directory . file) pair used in the last `python-load-file' command.
Used for determining the default in the next one.")

(autoload 'comint-get-source "comint")

(defun python-load-file (file-name)
  "Load a Python file FILE-NAME into the inferior Python process.
If the file has extension `.py' import or reload it as a module.
Treating it as a module keeps the global namespace clean, provides
function location information for debugging, and supports users of
module-qualified names."
  (interactive (comint-get-source "Load Python file: " python-prev-dir/file
				  python-source-modes
				  t))	; because execfile needs exact name
  (comint-check-source file-name)     ; Check to see if buffer needs saving.
  (setq python-prev-dir/file (cons (file-name-directory file-name)
				   (file-name-nondirectory file-name)))
  (with-current-buffer (process-buffer (python-proc)) ;Runs python if needed.
    ;; Fixme: I'm not convinced by this logic from python-mode.el.
    (python-send-command
     (if (string-match "\\.py\\'" file-name)
	 (let ((module (file-name-sans-extension
			(file-name-nondirectory file-name))))
	   (format "emacs.eimport(%S,%S)"
		   module (file-name-directory file-name)))
       (format "execfile(%S)" file-name)))
    (message "%s loaded" file-name)))

(defun python-proc ()
  "Return the current Python process.
See variable `python-buffer'.  Starts a new process if necessary."
  ;; Fixme: Maybe should look for another active process if there
  ;; isn't one for `python-buffer'.
  (unless (comint-check-proc python-buffer)
    (run-python nil t))
  (get-buffer-process (if (derived-mode-p 'inferior-python-mode)
                          (current-buffer)
                        python-buffer)))

(defun python-set-proc ()
  "Set the default value of `python-buffer' to correspond to this buffer.
If the current buffer has a local value of `python-buffer', set the
default (global) value to that.  The associated Python process is
the one that gets input from \\[python-send-region] et al when used
in a buffer that doesn't have a local value of `python-buffer'."
  (interactive)
  (if (local-variable-p 'python-buffer)
      (setq-default python-buffer python-buffer)
    (error "No local value of `python-buffer'")))

;;;; Context-sensitive help.

(defconst python-dotty-syntax-table
  (let ((table (make-syntax-table)))
    (set-char-table-parent table python-mode-syntax-table)
    (modify-syntax-entry ?. "_" table)
    table)
  "Syntax table giving `.' symbol syntax.
Otherwise inherits from `python-mode-syntax-table'.")

(defvar view-return-to-alist)
(eval-when-compile (autoload 'help-buffer "help-fns"))

(defvar python-imports)			; forward declaration

;; Fixme: Should this actually be used instead of info-look, i.e. be
;; bound to C-h S?  [Probably not, since info-look may work in cases
;; where this doesn't.]
(defun python-describe-symbol (symbol)
  "Get help on SYMBOL using `help'.
Interactively, prompt for symbol.

Symbol may be anything recognized by the interpreter's `help'
command -- e.g. `CALLS' -- not just variables in scope in the
interpreter.  This only works for Python version 2.2 or newer
since earlier interpreters don't support `help'.

In some cases where this doesn't find documentation, \\[info-lookup-symbol]
will."
  ;; Note that we do this in the inferior process, not a separate one, to
  ;; ensure the environment is appropriate.
  (interactive
   (let ((symbol (with-syntax-table python-dotty-syntax-table
		   (current-word)))
	 (enable-recursive-minibuffers t))
     (list (read-string (if symbol
			    (format "Describe symbol (default %s): " symbol)
			  "Describe symbol: ")
			nil nil symbol))))
  (if (equal symbol "") (error "No symbol"))
  ;; Ensure we have a suitable help buffer.
  ;; Fixme: Maybe process `Related help topics' a la help xrefs and
  ;; allow C-c C-f in help buffer.
  (let ((temp-buffer-show-hook		; avoid xref stuff
	 (lambda ()
	   (toggle-read-only 1)
	   (setq view-return-to-alist
		 (list (cons (selected-window) help-return-method))))))
    (with-output-to-temp-buffer (help-buffer)
      (with-current-buffer standard-output
 	;; Fixme: Is this actually useful?
	(help-setup-xref (list 'python-describe-symbol symbol) (interactive-p))
	(set (make-local-variable 'comint-redirect-subvert-readonly) t)
	(print-help-return-message))))
  (comint-redirect-send-command-to-process (format "emacs.ehelp(%S, %s)"
						   symbol python-imports)
   "*Help*" (python-proc) nil nil))

(add-to-list 'debug-ignored-errors "^No symbol")

(defun python-send-receive (string)
  "Send STRING to inferior Python (if any) and return result.
The result is what follows `_emacs_out' in the output."
  (python-send-string string)
  (let ((proc (python-proc)))
    (with-current-buffer (process-buffer proc)
      (set (make-local-variable 'python-preoutput-result) nil)
      (while (progn
               (accept-process-output proc 5)
               (null python-preoutput-result)))
      (prog1 python-preoutput-result
        (kill-local-variable 'python-preoutput-result)))))

;; Fixme:  Is there anything reasonable we can do with random methods?
;; (Currently only works with functions.)
(defun python-eldoc-function ()
  "`eldoc-print-current-symbol-info' for Python.
Only works when point is in a function name, not its arg list, for
instance.  Assumes an inferior Python is running."
  (let ((symbol (with-syntax-table python-dotty-syntax-table
		  (current-word))))
    ;; This is run from timers, so inhibit-quit tends to be set.
    (with-local-quit
      ;; First try the symbol we're on.
      (or (and symbol
               (python-send-receive (format "emacs.eargs(%S, %s)"
                                            symbol python-imports)))
          ;; Try moving to symbol before enclosing parens.
          (let ((s (syntax-ppss)))
            (unless (zerop (car s))
              (when (eq ?\( (char-after (nth 1 s)))
                (save-excursion
                  (goto-char (nth 1 s))
                  (skip-syntax-backward "-")
                  (let ((point (point)))
                    (skip-chars-backward "a-zA-Z._")
                    (if (< (point) point)
                        (python-send-receive
                         (format "emacs.eargs(%S, %s)"
                                 (buffer-substring-no-properties (point) point)
                                 python-imports))))))))))))

;;;; Info-look functionality.

(defun python-after-info-look ()
  "Set up info-look for Python.
Used with `eval-after-load'."
  (let* ((version (let ((s (shell-command-to-string (concat python-command
							    " -V"))))
		    (string-match "^Python \\([0-9]+\\.[0-9]+\\>\\)" s)
		    (match-string 1 s)))
	 ;; Whether info files have a Python version suffix, e.g. in Debian.
	 (versioned
	  (with-temp-buffer
	    (with-no-warnings (Info-mode))
	    (condition-case ()
		;; Don't use `info' because it would pop-up a *info* buffer.
		(with-no-warnings
		 (Info-goto-node (format "(python%s-lib)Miscellaneous Index"
					 version))
		 t)
	      (error nil)))))
    (info-lookup-maybe-add-help
     :mode 'python-mode
     :regexp "[[:alnum:]_]+"
     :doc-spec
     ;; Fixme: Can this reasonably be made specific to indices with
     ;; different rules?  Is the order of indices optimal?
     ;; (Miscellaneous in -ref first prefers lookup of keywords, for
     ;; instance.)
     (if versioned
	 ;; The empty prefix just gets us highlighted terms.
	 `((,(concat "(python" version "-ref)Miscellaneous Index") nil "")
	   (,(concat "(python" version "-ref)Module Index" nil ""))
	   (,(concat "(python" version "-ref)Function-Method-Variable Index"
		     nil ""))
	   (,(concat "(python" version "-ref)Class-Exception-Object Index"
		     nil ""))
	   (,(concat "(python" version "-lib)Module Index" nil ""))
	   (,(concat "(python" version "-lib)Class-Exception-Object Index"
		     nil ""))
	   (,(concat "(python" version "-lib)Function-Method-Variable Index"
		     nil ""))
	   (,(concat "(python" version "-lib)Miscellaneous Index" nil "")))
       '(("(python-ref)Miscellaneous Index" nil "")
	 ("(python-ref)Module Index" nil "")
	 ("(python-ref)Function-Method-Variable Index" nil "")
	 ("(python-ref)Class-Exception-Object Index" nil "")
	 ("(python-lib)Module Index" nil "")
	 ("(python-lib)Class-Exception-Object Index" nil "")
	 ("(python-lib)Function-Method-Variable Index" nil "")
	 ("(python-lib)Miscellaneous Index" nil ""))))))
(eval-after-load "info-look" '(python-after-info-look))

;;;; Miscellany.

(defcustom python-jython-packages '("java" "javax" "org" "com")
  "Packages implying `jython-mode'.
If these are imported near the beginning of the buffer, `python-mode'
actually punts to `jython-mode'."
  :type '(repeat string)
  :group 'python)

;; Called from `python-mode', this causes a recursive call of the
;; mode.  See logic there to break out of the recursion.
(defun python-maybe-jython ()
  "Invoke `jython-mode' if the buffer appears to contain Jython code.
The criterion is either a match for `jython-mode' via
`interpreter-mode-alist' or an import of a module from the list
`python-jython-packages'."
  ;; The logic is taken from python-mode.el.
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (let ((interpreter (if (looking-at auto-mode-interpreter-regexp)
			     (match-string 2))))
	(if (and interpreter (eq 'jython-mode
				 (cdr (assoc (file-name-nondirectory
					      interpreter)
					     interpreter-mode-alist))))
	    (jython-mode)
	  (if (catch 'done
		(while (re-search-forward
			(rx line-start (or "import" "from") (1+ space)
			    (group (1+ (not (any " \t\n.")))))
			(+ (point-min) 10000) ; Probably not worth customizing.
			t)
		  (if (member (match-string 1) python-jython-packages)
		      (throw 'done t))))
	      (jython-mode)))))))

(defun python-fill-paragraph (&optional justify)
  "`fill-paragraph-function' handling multi-line strings and possibly comments.
If any of the current line is in or at the end of a multi-line string,
fill the string or the paragraph of it that point is in, preserving
the strings's indentation."
  (interactive "P")
  (or (fill-comment-paragraph justify)
      (save-excursion
	(end-of-line)
	(let* ((syntax (syntax-ppss))
	       (orig (point))
	       start end)
	  (cond ((nth 4 syntax)	; comment.   fixme: loses with trailing one
		 (let (fill-paragraph-function)
		   (fill-paragraph justify)))
		;; The `paragraph-start' and `paragraph-separate'
		;; variables don't allow us to delimit the last
		;; paragraph in a multi-line string properly, so narrow
		;; to the string and then fill around (the end of) the
		;; current line.
		((eq t (nth 3 syntax))      ; in fenced string
		 (goto-char (nth 8 syntax)) ; string start
		 (setq start (line-beginning-position))
		 (setq end (condition-case () ; for unbalanced quotes
                               (progn (forward-sexp)
                                      (- (point) 3))
                             (error (point-max)))))
		((re-search-backward "\\s|\\s-*\\=" nil t) ; end of fenced string
		 (forward-char)
		 (setq end (point))
		 (condition-case ()
		     (progn (backward-sexp)
			    (setq start (line-beginning-position)))
		   (error nil))))
	  (when end
	    (save-restriction
	      (narrow-to-region start end)
	      (goto-char orig)
	      ;; Avoid losing leading and trailing newlines in doc
	      ;; strings written like:
	      ;;   """
	      ;;   ...
	      ;;   """
	      (let* ((paragraph-separate
		      (concat ".*\\s|\"\"$" ; newline after opening quotes
			      "\\|\\(?:" paragraph-separate "\\)"))
		     (paragraph-start
		      (concat ".*\\s|\"\"[ \t]*[^ \t].*" ; not newline after
					; opening quotes
			      "\\|\\(?:" paragraph-separate "\\)"))
		     (fill-paragraph-function))
		(fill-paragraph justify))))))) t)

(defun python-shift-left (start end &optional count)
  "Shift lines in region COUNT (the prefix arg) columns to the left.
COUNT defaults to `python-indent'.  If region isn't active, just shift
current line.  The region shifted includes the lines in which START and
END lie.  It is an error if any lines in the region are indented less than
COUNT columns."
  (interactive (if mark-active
		   (list (region-beginning) (region-end) current-prefix-arg)
		 (list (point) (point) current-prefix-arg)))
  (if count
      (setq count (prefix-numeric-value count))
    (setq count python-indent))
  (when (> count 0)
    (save-excursion
      (goto-char start)
      (while (< (point) end)
	(if (and (< (current-indentation) count)
		 (not (looking-at "[ \t]*$")))
	    (error "Can't shift all lines enough"))
	(forward-line))
      (indent-rigidly start end (- count)))))

(add-to-list 'debug-ignored-errors "^Can't shift all lines enough")

(defun python-shift-right (start end &optional count)
  "Shift lines in region COUNT (the prefix arg) columns to the right.
COUNT defaults to `python-indent'.  If region isn't active, just shift
current line.  The region shifted includes the lines in which START and
END lie."
  (interactive (if mark-active
		   (list (region-beginning) (region-end) current-prefix-arg)
		 (list (point) (point) current-prefix-arg)))
  (if count
      (setq count (prefix-numeric-value count))
    (setq count python-indent))
  (indent-rigidly start end count))

(defun python-outline-level ()
  "`outline-level' function for Python mode.
The level is the number of `python-indent' steps of indentation
of current line."
  (1+ (/ (current-indentation) python-indent)))

;; Fixme: Consider top-level assignments, imports, &c.
(defun python-current-defun (&optional length-limit)
  "`add-log-current-defun-function' for Python."
  (save-excursion
    ;; Move up the tree of nested `class' and `def' blocks until we
    ;; get to zero indentation, accumulating the defined names.
    (let ((accum)
	  (length -1))
      (catch 'done
	(while (or (null length-limit)
		   (null (cdr accum))
		   (< length length-limit))
	  (setq start nil)
	  (let ((started-from (point)))
	    (python-beginning-of-block)
	    (end-of-line)
	    (beginning-of-defun)
	    (when (= (point) started-from)
	      (throw 'done nil)))
	  (when (looking-at (rx (0+ space) (or "def" "class") (1+ space)
				(group (1+ (or word (syntax symbol))))))
	    (push (match-string 1) accum)
	    (setq length (+ length 1 (length (car accum)))))
	  (when (= (current-indentation) 0)
	    (throw 'done nil))))
      (when accum
	(when (and length-limit (> length length-limit))
	  (setcar accum ".."))
	(mapconcat 'identity accum ".")))))

(defun python-mark-block ()
  "Mark the block around point.
Uses `python-beginning-of-block', `python-end-of-block'."
  (interactive)
  (push-mark)
  (python-beginning-of-block)
  (push-mark (point) nil t)
  (python-end-of-block)
  (exchange-point-and-mark))

;; Fixme:  Provide a find-function-like command to find source of a
;; definition (separate from BicycleRepairMan).  Complicated by
;; finding the right qualified name.

;;;; Completion.

(defvar python-imports nil
  "String of top-level import statements updated by `python-find-imports'.")
(make-variable-buffer-local 'python-imports)

;; Fixme: Should font-lock try to run this when it deals with an import?
;; Maybe not a good idea if it gets run multiple times when the
;; statement is being edited, and is more likely to end up with
;; something syntactically incorrect.
;; However, what we should do is to trundle up the block tree from point
;; to extract imports that appear to be in scope, and add those.
(defun python-find-imports ()
  "Find top-level imports, updating `python-imports'."
  (interactive)
  (save-excursion
      (let (lines)
	(goto-char (point-min))
	(while (re-search-forward "^import\\>\\|^from\\>" nil t)
	  (unless (syntax-ppss-context (syntax-ppss))
	    (let ((start (line-beginning-position)))
	      ;; Skip over continued lines.
	      (while (and (eq ?\\ (char-before (line-end-position)))
			  (= 0 (forward-line 1))))
	      (push (buffer-substring start (line-beginning-position 2))
		    lines))))
	(setq python-imports
	      (if lines
		  (apply #'concat
;; This is probably best left out since you're unlikely to need the
;; doc for a function in the buffer and the import will lose if the
;; Python sub-process' working directory isn't the same as the
;; buffer's.
;; 			 (if buffer-file-name
;; 			     (concat
;; 			      "import "
;; 			      (file-name-sans-extension
;; 			       (file-name-nondirectory buffer-file-name))))
			 (nreverse lines))
		"None"))
	(when lines
	  (set-text-properties 0 (length python-imports) nil python-imports)
	  ;; The output ends up in the wrong place if the string we
	  ;; send contains newlines (from the imports).
	  (setq python-imports
		(replace-regexp-in-string "\n" "\\n"
					  (format "%S" python-imports) t t))))))

;; Fixme: This fails the first time if the sub-process isn't already
;; running.  Presumably a timing issue with i/o to the process.
(defun python-symbol-completions (symbol)
  "Return a list of completions of the string SYMBOL from Python process.
The list is sorted.
Uses `python-imports' to load modules against which to complete."
  (when symbol
    (let ((completions
	   (condition-case ()
	       (car (read-from-string
		     (python-send-receive
		      (format "emacs.complete(%S,%s)" symbol python-imports))))
	     (error nil))))
      (sort
       ;; We can get duplicates from the above -- don't know why.
       (delete-dups completions)
       #'string<))))

(defun python-partial-symbol ()
  "Return the partial symbol before point (for completion)."
  (let ((end (point))
	(start (save-excursion
		 (and (re-search-backward
		       (rx (or buffer-start (regexp "[^[:alnum:]._]"))
			   (group (1+ (regexp "[[:alnum:]._]"))) point)
		       nil t)
		      (match-beginning 1)))))
    (if start (buffer-substring-no-properties start end))))

(defun python-complete-symbol ()
  "Perform completion on the Python symbol preceding point.
Repeating the command scrolls the completion window."
  (interactive)
  (let ((window (get-buffer-window "*Completions*")))
    (if (and (eq last-command this-command)
	     (window-live-p window) (window-buffer window)
	     (buffer-name (window-buffer window)))
	(with-current-buffer (window-buffer window)
	  (if (pos-visible-in-window-p (point-max) window)
	      (set-window-start window (point-min))
	    (save-selected-window
	      (select-window window)
	      (scroll-up))))
      ;; Do completion.
      (let* ((end (point))
	     (symbol (python-partial-symbol))
	     (completions (python-symbol-completions symbol))
	     (completion (if completions
			     (try-completion symbol completions))))
	(when symbol
	  (cond ((eq completion t))
		((null completion)
		 (message "Can't find completion for \"%s\"" symbol)
		 (ding))
		((not (string= symbol completion))
		 (delete-region (- end (length symbol)) end)
		 (insert completion))
		(t
		 (message "Making completion list...")
		 (with-output-to-temp-buffer "*Completions*"
		   (display-completion-list completions symbol))
		 (message "Making completion list...%s" "done"))))))))

(defun python-try-complete (old)
  "Completion function for Python for use with `hippie-expand'."
  (when (derived-mode-p 'python-mode)	; though we only add it locally
    (unless old
      (let ((symbol (python-partial-symbol)))
	(he-init-string (- (point) (length symbol)) (point))
	(if (not (he-string-member he-search-string he-tried-table))
	    (push he-search-string he-tried-table))
	(setq he-expand-list
	      (and symbol (python-symbol-completions symbol)))))
    (while (and he-expand-list
		(he-string-member (car he-expand-list) he-tried-table))
      (pop he-expand-list))
    (if he-expand-list
	(progn
	  (he-substitute-string (pop he-expand-list))
	  t)
      (if old (he-reset-string))
      nil)))

;;;; FFAP support

(defun python-module-path (module)
  "Function for `ffap-alist' to return path to MODULE."
  (python-send-receive (format "emacs.modpath (%S)" module)))

(eval-after-load "ffap"
  '(push '(python-mode . python-module-path) ffap-alist))

;;;; Skeletons

(defcustom python-use-skeletons nil
  "Non-nil means template skeletons will be automagically inserted.
This happens when pressing \"if<SPACE>\", for example, to prompt for
the if condition."
  :type 'boolean
  :group 'python)

(defvar python-skeletons nil
  "Alist of named skeletons for Python mode.
Elements are of the form (NAME . EXPANDER-FUNCTION).")

(defvar python-mode-abbrev-table nil
  "Abbrev table for Python mode.
The default contents correspond to the elements of `python-skeletons'.")
(define-abbrev-table 'python-mode-abbrev-table ())

(eval-when-compile
  ;; Define a user-level skeleton and add it to `python-skeletons' and
  ;; the abbrev table.
(defmacro def-python-skeleton (name &rest elements)
  (let* ((name (symbol-name name))
	 (function (intern (concat "python-insert-" name))))
    `(progn
       (add-to-list 'python-skeletons ',(cons name function))
       (if python-use-skeletons
	   (define-abbrev python-mode-abbrev-table ,name "" ',function nil t))
       (define-skeleton ,function
	 ,(format "Insert Python \"%s\" template." name)
	 ,@elements)))))
(put 'def-python-skeleton 'lisp-indent-function 2)

;; From `skeleton-further-elements':
;;  `<': outdent a level;
;;  `^': delete indentation on current line and also previous newline.
;;       Not quote like `delete-indentation'.  Assumes point is at
;;       beginning of indentation.

(def-python-skeleton if
  "Condition: "
  "if " str ":" \n
  > _ \n
  ("other condition, %s: "
   <			; Avoid wrong indentation after block opening.
   "elif " str ":" \n
   > _ \n nil)
  (python-else) | ^)

(define-skeleton python-else
  "Auxiliary skeleton."
  nil
  (unless (eq ?y (read-char "Add `else' clause? (y for yes or RET for no) "))
    (signal 'quit t))
  < "else:" \n
  > _ \n)

(def-python-skeleton while
  "Condition: "
  "while " str ":" \n
  > _ \n
  (python-else) | ^)

(def-python-skeleton for
  "Target, %s: "
  "for " str " in " (skeleton-read "Expression, %s: ") ":" \n
  > _ \n
  (python-else) | ^)

(def-python-skeleton try/except
  nil
  "try:" \n
  > _ \n
  ("Exception, %s: "
   < "except " str (python-target) ":" \n
   > _ \n nil)
  < "except:" \n
  > _ \n
  (python-else) | ^)

(define-skeleton python-target
  "Auxiliary skeleton."
  "Target, %s: " ", " str | -2)

(def-python-skeleton try/finally
  nil
  "try:" \n
  > _ \n
  < "finally:" \n
  > _ \n)

(def-python-skeleton def
  "Name: "
  "def " str " (" ("Parameter, %s: " (unless (equal ?\( (char-before)) ", ")
		     str) "):" \n
  "\"\"\"" @ " \"\"\"" \n	    ; Fixme: syntaxification wrong for """"""
  > _ \n)

(def-python-skeleton class
  "Name: "
  "class " str " (" ("Inheritance, %s: "
		     (unless (equal ?\( (char-before)) ", ")
		     str)
  & ")" | -2				; close list or remove opening
  ":" \n
  "\"\"\"" @ " \"\"\"" \n
  > _ \n)

(defvar python-default-template "if"
  "Default template to expand by `python-expand-template'.
Updated on each expansion.")

(defun python-expand-template (name)
  "Expand template named NAME.
Interactively, prompt for the name with completion."
  (interactive
   (list (completing-read (format "Template to expand (default %s): "
				  python-default-template)
			  python-skeletons nil t)))
  (if (equal "" name)
      (setq name python-default-template)
    (setq python-default-template name))
  (let ((func (cdr (assoc name python-skeletons))))
    (if func
	(funcall func)
      (error "Undefined template: %s" name))))

;;;; Bicycle Repair Man support

(autoload 'pymacs-load "pymacs" nil t)
(autoload 'brm-init "bikemacs")

;; I'm not sure how useful BRM really is, and it's certainly dangerous
;; the way it modifies files outside Emacs...  Also note that the
;; current BRM loses with tabs used for indentation -- I submitted a
;; fix <URL:http://www.loveshack.ukfsn.org/emacs/bikeemacs.py.diff>.
(defun python-setup-brm ()
  "Set up Bicycle Repair Man refactoring tool (if available).

Note that the `refactoring' features change files independently of
Emacs and may modify and save the contents of the current buffer
without confirmation."
  (interactive)
  (condition-case data
      (unless (fboundp 'brm-rename)
	(pymacs-load "bikeemacs" "brm-") ; first line of normal recipe
	(let ((py-mode-map (make-sparse-keymap)) ; it assumes this
	      (features (cons 'python-mode features))) ; and requires this
	  (brm-init))			; second line of normal recipe
        (remove-hook 'python-mode-hook ; undo this from `brm-init'
                     '(lambda () (easy-menu-add brm-menu)))
        (easy-menu-define
          python-brm-menu python-mode-map
          "Bicycle Repair Man"
          '("BicycleRepairMan"
            :help "Interface to navigation and refactoring tool"
            "Queries"
            ["Find References" brm-find-references
             :help "Find references to name at point in compilation buffer"]
            ["Find Definition" brm-find-definition
             :help "Find definition of name at point"]
            "-"
            "Refactoring"
            ["Rename" brm-rename
             :help "Replace name at point with a new name everywhere"]
            ["Extract Method" brm-extract-method
             :active (and mark-active (not buffer-read-only))
             :help "Replace statements in region with a method"]
            ["Extract Local Variable" brm-extract-local-variable
             :active (and mark-active (not buffer-read-only))
             :help "Replace expression in region with an assignment"]
            ["Inline Local Variable" brm-inline-local-variable
             :help
             "Substitute uses of variable at point with its definition"]
            ;; Fixme:  Should check for anything to revert.
            ["Undo Last Refactoring" brm-undo :help ""])))
    (error (error "Bicyclerepairman setup failed: %s" data))))

;;;; Modes.

(defvar outline-heading-end-regexp)
(defvar eldoc-documentation-function)

;; Stuff to allow expanding abbrevs with non-word constituents.
(defun python-abbrev-pc-hook ()
  "Set the syntax table before possibly expanding abbrevs."
  (remove-hook 'post-command-hook 'python-abbrev-pc-hook t)
  (set-syntax-table python-mode-syntax-table))

(defvar python-abbrev-syntax-table
  (copy-syntax-table python-mode-syntax-table)
  "Syntax table used when expanding abbrevs.")

(defun python-pea-hook ()
  "Reset the syntax table after possibly expanding abbrevs."
  (set-syntax-table python-abbrev-syntax-table)
  (add-hook 'post-command-hook 'python-abbrev-pc-hook nil t))
(modify-syntax-entry ?/ "w" python-abbrev-syntax-table)

(defvar python-mode-running)            ;Dynamically scoped var.

;;;###autoload
(define-derived-mode python-mode fundamental-mode "Python"
  "Major mode for editing Python files.
Font Lock mode is currently required for correct parsing of the source.
See also `jython-mode', which is actually invoked if the buffer appears to
contain Jython code.  See also `run-python' and associated Python mode
commands for running Python under Emacs.

The Emacs commands which work with `defun's, e.g. \\[beginning-of-defun], deal
with nested `def' and `class' blocks.  They take the innermost one as
current without distinguishing method and class definitions.  Used multiple
times, they move over others at the same indentation level until they reach
the end of definitions at that level, when they move up a level.
\\<python-mode-map>
Colon is electric: it outdents the line if appropriate, e.g. for
an else statement.  \\[python-backspace] at the beginning of an indented statement
deletes a level of indentation to close the current block; otherwise it
deletes a character backward.  TAB indents the current line relative to
the preceding code.  Successive TABs, with no intervening command, cycle
through the possibilities for indentation on the basis of enclosing blocks.

\\[fill-paragraph] fills comments and multi-line strings appropriately, but has no
effect outside them.

Supports Eldoc mode (only for functions, using a Python process),
Info-Look and Imenu.  In Outline minor mode, `class' and `def'
lines count as headers.  Symbol completion is available in the
same way as in the Python shell using the `rlcompleter' module
and this is added to the Hippie Expand functions locally if
Hippie Expand mode is turned on.  Completion of symbols of the
form x.y only works if the components are literal
module/attribute names, not variables.  An abbrev table is set up
with skeleton expansions for compound statement templates.

\\{python-mode-map}"
  :group 'python
  (set (make-local-variable 'font-lock-defaults)
       '(python-font-lock-keywords nil nil nil nil
				   (font-lock-syntactic-keywords
				    . python-font-lock-syntactic-keywords)
				   ;; This probably isn't worth it.
				   ;; (font-lock-syntactic-face-function
				   ;;  . python-font-lock-syntactic-face-function)
				   ))
  (set (make-local-variable 'parse-sexp-lookup-properties) t)
  (set (make-local-variable 'parse-sexp-ignore-comments) t)
  (set (make-local-variable 'comment-start) "# ")
  (set (make-local-variable 'indent-line-function) #'python-indent-line)
  (set (make-local-variable 'indent-region-function) #'python-indent-region)
  (set (make-local-variable 'paragraph-start) "\\s-*$")
  (set (make-local-variable 'fill-paragraph-function) 'python-fill-paragraph)
  (set (make-local-variable 'require-final-newline) mode-require-final-newline)
  (set (make-local-variable 'add-log-current-defun-function)
       #'python-current-defun)
  (set (make-local-variable 'outline-regexp)
       (rx (* space) (or "class" "def" "elif" "else" "except" "finally"
			 "for" "if" "try" "while" "with")
	   symbol-end))
  (set (make-local-variable 'outline-heading-end-regexp) ":\\s-*\n")
  (set (make-local-variable 'outline-level) #'python-outline-level)
  (set (make-local-variable 'open-paren-in-column-0-is-defun-start) nil)
  (make-local-variable 'python-saved-check-command)
  (set (make-local-variable 'beginning-of-defun-function)
       'python-beginning-of-defun)
  (set (make-local-variable 'end-of-defun-function) 'python-end-of-defun)
  (add-hook 'which-func-functions 'python-which-func nil t)
  (setq imenu-create-index-function #'python-imenu-create-index)
  (set (make-local-variable 'eldoc-documentation-function)
       #'python-eldoc-function)
  (add-hook 'eldoc-mode-hook
	    (lambda () (run-python nil t)) ; need it running
	    nil t)
  ;; Fixme: should be in hideshow.  This seems to be of limited use
  ;; since it isn't (can't be) indentation-based.  Also hide-level
  ;; doesn't seem to work properly.
  (add-to-list 'hs-special-modes-alist
	       `(python-mode "^\\s-*\\(?:def\\|class\\)\\>" nil "#"
		 ,(lambda (arg)
		   (python-end-of-defun)
		   (skip-chars-backward " \t\n"))
		 nil))
  (set (make-local-variable 'skeleton-further-elements)
       '((< '(backward-delete-char-untabify (min python-indent
						 (current-column))))
	 (^ '(- (1+ (current-indentation))))))
  (add-hook 'pre-abbrev-expand-hook 'python-pea-hook nil t)
  (if (featurep 'hippie-exp)
      (set (make-local-variable 'hippie-expand-try-functions-list)
	   (cons 'python-try-complete hippie-expand-try-functions-list)))
  ;; Python defines TABs as being 8-char wide.
  (set (make-local-variable 'tab-width) 8)
  (when python-guess-indent (python-guess-indent))
  ;; Let's make it harder for the user to shoot himself in the foot.
  (unless (= tab-width python-indent)
    (setq indent-tabs-mode nil))
  (set (make-local-variable 'python-command) python-python-command)
  (python-find-imports)
  (unless (boundp 'python-mode-running)	; kill the recursion from jython-mode
    (let ((python-mode-running t))
      (python-maybe-jython))))

(custom-add-option 'python-mode-hook 'imenu-add-menubar-index)
(custom-add-option 'python-mode-hook
		   (lambda ()
                     "Turn off Indent Tabs mode."
                     (set (make-local-variable 'indent-tabs-mode) nil)))
(custom-add-option 'python-mode-hook 'turn-on-eldoc-mode)
(custom-add-option 'python-mode-hook 'abbrev-mode)
(custom-add-option 'python-mode-hook 'python-setup-brm)

;;;###autoload
(define-derived-mode jython-mode python-mode  "Jython"
  "Major mode for editing Jython files.
Like `python-mode', but sets up parameters for Jython subprocesses.
Runs `jython-mode-hook' after `python-mode-hook'."
  :group 'python
  (set (make-local-variable 'python-command) python-jython-command))

(provide 'python)
(provide 'python-21)
;; arch-tag: 6fce1d99-a704-4de9-ba19-c6e4912b0554
;;; python.el ends here
