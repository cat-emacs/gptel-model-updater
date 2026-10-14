;;; gptel-model-updater-tests.el --- Tests for gptel-model-updater -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Misaka

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for pure model parsing and filtering helpers.

;;; Code:

(require 'ert)
(require 'gptel-model-updater)
(require 'gptel-openai)
(require 'gptel-model-updater-transient)

(ert-deftest gptel-model-updater-parse-models-keeps-provider-order ()
  "Model parsing preserves provider order and removes duplicates."
  (let ((gptel-model-updater-sort-models nil))
    (should
     (equal (gptel-model-updater--parse-models
             '(((id . "b")) ((id . "a")) ((id . "b")))
             'openai)
            '(b a)))))

(ert-deftest gptel-model-updater-parse-models-sorts-when-enabled ()
  "Model parsing sorts alphabetically when requested."
  (let ((gptel-model-updater-sort-models t))
    (should
     (equal (gptel-model-updater--parse-models
             '(((id . "b")) ((id . "a")))
             'openai)
            '(a b)))))

(ert-deftest gptel-model-updater-prepare-models-applies-global-ingress ()
  "Global ingress filters include, exclude, prefer, and limit models."
  (let ((gptel-model-updater-include-model-regexp "openai/\\|google/")
        (gptel-model-updater-exclude-model-regexp "4o-mini")
        (gptel-model-updater-max-models 2)
        (gptel-model-updater-backend-filters nil))
    (should
     (equal (gptel-model-updater--prepare-models
             '(openai/gpt-4o anthropic/claude google/gemini openai/gpt-4o-mini)
             '("OpenRouter:google/gemini")
             "OpenRouter")
            '(google/gemini openai/gpt-4o)))))

(ert-deftest gptel-model-updater-prepare-models-applies-backend-overrides ()
  "Backend-specific filters override global ingress filters."
  (let ((gptel-model-updater-include-model-regexp "local/")
        (gptel-model-updater-exclude-model-regexp nil)
        (gptel-model-updater-max-models 1)
        (gptel-model-updater-backend-filters
         '(("Ollama" :include nil :exclude nil :max nil))))
    (should
     (equal (gptel-model-updater--prepare-models
             '(openai/gpt-4o local/llama google/gemini)
             nil
             "Ollama")
            '(openai/gpt-4o local/llama google/gemini)))))

(ert-deftest gptel-model-updater-merge-models-preserves-existing ()
  "Fetched models are appended without replacing configured models."
  (should (equal (gptel-model-updater--merge-models-preserving-existing
                  '(custom-model gpt-4o)
                  '(gpt-4o gpt-4.1))
                 '(custom-model gpt-4o gpt-4.1))))

(ert-deftest gptel-model-updater-metadata-openai-plist ()
  "models.dev metadata maps to gptel model properties."
  (let* ((backend (gptel-make-openai "metadata-openai-test"
                    :host "api.openai.com"
                    :models '()))
         (metadata
          '((openai
             (models
              (gpt-4o
               (id . "gpt-4o")
               (name . "GPT-4o")
               (attachment . t)
               (reasoning . :json-false)
               (tool_call . t)
               (structured_output . t)
               (knowledge . "2023-10")
               (modalities . ((input . ["text" "image"])
                              (output . ["text"])))
               (limit . ((context . 128000)))
               (cost . ((input . 2.5)
                        (output . 10))))))))
         (gptel-model-updater-metadata--cache metadata)
         (gptel-model-updater-metadata--cache-url gptel-model-updater-model-metadata-url))
    (gptel-model-updater-metadata-apply '(gpt-4o) backend 'openai)
    (should (equal (symbol-plist 'gpt-4o)
                   '(:description "GPT-4o"
                     :capabilities (media tool-use json url responses-api)
                     :mime-types ("image/jpeg" "image/png" "image/gif" "image/webp")
                     :context-window 128
                     :input-cost 2.5
                     :output-cost 10
                     :cutoff-date "2023-10")))))

(ert-deftest gptel-model-updater-metadata-preserves-existing-properties ()
  "models.dev metadata only fills missing gptel model properties."
  (let* ((backend (gptel-make-openai "metadata-preserve-test"
                    :host "api.openai.com"
                    :models '()))
         (metadata
          '((openai
             (models
              (gpt-4o
               (name . "GPT-4o from metadata")
               (tool_call . t)
               (modalities . ((input . ["text" "image"])
                              (output . ["text"])))
               (limit . ((context . 128000)))
               (cost . ((input . 2.5)
                        (output . 10))))))))
         (gptel-model-updater-metadata--cache metadata)
         (gptel-model-updater-metadata--cache-url gptel-model-updater-model-metadata-url))
    (unwind-protect
        (progn
          (setf (symbol-plist 'gpt-4o)
                '(:description "Existing description"
                  :context-window 32
                  :custom-property keep-me))
          (gptel-model-updater-metadata-apply '(gpt-4o) backend 'openai)
          (should (equal (get 'gpt-4o :description)
                         "Existing description"))
          (should (equal (get 'gpt-4o :context-window) 32))
          (should (equal (get 'gpt-4o :custom-property) 'keep-me))
          (should (equal (get 'gpt-4o :input-cost) 2.5))
          (should (equal (get 'gpt-4o :capabilities)
                         '(media tool-use responses-api))))
      (setf (symbol-plist 'gpt-4o) nil))))

(ert-deftest gptel-model-updater-metadata-overwrites-when-enabled ()
  "models.dev metadata can replace existing model properties on request."
  (let* ((backend (gptel-make-openai "metadata-overwrite-test"
                    :host "api.openai.com"
                    :models '()))
         (metadata
          '((openai
             (models
              (gpt-4o
               (name . "GPT-4o from metadata")
               (tool_call . t)
               (modalities . ((input . ["text" "image"])
                              (output . ["text"])))
               (limit . ((context . 128000)))
               (cost . ((input . 2.5)
                        (output . 10))))))))
         (gptel-model-updater-metadata--cache metadata)
         (gptel-model-updater-metadata--cache-url gptel-model-updater-model-metadata-url)
         (gptel-model-updater-metadata-overwrite-existing t))
    (unwind-protect
        (progn
          (setf (symbol-plist 'gpt-4o)
                '(:description "Existing description"
                  :context-window 32
                  :custom-property keep-me))
          (gptel-model-updater-metadata-apply '(gpt-4o) backend 'openai)
          (should (equal (get 'gpt-4o :description)
                         "GPT-4o from metadata"))
          (should (equal (get 'gpt-4o :context-window) 128))
          (should (equal (get 'gpt-4o :custom-property) 'keep-me))
          (should (equal (get 'gpt-4o :input-cost) 2.5))
          (should (equal (get 'gpt-4o :capabilities)
                         '(media tool-use responses-api))))
      (setf (symbol-plist 'gpt-4o) nil))))

(ert-deftest gptel-model-updater-metadata-fetch-respects-curl-setting ()
  "Metadata fetching follows `gptel-use-curl'."
  (cl-letf (((symbol-function 'gptel-model-updater-metadata--fetch-with-curl)
             (lambda (_url) 'curl))
            ((symbol-function 'gptel-model-updater-metadata--fetch-with-url)
             (lambda (_url) 'url)))
    (let ((gptel-use-curl t))
      (should (eq (gptel-model-updater-metadata--fetch "https://example.com")
                  'curl)))
    (let ((gptel-use-curl nil))
      (should (eq (gptel-model-updater-metadata--fetch "https://example.com")
                  'url)))))

(ert-deftest gptel-model-updater-metadata-backend-spec-providers-win ()
  "Backend spec providers override automatic matching and support many providers."
  (let* ((backend (gptel-make-openai "metadata-backend-test"
                    :host "api.openai.com"
                    :models '()))
         (gptel-model-updater-backends
          '((gptel-model-updater--test-backend
             :providers (openrouter anthropic)))))
    (unwind-protect
        (progn
          (set 'gptel-model-updater--test-backend backend)
          (should (equal (gptel-model-updater-metadata--provider-keys
                          backend 'openai '((openai) (openrouter) (anthropic)))
                         '(openrouter anthropic openai))))
      (makunbound 'gptel-model-updater--test-backend))))

(ert-deftest gptel-model-updater-metadata-apply-tries-multiple-providers ()
  "Metadata application tries provider candidates in order per model."
  (let* ((backend (gptel-make-openai "metadata-multi-provider-test"
                    :host "api.openai.com"
                    :models '()))
         (gptel-model-updater-backends
          '((gptel-model-updater--multi-provider-test-backend
             :providers (openrouter openai))))
         (metadata
          '((openrouter
             (models
              (openai/gpt-4o
               (name . "OpenRouter GPT-4o")
               (tool_call . t)
               (modalities . ((input . ["text"])
                              (output . ["text"])))
               (limit . ((context . 128000)))
               (cost . ((input . 2.5)
                        (output . 10))))))
            (openai
             (models
              (gpt-4o
               (name . "OpenAI GPT-4o")
               (tool_call . t)
               (modalities . ((input . ["text"])
                              (output . ["text"])))
               (limit . ((context . 128000)))
               (cost . ((input . 2.5)
                        (output . 10))))))))
         (gptel-model-updater-metadata--cache metadata)
         (gptel-model-updater-metadata--cache-url gptel-model-updater-model-metadata-url))
    (unwind-protect
        (progn
          (set 'gptel-model-updater--multi-provider-test-backend backend)
          (gptel-model-updater-metadata-apply '(gpt-4o openai/gpt-4o)
                                              backend 'openai)
          (should (equal (get 'gpt-4o :description) "OpenAI GPT-4o"))
          (should (equal (get 'openai/gpt-4o :description)
                         "OpenRouter GPT-4o")))
      (makunbound 'gptel-model-updater--multi-provider-test-backend)
      (setf (symbol-plist 'gpt-4o) nil
            (symbol-plist 'openai/gpt-4o) nil))))

(ert-deftest gptel-model-updater-metadata-all-provider-searches-everywhere ()
  "The special provider `all' searches every models.dev provider."
  (let* ((backend (gptel-make-openai "metadata-all-provider-test"
                    :host "example.invalid"
                    :models '()))
         (gptel-model-updater-backends
          '((gptel-model-updater--all-provider-test-backend :providers (all))))
         (metadata
          '((openrouter
             (models
              (gpt-4o
               (name . "First GPT-4o")
               (modalities . ((input . ["text"])
                              (output . ["text"])))
               (limit . ((context . 64000))))))
            (openai
             (models
              (gpt-4o
               (name . "OpenAI GPT-4o")
               (modalities . ((input . ["text"])
                              (output . ["text"])))
               (limit . ((context . 128000))))))))
         (gptel-model-updater-metadata--cache metadata)
         (gptel-model-updater-metadata--cache-url gptel-model-updater-model-metadata-url))
    (unwind-protect
        (progn
          (set 'gptel-model-updater--all-provider-test-backend backend)
          (setf (symbol-plist 'gpt-4o) nil)
          (gptel-model-updater-metadata-apply '(gpt-4o) backend 'openai)
          (should (equal (get 'gpt-4o :description) "First GPT-4o")))
      (makunbound 'gptel-model-updater--all-provider-test-backend)
      (setf (symbol-plist 'gpt-4o) nil))))

(ert-deftest gptel-model-updater-format-model-annotation-uses-plist ()
  "Interactive model annotations display gptel model properties."
  (let ((model 'gptel-model-updater-test-model))
    (unwind-protect
        (progn
          (setf (symbol-plist model)
                '(:description "Test Model"
                  :capabilities (media tool-use json)
                  :context-window 128
                  :input-cost 2.5
                  :output-cost 10
                  :cutoff-date "2024-01"))
          (let ((annotation (substring-no-properties
                             (gptel-model-updater-ui--format-model-annotation model))))
            (should (string-match-p "Test Model" annotation))
            (should (string-match-p "media" annotation))
            (should (string-match-p "128k" annotation))
            (should (string-match-p "\\$ 2\\.50 in" annotation))
            (should (string-match-p "\\$ 10\\.00 out" annotation))
            (should (string-match-p "2024-01" annotation))))
      (setf (symbol-plist model) nil))))

(ert-deftest gptel-model-updater-format-model-annotation-uses-column-widths ()
  "Interactive model annotations honor configured column widths."
  (let ((model 'gptel-model-updater-test-model)
        (old-widths gptel-model-updater-ui-annotation-column-widths))
    (unwind-protect
        (progn
          (setq gptel-model-updater-ui-annotation-column-widths
                '((model . 20)
                  (description . 10)
                  (capabilities . 12)
                  (context-window . 6)
                  (input-cost . 9)
                  (output-cost . 11)
                  (cutoff-date . nil)))
          (setf (symbol-plist model)
                '(:description "Long Test Model Description"
                  :capabilities (media tool-use json)
                  :context-window 128
                  :input-cost 2.5
                  :output-cost 10
                  :cutoff-date "2024-01"))
          (let* ((annotation (gptel-model-updater-ui--format-model-annotation model))
                 (plain (substring-no-properties annotation)))
            (should (equal (get-text-property 0 'display annotation)
                           '(space :align-to 20)))
            (should (string-match-p "Long Te" plain))
            (should-not (string-match-p "Long Test Model Description" plain))))
      (setq gptel-model-updater-ui-annotation-column-widths old-widths)
      (setf (symbol-plist model) nil))))

(ert-deftest gptel-model-updater-select-all-targets-interactive-selects-one-target ()
  "Interactive selection updates only the chosen external target."
  (let* ((target-a '(test-backend-a test-model-a "Target A"))
         (target-b '(test-backend-b test-model-b "Target B"))
         (gptel-model-updater-external-targets (list target-a target-b))
         (selected nil))
    (cl-letf (((symbol-function 'gptel-model-updater--read-target)
               (lambda () target-b))
              ((symbol-function 'gptel-model-updater-select-default-target)
               (lambda (&rest _args) (push 'gptel selected)))
              ((symbol-function 'gptel-model-updater--select-external-target)
               (lambda (target &rest _args) (push target selected))))
      (gptel-model-updater-select-all-targets t t)
      (should (equal selected (list target-b))))))

(ert-deftest gptel-model-updater-read-target-lists-default-and-external-targets ()
  "Target completion includes GPTel and every configured external target."
  (let* ((target-a '(test-backend-a test-model-a "Target A"))
         (target-b '(test-backend-b test-model-b "Target B"))
         (gptel-model-updater-external-targets (list target-a target-b))
         (candidates nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _args)
                 (setq candidates collection)
                 "Target B")))
      (should (equal (gptel-model-updater--read-target) target-b))
      (should (equal (mapcar #'car candidates)
                     '("GPTel" "Target A" "Target B"))))))

(ert-deftest gptel-model-updater-select-all-targets-noninteractive-selects-all ()
  "Non-interactive selection continues to update every target."
  (let ((gptel-model-updater-external-targets
         '((test-backend-a test-model-a "Target A")))
        (selected nil))
    (cl-letf (((symbol-function 'gptel-model-updater-select-default-target)
               (lambda (&rest _args) (push 'gptel selected)))
              ((symbol-function 'gptel-model-updater-select-external-targets)
               (lambda (&rest _args) (push 'external selected))))
      (gptel-model-updater-select-all-targets t nil)
      (should (equal selected '(external gptel))))))

(ert-deftest gptel-model-updater-update-all-runs-after-hook ()
  "Update-all hook runs once after backend updates are scheduled."
  (let ((gptel-model-updater--test-hook-calls 0)
        (gptel-model-updater-backends '(gptel-model-updater--test-backend))
        (gptel-model-updater-after-update-all-hook
         '(gptel-model-updater--test-after-update-all)))
    (cl-letf (((symbol-function 'gptel-model-updater-update-backend)
               (lambda (&rest args)
                 (funcall (car (last args)))))
              ((symbol-function 'gptel-model-updater--test-after-update-all)
               (lambda (&rest _args) nil)))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'gptel-model-updater--test-after-update-all)
                       (lambda ()
                         (cl-incf gptel-model-updater--test-hook-calls))))
              (set 'gptel-model-updater--test-backend
                   (gptel-make-openai "update-all-hook-test" :models '()))
              (gptel-model-updater-update-all))
            (should (= gptel-model-updater--test-hook-calls 1)))
        (makunbound 'gptel-model-updater--test-backend)))))

(ert-deftest gptel-model-updater-update-all-waits-for-callbacks ()
  "Update-all hook waits until every backend callback finishes."
  (let ((callbacks nil)
        (events nil)
        (gptel-model-updater--test-hook-calls 0)
        (gptel-model-updater-backends '(gptel-model-updater--test-backend-a
                                        gptel-model-updater--test-backend-b))
        (gptel-model-updater-after-update-all-hook
         '(gptel-model-updater--test-after-update-all)))
    (cl-letf (((symbol-function 'gptel-model-updater-update-backend)
               (lambda (name &rest args)
                 (push name events)
                 (push (car (last args)) callbacks)))
              ((symbol-function 'gptel-model-updater--test-after-update-all)
               (lambda ()
                 (cl-incf gptel-model-updater--test-hook-calls)
                 (push 'all-hook events))))
      (unwind-protect
          (progn
            (set 'gptel-model-updater--test-backend-a
                 (gptel-make-openai "update-all-callback-test-a" :models '()))
            (set 'gptel-model-updater--test-backend-b
                 (gptel-make-openai "update-all-callback-test-b" :models '()))
            (gptel-model-updater-update-all)
            (should (= gptel-model-updater--test-hook-calls 0))
            (funcall (pop callbacks))
            (should (= gptel-model-updater--test-hook-calls 0))
            (funcall (pop callbacks))
            (should (= gptel-model-updater--test-hook-calls 1))
            (should (eq (car events) 'all-hook)))
        (makunbound 'gptel-model-updater--test-backend-a)
        (makunbound 'gptel-model-updater--test-backend-b)))))

;;; Transient dispatcher

(ert-deftest gptel-model-updater-transient-prefix-defined ()
  "The transient prefix command and its alias are defined."
  (should (commandp 'gptel-model-updater-transient))
  (should (commandp 'gptel-model-updater-menu)))

(ert-deftest gptel-model-updater-set-backend-filter-adds-entry ()
  "Setting a filter creates a backend entry when none exists."
  (let ((gptel-model-updater-backend-filters nil))
    (gptel-model-updater--set-backend-filter "Ollama" :include "local/")
    (should (equal gptel-model-updater-backend-filters
                   '(("Ollama" :include "local/"))))))

(ert-deftest gptel-model-updater-set-backend-filter-updates-key ()
  "Setting an existing key replaces its value, keeping other keys."
  (let ((gptel-model-updater-backend-filters
         '(("Ollama" :include "local/" :max 5))))
    (gptel-model-updater--set-backend-filter "Ollama" :max 10)
    (should (equal (cdr (assoc "Ollama" gptel-model-updater-backend-filters))
                   '(:include "local/" :max 10)))))

(ert-deftest gptel-model-updater-set-backend-filter-removes-key-on-nil ()
  "Setting a key to nil removes only that key."
  (let ((gptel-model-updater-backend-filters
         '(("Ollama" :include "local/" :max 5))))
    (gptel-model-updater--set-backend-filter "Ollama" :include nil)
    (should (equal (cdr (assoc "Ollama" gptel-model-updater-backend-filters))
                   '(:max 5)))))

(ert-deftest gptel-model-updater-set-backend-filter-removes-empty-entry ()
  "Clearing the last key removes the whole backend entry."
  (let ((gptel-model-updater-backend-filters
         '(("Ollama" :include "local/")
           ("OpenAI" :max 3))))
    (gptel-model-updater--set-backend-filter "Ollama" :include nil)
    (should (equal gptel-model-updater-backend-filters
                   '(("OpenAI" :max 3))))))

(ert-deftest gptel-model-updater-transient-toggle-flips-value ()
  "Toggling a boolean variable returns and stores the negated value."
  (let ((gptel-model-updater-sort-models nil))
    (should (eq (gptel-model-updater--transient-toggle
                 'gptel-model-updater-sort-models)
                t))
    (should (eq gptel-model-updater-sort-models t))
    (should (eq (gptel-model-updater--transient-toggle
                 'gptel-model-updater-sort-models)
                nil))
    (should (eq gptel-model-updater-sort-models nil))))

(ert-deftest gptel-model-updater-transient-read-regexp-blank-is-nil ()
  "An empty regexp input clears the value to nil."
  (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "  ")))
    (should (null (gptel-model-updater--transient-read-regexp "P: " "old"))))
  (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "openai/")))
    (should (equal (gptel-model-updater--transient-read-regexp "P: " nil)
                   "openai/"))))

(ert-deftest gptel-model-updater-transient-read-max-parses-integer ()
  "Reading the max count parses positive integers and clears otherwise."
  (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "50")))
    (should (equal (gptel-model-updater--transient-read-max "P: " nil) 50)))
  (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "")))
    (should (null (gptel-model-updater--transient-read-max "P: " 10))))
  (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "0")))
    (should (null (gptel-model-updater--transient-read-max "P: " nil)))))

(ert-deftest gptel-model-updater-transient-targets-lists-default-and-external ()
  "Target rows include the default target and each external target."
  (let ((gptel-model-updater-external-targets
         '((backend-var model-var "Fast")
           (backend-var2 model-var2 "Vision"))))
    (let ((rows (gptel-model-updater--transient-targets)))
      (should (equal (car (nth 0 rows)) "g"))
      (should (eq (cdr (nth 0 rows)) 'gptel))
      (should (equal (car (nth 1 rows)) "1"))
      (should (equal (gptel-model-updater--target-label (cdr (nth 1 rows)))
                     "Fast"))
      (should (equal (car (nth 2 rows)) "2")))))

(ert-deftest gptel-model-updater-transient-target-description-reflects-state ()
  "Target descriptions reflect state without field prefixes."
  (defvar gptel-model-updater--test-tr-backend nil)
  (defvar gptel-model-updater--test-tr-model nil)
  (let* ((gptel-backend (gptel-make-openai "IV" :models '(gpt-5.4)))
         (gptel-model 'gpt-5.4)
         (backend (gptel-make-openai "transient-desc-test" :models '(gpt-4o)))
         (gptel-model-updater--test-tr-backend backend)
         (gptel-model-updater--test-tr-model 'gpt-4o)
         (target '(gptel-model-updater--test-tr-backend
                   gptel-model-updater--test-tr-model "Fast"))
         (gptel-model-updater-external-targets (list target)))
    (should (equal (gptel-model-updater--transient-target-description target)
                   "Fast   transient-desc-test  gpt-4o"))))

(ert-deftest gptel-model-updater-transient-target-descriptions-align-columns ()
  "All transient target descriptions share backend and model columns."
  (defvar gptel-model-updater--test-tr-magit-backend nil)
  (defvar gptel-model-updater--test-tr-magit-model nil)
  (defvar gptel-model-updater--test-tr-forge-backend nil)
  (defvar gptel-model-updater--test-tr-forge-model nil)
  (let* ((gptel-backend (gptel-make-openai "IV" :models '(gpt-5.4)))
         (gptel-model 'gpt-5.4)
         (gptel-model-updater--test-tr-magit-backend gptel-backend)
         (gptel-model-updater--test-tr-magit-model 'deepseek-v4-flash)
         (gptel-model-updater--test-tr-forge-backend gptel-backend)
         (gptel-model-updater--test-tr-forge-model 'deepseek-v4-flash)
         (gptel-model-updater-external-targets
          '((gptel-model-updater--test-tr-magit-backend
             gptel-model-updater--test-tr-magit-model "GPTel-Magit")
            (gptel-model-updater--test-tr-forge-backend
             gptel-model-updater--test-tr-forge-model "GPTel-Forge-Prs")))
         (descriptions
          (mapcar #'cdr (gptel-model-updater--transient-target-descriptions))))
    (should-not (string-match-p "backend=\|model=\|\t"
                                (string-join descriptions "\n")))
    (should (equal (cl-mapcar #'string-match '("IV" "IV" "IV") descriptions)
                   '(17 17 17)))
    (should (equal (cl-mapcar #'string-match
                              '("gpt-5.4" "deepseek-v4-flash"
                                "deepseek-v4-flash")
                              descriptions)
                   '(21 21 21)))))

(ert-deftest gptel-model-updater-format-all-targets-aligns-with-spaces ()
  "Target output aligns backend and model fields using spaces."
  (defvar gptel-model-updater--test-magit-backend nil)
  (defvar gptel-model-updater--test-magit-model nil)
  (defvar gptel-model-updater--test-forge-backend nil)
  (defvar gptel-model-updater--test-forge-model nil)
  (let* ((gptel-backend
          (gptel-make-openai "Gemini" :models '(gemini-pro)))
         (gptel-model 'gemini-pro)
         (gptel-model-updater--test-magit-backend
          (gptel-make-openai "OpenRouter" :models '(openai/gpt)))
         (gptel-model-updater--test-magit-model 'openai/gpt)
         (gptel-model-updater--test-forge-backend
          (gptel-make-openai "MLX" :models '(mlx/model)))
         (gptel-model-updater--test-forge-model 'mlx/model)
         (gptel-model-updater-external-targets
          '((gptel-model-updater--test-magit-backend
             gptel-model-updater--test-magit-model "GPTel-Magit")
            (gptel-model-updater--test-forge-backend
             gptel-model-updater--test-forge-model "GPTel-Forge-Prs"))))
    (let* ((output (gptel-model-updater--format-all-targets))
           (lines (string-split output "\n")))
      (should-not (string-match-p "\t" output))
      (should (equal (cl-mapcar #'string-match
                                '("Backend" "Gemini" "OpenRouter" "MLX")
                                lines)
                     '(17 17 17 17)))
      (should (equal (cl-mapcar #'string-match
                                '("Model" "gemini-pro"
                                  "openai/gpt" "mlx/model")
                                lines)
                     '(29 29 29 29))))))

(ert-deftest gptel-model-updater-format-target-table-aligns-raw-text ()
  "Target table columns align without relying on tab rendering."
  (let* ((output
          (gptel-model-updater--format-target-fields
           '(("GPTel" "IV" "gpt-5.4")
             ("GPTel-Magit" "IV" "deepseek-v4-flash")
             ("GPTel-Forge-Prs" "IV" "deepseek-v4-flash"))
           t))
         (lines (string-split output "\n")))
    (should-not (string-match-p "\t" output))
    (should (equal (cl-mapcar #'string-match
                              '("Backend" "IV" "IV" "IV") lines)
                   '(17 17 17 17)))
    (should (equal (cl-mapcar #'string-match
                              '("Model" "gpt-5.4"
                                "deepseek-v4-flash" "deepseek-v4-flash")
                              lines)
                   '(26 26 26 26)))))

(ert-deftest gptel-model-updater-transient-backend-row-description ()
  "Per-backend rows show effective include/exclude/max with global fallback."
  (let ((gptel-model-updater-include-model-regexp "global/")
        (gptel-model-updater-exclude-model-regexp nil)
        (gptel-model-updater-max-models 200)
        (gptel-model-updater-backend-filters
         '(("Ollama" :include "local/" :max 5))))
    ;; Ollama overrides include and max; exclude falls back to global (nil).
    (should (equal (gptel-model-updater--transient-backend-row-description
                    "Ollama")
                   "Ollama  include=local/ exclude=- max=5"))
    ;; OpenAI has no override, so include and max fall back to global values.
    (should (equal (gptel-model-updater--transient-backend-row-description
                    "OpenAI")
                   "OpenAI  include=global/ exclude=- max=200"))))

(ert-deftest gptel-model-updater-transient-set-current-filter ()
  "Setting the current per-backend filter writes through to the alist."
  (let ((gptel-model-updater-backend-filters nil)
        (gptel-model-updater--transient-backend "Ollama"))
    (gptel-model-updater--transient-set-current-filter :max 7)
    (should (equal (gptel-model-updater--backend-filter-value "Ollama" :max)
                   7)))
  (let ((gptel-model-updater-backend-filters '(("Ollama" :max 7)))
        (gptel-model-updater--transient-backend nil))
    (gptel-model-updater--transient-set-current-filter :max 9)
    (should (equal gptel-model-updater-backend-filters '(("Ollama" :max 7))))))

(ert-deftest gptel-model-updater-backend-filter-value-reads-effective ()
  "Reading a backend filter value returns the stored plist value."
  (let ((gptel-model-updater-backend-filters
         '(("Ollama" :include "local/" :max 5))))
    (should (equal (gptel-model-updater--backend-filter-value "Ollama" :include)
                   "local/"))
    (should (equal (gptel-model-updater--backend-filter-value "Ollama" :max)
                   5))
    (should (null (gptel-model-updater--backend-filter-value "Ollama" :exclude)))
    (should (null (gptel-model-updater--backend-filter-value "Missing" :max)))))

(provide 'gptel-model-updater-tests)
;;; gptel-model-updater-tests.el ends here
