;;; gptel-model-updater-transient.el --- Transient UI for gptel-model-updater -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Misaka

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A transient dispatcher for `gptel-model-updater'.  It provides a
;; Magit-style popup for selecting the backend/model of each configured
;; target, running updates, toggling metadata overwrite, and editing the
;; global and per-backend model filters.
;;
;; This file is additive: the existing interactive `completing-read'
;; commands remain available and are reused here.

;;; Code:

(require 'transient)
(require 'gptel-model-updater)

;;;; Backend filter helpers

(defun gptel-model-updater--backend-filter-value (backend-name key)
  "Return the stored KEY value for BACKEND-NAME in the filter alist.
Returns nil when the backend or KEY is not configured."
  (plist-get (cdr (assoc backend-name gptel-model-updater-backend-filters))
             key))

(defun gptel-model-updater--set-backend-filter (backend-name key value)
  "Set KEY to VALUE for BACKEND-NAME in `gptel-model-updater-backend-filters'.
When VALUE is nil, remove KEY.  When a backend entry has no keys left,
remove the entry.  Creates the entry when needed."
  (let* ((filters (copy-sequence gptel-model-updater-backend-filters))
         (entry (assoc backend-name filters))
         (plist (copy-sequence (cdr entry))))
    (if value
        (setq plist (plist-put plist key value))
      (setq plist (gptel-model-updater--plist-remove plist key)))
    (cond
     ((and entry plist)
      (setcdr entry plist))
     (entry
      (setq filters (delq entry filters)))
     (plist
      (setq filters (append filters (list (cons backend-name plist))))))
    (setq gptel-model-updater-backend-filters filters)))

(defun gptel-model-updater--plist-remove (plist key)
  "Return a copy of PLIST with KEY and its value removed."
  (let (result)
    (while plist
      (unless (eq (car plist) key)
        (setq result (append result (list (car plist) (cadr plist)))))
      (setq plist (cddr plist)))
    result))

;;;; Option readers

(defun gptel-model-updater--transient-toggle (variable)
  "Set VARIABLE to the negation of its value and return the new value."
  (set variable (not (symbol-value variable))))

(defun gptel-model-updater--transient-read-regexp (prompt current)
  "Read a regexp with PROMPT showing CURRENT.
Return the trimmed input, or nil when the input is empty."
  (let ((input (read-string prompt (and current (format "%s" current)))))
    (if (string-empty-p (string-trim input)) nil input)))

(defun gptel-model-updater--transient-read-max (prompt current)
  "Read a maximum model count with PROMPT showing CURRENT.
Return an integer, or nil when the input is empty or non-positive."
  (let ((input (read-string prompt (and current (number-to-string current)))))
    (if (string-empty-p (string-trim input))
        nil
      (let ((value (string-to-number input)))
        (if (> value 0) value nil)))))

;;;; Targets

(defun gptel-model-updater--transient-targets ()
  "Return rows of (KEY . TARGET) for the default and external targets.
TARGET is the symbol `gptel' for the default target or an external target
spec from `gptel-model-updater-external-targets'."
  (let ((rows (list (cons "g" 'gptel)))
        (index 0))
    (dolist (target gptel-model-updater-external-targets)
      (setq index (1+ index))
      (push (cons (number-to-string index) target) rows))
    (nreverse rows)))

(defun gptel-model-updater--transient-target-description (target)
  "Return a display string for TARGET row."
  (cdr (assoc target (gptel-model-updater--transient-target-descriptions))))

(defun gptel-model-updater--transient-target-fields (target)
  "Return display fields for transient TARGET."
  (if (eq target 'gptel)
      (gptel-model-updater--default-target-fields)
    (gptel-model-updater--external-target-fields target)))

(defun gptel-model-updater--transient-target-descriptions ()
  "Return aligned (TARGET . DESCRIPTION) entries for the transient."
  (let* ((targets (mapcar #'cdr (gptel-model-updater--transient-targets)))
         (descriptions
          (string-split
           (gptel-model-updater--format-target-fields
            (mapcar #'gptel-model-updater--transient-target-fields targets)
            'plain)
           "\n")))
    (cl-mapcar #'cons targets descriptions)))

(defun gptel-model-updater--transient-select-target (target)
  "Interactively select the backend and model for TARGET."
  (if (eq target 'gptel)
      (gptel-model-updater-select-default-target t t)
    (gptel-model-updater--select-external-target target t)))

(defun gptel-model-updater--transient-setup-targets (_children)
  "Return parsed target suffixes for the Targets group."
  (transient-parse-suffixes
   'gptel-model-updater-transient
   (mapcar
    (pcase-lambda (`(,key . ,target))
      (list key
            (lambda ()
              (interactive)
              (gptel-model-updater--transient-select-target target))
            :description
            (lambda () (gptel-model-updater--transient-target-description target))
            :transient t))
    (gptel-model-updater--transient-targets))))

;;;; Options infixes

(transient-define-infix gptel-model-updater-transient--overwrite ()
  "Toggle whether models.dev metadata overwrites existing properties."
  :class 'transient-lisp-variable
  :variable 'gptel-model-updater-metadata-overwrite-existing
  :description "Overwrite metadata"
  :reader (lambda (&rest _)
            (gptel-model-updater--transient-toggle
             'gptel-model-updater-metadata-overwrite-existing)))

;;;; Filter infixes

(transient-define-infix gptel-model-updater-transient--sort ()
  "Toggle alphabetical sorting of fetched models."
  :class 'transient-lisp-variable
  :variable 'gptel-model-updater-sort-models
  :description "Sort models"
  :reader (lambda (&rest _)
            (gptel-model-updater--transient-toggle
             'gptel-model-updater-sort-models)))

(transient-define-infix gptel-model-updater-transient--include ()
  "Set the global include-model regexp."
  :class 'transient-lisp-variable
  :variable 'gptel-model-updater-include-model-regexp
  :description "Include regexp"
  :reader (lambda (&rest _)
            (gptel-model-updater--transient-read-regexp
             "Include regexp: " gptel-model-updater-include-model-regexp)))

(transient-define-infix gptel-model-updater-transient--exclude ()
  "Set the global exclude-model regexp."
  :class 'transient-lisp-variable
  :variable 'gptel-model-updater-exclude-model-regexp
  :description "Exclude regexp"
  :reader (lambda (&rest _)
            (gptel-model-updater--transient-read-regexp
             "Exclude regexp: " gptel-model-updater-exclude-model-regexp)))

(transient-define-infix gptel-model-updater-transient--max ()
  "Set the global maximum number of models."
  :class 'transient-lisp-variable
  :variable 'gptel-model-updater-max-models
  :description "Max models"
  :reader (lambda (&rest _)
            (gptel-model-updater--transient-read-max
             "Max models (empty for no limit): "
             gptel-model-updater-max-models)))

;;;; Per-backend filters

(defvar gptel-model-updater--transient-backend nil
  "Backend name targeted by the per-backend filter sub-transient.")

(defun gptel-model-updater--transient-backend-names ()
  "Return the names of backends managed by `gptel-model-updater'."
  (cl-loop for symbol in (gptel-model-updater--backends)
           when (and (symbolp symbol) (boundp symbol))
           collect (gptel-backend-name (symbol-value symbol))))

(defun gptel-model-updater--transient-backend-row-description (name)
  "Return a display string for the per-backend filter row NAME.
Values are the effective include/exclude/max, resolving global fallbacks."
  (format "%s  include=%s exclude=%s max=%s"
          name
          (or (gptel-model-updater--include-regexp name) "-")
          (or (gptel-model-updater--exclude-regexp name) "-")
          (or (gptel-model-updater--max-models name) "-")))

(defun gptel-model-updater--transient-edit-backend (name)
  "Set the current per-backend filter target to NAME and open its menu."
  (setq gptel-model-updater--transient-backend name)
  (gptel-model-updater-transient-backend-filter))

(defun gptel-model-updater--transient-setup-backends (_children)
  "Return parsed per-backend filter suffixes for the Filters group."
  (let ((index 0))
    (transient-parse-suffixes
     'gptel-model-updater-transient-filters
     (mapcar
      (lambda (name)
        (setq index (1+ index))
        (list (number-to-string index)
              (lambda ()
                (interactive)
                (gptel-model-updater--transient-edit-backend name))
              :description
              (lambda ()
                (gptel-model-updater--transient-backend-row-description name))))
      (gptel-model-updater--transient-backend-names)))))

(defun gptel-model-updater--transient-set-current-filter (key value)
  "Set KEY to VALUE for the current per-backend filter target."
  (when gptel-model-updater--transient-backend
    (gptel-model-updater--set-backend-filter
     gptel-model-updater--transient-backend key value)))

(transient-define-infix gptel-model-updater-transient--backend-include ()
  "Set the current backend's include regexp."
  :class 'transient-lisp-variable
  :variable 'gptel-model-updater--transient-backend
  :description "Include regexp"
  :format "%k %d"
  :reader (lambda (&rest _)
            (gptel-model-updater--transient-set-current-filter
             :include
             (gptel-model-updater--transient-read-regexp
              "Include regexp: "
              (gptel-model-updater--backend-filter-value
               gptel-model-updater--transient-backend :include)))
            gptel-model-updater--transient-backend))

(transient-define-infix gptel-model-updater-transient--backend-exclude ()
  "Set the current backend's exclude regexp."
  :class 'transient-lisp-variable
  :variable 'gptel-model-updater--transient-backend
  :description "Exclude regexp"
  :format "%k %d"
  :reader (lambda (&rest _)
            (gptel-model-updater--transient-set-current-filter
             :exclude
             (gptel-model-updater--transient-read-regexp
              "Exclude regexp: "
              (gptel-model-updater--backend-filter-value
               gptel-model-updater--transient-backend :exclude)))
            gptel-model-updater--transient-backend))

(transient-define-infix gptel-model-updater-transient--backend-max ()
  "Set the current backend's maximum model count."
  :class 'transient-lisp-variable
  :variable 'gptel-model-updater--transient-backend
  :description "Max models"
  :format "%k %d"
  :reader (lambda (&rest _)
            (gptel-model-updater--transient-set-current-filter
             :max
             (gptel-model-updater--transient-read-max
              "Max models (empty for no limit): "
              (gptel-model-updater--backend-filter-value
               gptel-model-updater--transient-backend :max)))
            gptel-model-updater--transient-backend))

;;;; Prefixes

(transient-define-prefix gptel-model-updater-transient-backend-filter ()
  "Edit include/exclude/max filters for a single backend."
  [:description
   (lambda ()
     (format "Backend filter: %s" gptel-model-updater--transient-backend))
   ["Rules"
    ("-i" gptel-model-updater-transient--backend-include)
    ("-x" gptel-model-updater-transient--backend-exclude)
    ("-m" gptel-model-updater-transient--backend-max)]
   [("q" "Back" transient-quit-one)]])

(transient-define-prefix gptel-model-updater-transient-filters ()
  "Configure global and per-backend model filters."
  [["Global"
    ("-s" gptel-model-updater-transient--sort)
    ("-i" gptel-model-updater-transient--include)
    ("-x" gptel-model-updater-transient--exclude)
    ("-m" gptel-model-updater-transient--max)]
   ["Per-backend"
    :class transient-column
    :setup-children gptel-model-updater--transient-setup-backends]]
  [("q" "Back" transient-quit-one)])

;;;###autoload (autoload 'gptel-model-updater-transient "gptel-model-updater-transient" nil t)
(transient-define-prefix gptel-model-updater-transient ()
  "Dispatch backend/model selection, updates, and filters."
  [:description "GPTel Model Updater"
   ["Targets"
    :class transient-column
    :setup-children gptel-model-updater--transient-setup-targets]
   ["Update"
    ("u" "Update all" gptel-model-updater-update-all)
    ("b" "Update backend" gptel-model-updater-update-backend)
    ("a" "Select all targets" gptel-model-updater-select-all-targets)]
   ["Options"
    ("-o" gptel-model-updater-transient--overwrite)
    ("f" "Filters..." gptel-model-updater-transient-filters)]]
  [("q" "Quit" transient-quit-one)])

;;;###autoload
(defalias 'gptel-model-updater-menu #'gptel-model-updater-transient)

(provide 'gptel-model-updater-transient)
;;; gptel-model-updater-transient.el ends here
