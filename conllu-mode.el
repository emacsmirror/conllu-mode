;;; conllu-mode.el --- editing mode for CoNLL-U files  -*- lexical-binding: t; -*-
;; Copyright (C) 2018 bruno cuconato

;; Author: bruno cuconato <bcclaro+emacs@gmail.com>
;; Maintainer: bruno cuconato <bcclaro+emacs@gmail.com>
;; URL: https://github.com/odanoburu/conllu-mode
;; Version: 0.5.0
;; Package-Requires: ((emacs "25") (cl-lib "0.5") (flycheck "30") (hydra "0.13.0") (s "1.0"))
;; Keywords: extensions

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
;; this mode provides simple utilities for editing and viewing CoNLL-U
;; files.

;; it offers the following features, and more:

;; - highlighting comments, and upostag and deprel fields
;; - truncate lines by default
;; - show newline and tab characters using whitespace.el
;; - aligning and unaligning column fields
;; - jumping to next or previous sentence
;; - in a token line, jump to its head

;;; Code:

;;;
;; dependencies
(require 'whitespace)

(require 'conllu-align)
(require 'conllu-edit)
(require 'conllu-flycheck)
(require 'conllu-move)
(require 'conllu-parse)
(require 'conllu-thing)



;;;
;; customizable
(defgroup conllu nil
  "Support for CoNLL-U files."
  :group 'data
  :link  '(url-link "http://universaldependencies.org/format.html"))

(defcustom conllu-tab-width
  2
  "Width of a tab in ‘conllu-mode’."
  :type 'integer
  :group 'conllu)

(defcustom conllu-command-buffer
  "*conllu-command-output*"
  "Buffer to use for ‘conllu-command’ output."
  :type 'string
  :group 'conllu)

(defcustom conllu-default-command
  nil
  "Default command run by ‘conllu-command’."
  :type '(choice string nil)
  :group 'conllu)

;;;
;; keymap
(defvar conllu-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [(control ?c) (control ?a)] #'conllu-align-fields)
    (define-key map [(control ?c) (control ?c)] #'conllu-clear-field)
    (define-key map [(control ?c) (control ?e)] #'conllu-edit-hydra/body)
    (define-key map [(control ?c) (control ?h)] #'conllu-move-to-head)
    (define-key map [(control ?c) (control ?l)] #'conllu-insert-token-line)
    (define-key map [(control ?c) (control ?u)] #'conllu-unalign-fields)
    (define-key map [(control ?c) (control ?!)] #'conllu-command)
    (define-key map [(control ?c) ?1] #'conllu-move-to-field-number-1)
    (define-key map [(control ?c) ?2] #'conllu-move-to-field-number-2)
    (define-key map [(control ?c) ?3] #'conllu-move-to-field-number-3)
    (define-key map [(control ?c) ?4] #'conllu-move-to-field-number-4)
    (define-key map [(control ?c) ?5] #'conllu-move-to-field-number-5)
    (define-key map [(control ?c) ?6] #'conllu-move-to-field-number-6)
    (define-key map [(control ?c) ?7] #'conllu-move-to-field-number-7)
    (define-key map [(control ?c) ?8] #'conllu-move-to-field-number-8)
    (define-key map [(control ?c) ?9] #'conllu-move-to-field-number-9)
    (define-key map [(control ?c) ?0] #'conllu-move-to-field-number-10)
    (define-key map [(meta ?a)] #'conllu-previous-sentence)
    (define-key map [(meta ?e)] #'conllu-next-sentence)
    (define-key map [(meta ?n)] #'conllu-next-sentence)
    (define-key map [(meta ?p)] #'conllu-previous-sentence)
    map)
  "Keymap for ‘conllu-mode’.")

;;;
;; syntax table
(defvar conllu-mode-syntax-table
  (let ((st (make-syntax-table)))
    (modify-syntax-entry ?_ "w" st) ; _ is (part of) word, not whitespace
    (modify-syntax-entry ?, "w" st)
    (modify-syntax-entry ?. "w" st)
    (modify-syntax-entry ?\" "w" st)
    (modify-syntax-entry ?# "<" st) ; begins comment
    (modify-syntax-entry ?\n ">" st) ; ends comment
    st)
  "Syntax table for ‘conllu-mode’.")

;;;
;; fonts
(defvar conllu-upos-values
  '("ADJ" "ADP" "ADV" "AUX" "CCONJ" "DET" "INTJ" "NOUN" "NUM" "PART" "PRON" "PROPN" "PUNCT" "SCONJ" "SYM" "VERB" "X")
  "List possible upostag values.")

(defvar conllu-deprel-values
  '("acl" "advcl" "advmod" "amod" "appos" "aux" "case" "cc" "ccomp" "clf" "compound" "conj" "cop" "csubj" "dep" "det" "discourse" "dislocated" "expl" "fixed" "flat" "goeswith" "iobj" "list" "mark" "nmod" "nsubj" "nummod" "obj" "obl" "orphan" "parataxis" "punct" "reparandum" "root" "vocative" "xcomp")
  "List possible deprel values.")

(defvar conllu-font-lock-defaults
  `((( ,(regexp-opt conllu-upos-values 'words) . font-lock-builtin-face)
     ( ,(regexp-opt conllu-deprel-values 'words) . font-lock-constant-face)))
  "Default font locks for ‘conllu-mode’.")

;;;
;; standalone commands
(defun conllu-command (beg end command)
  "Run shell COMMAND on region delimited by BEG and END.

When run interactively, if no region is active this will use the
current sentence as standard input to the command."
  ;; this is a very thin wrapper on ‘shell-command-on-region’, in fact
  ;; it would be easy to replicate a version of this function by
  ;; calling ‘mark-paragraph’ and then ‘shell-command-on-region’
  (interactive
   (seq-let (beg end cmd-str)
       ;; cmd-str will be nil, we are just declaring it
       ;; (shell-command-on-region does it like this)
       (if (use-region-p)
	   (list (region-beginning) (region-end))
	 (conllu--sentence-points))
     (setq cmd-str (or conllu-default-command
		       (read-shell-command "Shell command to run: ")))
     (list beg end cmd-str)))
  (shell-command-on-region beg end command conllu-command-buffer))


;;;
;; derive mode
;;;###autoload
(define-derived-mode conllu-mode fundamental-mode "CoNLL-U"
  "conllu-mode is a major mode for editing CoNLL-U files."
  :syntax-table conllu-mode-syntax-table
  (setq-local font-lock-defaults conllu-font-lock-defaults)
  (setq-local indent-tabs-mode t) ;; use tabs for indentation
  (setq-local tab-width conllu-tab-width)
  (setq-local comment-start "# ")
  (setq-local comment-end "")
  ;; to be able to use M-a and M-e to jump:
  (setq-local sentence-end ".$$")
  (setq-local truncate-lines t)
  (setq-local whitespace-style '(face tabs newline newline-mark tab-mark))
  (whitespace-mode)
  (add-hook 'hack-local-variables-hook #'conllu--invoke-flycheck-if nil t))


;;;###autoload
(add-to-list 'auto-mode-alist '("\\.conllu\\'" . conllu-mode))

(provide 'conllu-mode)

;;; conllu-mode.el ends here
