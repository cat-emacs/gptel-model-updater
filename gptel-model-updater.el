;;; gptel-model-updater.el --- Fetch and update models for GPTel backends -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Misaka

;; Author: pfcdx <github@pfcdx>
;; Maintainer: Misaka <chuxubank@qq.com>
;; Assisted-by: opencode:deepseek-v4-flash-free
;; Version: 0.3.3
;; Package-Requires: ((emacs "29.1") (gptel "0.8"))
;; Keywords: comm, tools, processes
;; URL: https://github.com/cat-emacs/gptel-model-updater

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

;; A package to fetch and update models for GPTel backends from various providers.
;; Supports OpenAI-compatible APIs, Ollama, and Gemini.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'gptel)

(defgroup gptel-model-updater nil
  "GPTel model updater settings."
  :group 'gptel)

(require 'gptel-model-updater-metadata)
(require 'gptel-model-updater-ui)

(defcustom gptel-model-updater-timeout 30
  "Timeout for API requests in seconds."
  :type 'number
  :group 'gptel-model-updater)

(defcustom gptel-model-updater-sort-models nil
  "Whether to sort fetched model lists alphabetically.
When nil, keep the provider's response order, with
`gptel-model-updater-models' entries moved to the front when configured."
  :type 'boolean
  :group 'gptel-model-updater)

(defcustom gptel-model-updater-include-model-regexp nil
  "Regexp matching model names allowed into refreshed backend model lists.
When nil, do not filter models by inclusion regexp."
  :type '(choice (const :tag "Allow all" nil)
                 regexp)
  :group 'gptel-model-updater)

(defcustom gptel-model-updater-exclude-model-regexp nil
  "Regexp matching model names excluded from refreshed backend model lists.
When nil, do not filter models by exclusion regexp."
  :type '(choice (const :tag "Exclude none" nil)
                 regexp)
  :group 'gptel-model-updater)

(defcustom gptel-model-updater-max-models nil
  "Maximum number of models to write to a refreshed backend.
When nil, keep every model that passes the regexp filters."
  :type '(choice (const :tag "No limit" nil)
                 (integer :tag "Maximum models"))
  :group 'gptel-model-updater)

(defcustom gptel-model-updater-backend-filters nil
  "Per-backend ingress filters.
Each entry is (BACKEND-NAME :include INCLUDE :exclude EXCLUDE :max MAX).
BACKEND-NAME is compared with `gptel-backend-name'.  INCLUDE and EXCLUDE
are regexps matched against model names.  MAX is the maximum number of
models to keep after filtering and preferred-model ordering.

Omitted keys fall back to the corresponding global settings:
`gptel-model-updater-include-model-regexp',
`gptel-model-updater-exclude-model-regexp', and
`gptel-model-updater-max-models'."
  :type '(repeat sexp)
  :group 'gptel-model-updater)

(defcustom gptel-model-updater-after-update-hook nil
  "Hook run after a backend's models are updated successfully.
Each function is called with BACKEND-NAME, BACKEND, and MODELS."
  :type 'hook
  :group 'gptel-model-updater)

(defcustom gptel-model-updater-after-update-all-hook #'gptel-model-updater-select-all-targets
  "Hook run after `gptel-model-updater-update-all' finishes all backends."
  :type 'hook
  :group 'gptel-model-updater)

(defcustom gptel-model-updater-backends nil
  "GPTel backends managed by `gptel-model-updater'.
Each entry may be a backend variable symbol, or (BACKEND :providers PROVIDERS).
BACKEND is a backend variable symbol.  PROVIDERS is a models.dev provider key
symbol or a list of provider key symbols tried in order for metadata.  The
special provider key `all' searches all models.dev providers."
  :type '(repeat (choice symbol sexp))
  :group 'gptel-model-updater)

(defcustom gptel-model-updater-models nil
  "Preferred models selected by `gptel-model-updater'.
When non-nil, entries are tried in order.  Each entry must be BACKEND:MODEL.
The first available backend/model pair is selected.  Entries may be symbols
or strings."
  :type '(repeat (choice symbol string))
  :group 'gptel-model-updater)

(defcustom gptel-model-updater-external-targets nil
  "External backend/model variable pairs set by `gptel-model-updater'.
Each item is (BACKEND-VARIABLE MODEL-VARIABLE DISPLAY-NAME MODEL-LIST).
MODEL-LIST is optional and overrides `gptel-model-updater-models' for that
target.  These targets are selected and set when
`gptel-model-updater-select-external-targets' is called, or via
`gptel-model-updater-select-all-targets'."
  :type '(repeat (choice (list symbol symbol string)
                         (list symbol symbol string
                               (repeat (choice symbol string)))))
  :group 'gptel-model-updater)

(defun gptel-model-updater--backends ()
  "Return backend symbols managed by `gptel-model-updater'."
  (delq nil (mapcar #'gptel-model-updater--backend-spec-symbol
                    gptel-model-updater-backends)))

(defun gptel-model-updater--backend-spec-symbol (spec)
  "Return backend variable symbol from SPEC."
  (cond
   ((symbolp spec) spec)
   ((and (consp spec) (symbolp (car spec))) (car spec))))

(defun gptel-model-updater--backend-spec-providers (spec)
  "Return metadata providers configured in backend SPEC."
  (when (consp spec)
    (let ((providers (plist-get (cdr spec) :providers)))
      (cond
       ((null providers) nil)
       ((listp providers) providers)
       (t (list providers))))))

(defun gptel-model-updater--backend-providers (backend)
  "Return metadata providers configured for BACKEND."
  (catch 'providers
    (dolist (spec gptel-model-updater-backends)
      (when-let* ((symbol (gptel-model-updater--backend-spec-symbol spec))
                  ((boundp symbol))
                  ((eq (symbol-value symbol) backend)))
        (throw 'providers
               (gptel-model-updater--backend-spec-providers spec))))))

(defun gptel-model-updater--backend-p (backend predicate)
  "Return non-nil when BACKEND satisfies PREDICATE.
PREDICATE may be undefined if the corresponding gptel provider file has not
been loaded yet."
  (and (fboundp predicate)
       (funcall predicate backend)))

(defun gptel-model-updater--detect-provider (backend)
  "Detect provider type for BACKEND struct.
Returns one of `openai', `gemini', or `ollama'."
  (cond
   ((gptel-model-updater--backend-p backend 'gptel-gemini-p) 'gemini)
   ((gptel-model-updater--backend-p backend 'gptel-ollama-p) 'ollama)
   ((gptel-model-updater--backend-p backend 'gptel-openai-p) 'openai)
   (t 'openai)))

(defun gptel-model-updater--build-url (backend provider-type &optional api-key)
  "Build the models list URL for BACKEND given PROVIDER-TYPE.
API-KEY is used for providers that require it in the query string."
  (let ((host (gptel-backend-host backend))
        (endpoint (gptel-backend-endpoint backend))
        (protocol (or (gptel-backend-protocol backend) "https")))
    (pcase provider-type
      ('gemini
       (format "%s://%s/v1beta/models?key=%s&pageSize=1000" protocol host (or api-key "")))
      ('ollama
       (format "%s://%s/api/tags" protocol host))
      (_
       (let* ((base-path (replace-regexp-in-string "chat/completions.*" "" (or endpoint "")))
              (models-url (concat base-path "models")))
         (format "%s://%s%s" protocol host models-url))))))

(defun gptel-model-updater--build-headers (provider-type api-key)
  "Build request headers for PROVIDER-TYPE with API-KEY."
  (append '(("Content-Type" . "application/json"))
          (pcase provider-type
            ('openai
             (when api-key
               `(("Authorization" . ,(concat "Bearer " api-key)))))
            ;; Gemini uses query param for key, no auth header needed
            (_ nil))))

(defun gptel-model-updater--curl-program ()
  "Return the curl executable configured by `gptel-use-curl'."
  (if (stringp gptel-use-curl) gptel-use-curl "curl"))

(defun gptel-model-updater--get-api-key (backend key-source)
  "Get API key for BACKEND from KEY-SOURCE.
Bind `gptel-backend' while resolving KEY-SOURCE so auth-source
lookups use BACKEND's host instead of the current chat backend."
  (when key-source
    (let ((gptel-backend backend))
      (ignore-errors (gptel--get-api-key key-source)))))

(defun gptel-model-updater--parse-response (provider-type body)
  "Parse BODY for PROVIDER-TYPE and return (t . RAW-DATA).
Return nil when BODY is not valid JSON."
  (let* ((json-object-type 'alist)
         (json-key-type 'symbol)
         (response (condition-case nil
                       (json-read-from-string body)
                     (error nil))))
    (when response
      (let ((raw-data (pcase provider-type
                        ('gemini (alist-get 'models response))
                        ('ollama (alist-get 'models response))
                        (_ (alist-get 'data response)))))
        (cons t (if (vectorp raw-data) (append raw-data nil) raw-data))))))

(defun gptel-model-updater--http-success-p (code)
  "Return non-nil when HTTP CODE is a 2xx status."
  (and (integerp code) (<= 200 code) (< code 300)))

(defun gptel-model-updater--fetch-models-with-curl (backend-name provider-type url headers callback)
  "Fetch models using curl and call CALLBACK with the result.
BACKEND-NAME is used for messages.
PROVIDER-TYPE is `openai', `ollama', or `gemini'.
URL is the endpoint to fetch from.
HEADERS is the request headers alist.
CALLBACK is called with (success raw-data error-message)."
  (let* ((status-marker "\n__GPTEL_MODEL_UPDATER_HTTP_STATUS__:")
         (args (list "--silent" "--show-error"
                     "--max-time" (number-to-string gptel-model-updater-timeout)
                     "--write-out" (concat status-marker "%{http_code}")))
         (output-buf (generate-new-buffer " *gptel-model-updater-curl*")))
    (dolist (h headers)
      (setq args (append args (list "-H" (format "%s: %s" (car h) (cdr h))))))
    (setq args (append args (list url)))
    (make-process
     :name (format "gptel-model-updater-%s" backend-name)
     :buffer output-buf
     :command (cons (gptel-model-updater--curl-program) args)
     :noquery t
     :sentinel
     (lambda (proc event)
       (when (memq (process-status proc) '(exit signal))
         (let ((buffer (process-buffer proc))
               (exit-status (process-exit-status proc)))
           (unwind-protect
               (if (not (zerop exit-status))
                   (funcall callback nil nil
                            (format "curl process %s" (string-trim event)))
                 (with-current-buffer buffer
                   (let* ((output (buffer-string))
                          (status-pos (string-match (regexp-quote status-marker) output))
                          (body (if status-pos (substring output 0 status-pos) output))
                          (http-code (and status-pos
                                          (string-to-number
                                           (substring output
                                                      (+ status-pos (length status-marker))))))
                          (parsed (and (gptel-model-updater--http-success-p http-code)
                                       (gptel-model-updater--parse-response
                                        provider-type body))))
                     (cond
                      ((not (gptel-model-updater--http-success-p http-code))
                       (funcall callback nil nil
                                (format "HTTP %s" (or http-code "unknown"))))
                      ((not parsed)
                       (funcall callback nil nil "Failed to parse JSON"))
                      (t
                       (funcall callback t (cdr parsed) nil))))))
             (when (buffer-live-p buffer)
               (kill-buffer buffer)))))))))

(defun gptel-model-updater--fetch-models-with-url (_backend-name provider-type url headers callback)
  "Fetch models using `url-retrieve' and call CALLBACK with the result.
PROVIDER-TYPE is `openai', `ollama', or `gemini'.
URL is the endpoint to fetch from.
HEADERS is the request headers alist.
CALLBACK is called with (success raw-data error-message)."
  (let ((url-request-method "GET")
        (url-request-extra-headers headers))
    (url-retrieve
     url
     (lambda (status)
       (unwind-protect
           (let ((error-info (plist-get status :error)))
             (if error-info
                 (funcall callback nil nil (format "%s" error-info))
               (let ((http-code (url-http-parse-response)))
                 (cond
                  ((not (gptel-model-updater--http-success-p http-code))
                   (funcall callback nil nil
                            (format "HTTP %s" (or http-code "unknown"))))
                  (t
                   (goto-char (point-min))
                   (if (not (re-search-forward "\r?\n\r?\n" nil t))
                       (funcall callback nil nil "Malformed HTTP response")
                     (let ((parsed (gptel-model-updater--parse-response
                                    provider-type
                                    (buffer-substring-no-properties
                                     (point) (point-max)))))
                       (if parsed
                           (funcall callback t (cdr parsed) nil)
                         (funcall callback nil nil
                                  "Failed to parse JSON")))))))))
         (when (buffer-live-p (current-buffer))
           (kill-buffer (current-buffer)))))
     nil t t)))

(defun gptel-model-updater--fetch-models (backend-name provider-type url headers callback)
  "Fetch models from URL and call CALLBACK with the result.
BACKEND-NAME is used for messages.
PROVIDER-TYPE is `openai', `ollama', or `gemini'.
URL is the endpoint to fetch from.
HEADERS is the request headers alist.
CALLBACK is called with (success raw-data error-message)."
  (message "GPTel-Model-Updater: Contacting %s..." backend-name)
  (if gptel-use-curl
      (gptel-model-updater--fetch-models-with-curl
       backend-name provider-type url headers callback)
    (gptel-model-updater--fetch-models-with-url
     backend-name provider-type url headers callback)))

(defun gptel-model-updater--parse-models (raw-data provider-type)
  "Parse RAW-DATA from PROVIDER-TYPE into a list of model symbols."
  (let ((models nil))
    (dolist (m raw-data)
      (let ((id (pcase provider-type
                  ('gemini
                   ;; Gemini returns "models/gemini-2.5-pro", strip prefix
                   (let ((name (or (alist-get 'name m) "")))
                     (if (string-prefix-p "models/" name)
                         (substring name 7)
                       name)))
                  (_
                   (or (alist-get 'id m)
                       (alist-get 'name m))))))
        (when (and id (not (string-empty-p id)))
          (push (intern id) models))))
    (setq models (delete-dups (nreverse models)))
    (when (and models gptel-model-updater-sort-models)
      (setq models (sort models
                         (lambda (a b)
                           (string< (symbol-name a) (symbol-name b))))))
    models))

(defun gptel-model-updater--get-backends ()
  "Get list of available backend names.
Iterates over `gptel-model-updater-backends' and returns their name strings."
  (cl-loop for sym in (gptel-model-updater--backends)
           when (and (symbolp sym) (boundp sym))
           collect (gptel-backend-name (symbol-value sym))))

(defun gptel-model-updater--random-model (models)
  "Return a random model from MODELS."
  (nth (random (length models)) models))

(defun gptel-model-updater--split-model-entry (entry)
  "Return ENTRY as (BACKEND-NAME . MODEL), or nil for unsupported entries."
  (let ((entry-name (cond
                     ((symbolp entry) (symbol-name entry))
                     ((stringp entry) entry))))
    (when entry-name
      (if (string-match-p ":" entry-name)
          (pcase-let ((`(,backend-name ,model-name)
                       (string-split entry-name ":" t)))
            (when (and backend-name model-name)
              (cons backend-name (intern model-name))))
        nil))))

(defun gptel-model-updater--normalize-model-list (models)
  "Return MODELS as preferred (BACKEND-NAME . MODEL) entries."
  (delq nil (mapcar #'gptel-model-updater--split-model-entry models)))

(defun gptel-model-updater--pick-preferred-backend-model (model-list)
  "Pick the first available backend/model following MODEL-LIST order."
  (catch 'found
    (pcase-dolist (`(,backend-name . ,model)
                   (gptel-model-updater--normalize-model-list model-list))
      (dolist (backend-symbol (gptel-model-updater--backends))
        (when-let* ((backend (and (symbolp backend-symbol)
                                  (boundp backend-symbol)
                                  (symbol-value backend-symbol)))
                    (models (gptel-backend-models backend)))
          (when (and (or (not backend-name)
                         (string= backend-name (gptel-backend-name backend)))
                     (memq model models))
            (throw 'found (cons backend model))))))))

(defun gptel-model-updater--order-models (models &optional model-list backend-name)
  "Return MODELS with MODEL-LIST entries for BACKEND-NAME first."
  (let (selected)
    (pcase-dolist (`(,entry-backend-name . ,model)
                   (gptel-model-updater--normalize-model-list model-list))
      (when (and (or (not entry-backend-name)
                     (string= entry-backend-name backend-name))
                 (memq model models)
                 (not (memq model selected)))
        (setq selected (append selected (list model)))))
    (append selected (cl-remove-if (lambda (model) (memq model selected)) models))))

(defun gptel-model-updater--backend-filter (backend-name)
  "Return ingress filter plist configured for BACKEND-NAME."
  (when backend-name
    (cdr (cl-find backend-name gptel-model-updater-backend-filters
                  :key #'car
                  :test (lambda (name entry-name)
                          (string= name
                                   (if (symbolp entry-name)
                                       (symbol-name entry-name)
                                     entry-name)))))))

(defun gptel-model-updater--filter-value (backend-name key fallback)
  "Return BACKEND-NAME filter value for KEY, or FALLBACK when omitted."
  (let ((filter (gptel-model-updater--backend-filter backend-name)))
    (if (plist-member filter key)
        (plist-get filter key)
      fallback)))

(defun gptel-model-updater--include-regexp (backend-name)
  "Return effective include regexp for BACKEND-NAME."
  (gptel-model-updater--filter-value
   backend-name :include gptel-model-updater-include-model-regexp))

(defun gptel-model-updater--exclude-regexp (backend-name)
  "Return effective exclude regexp for BACKEND-NAME."
  (gptel-model-updater--filter-value
   backend-name :exclude gptel-model-updater-exclude-model-regexp))

(defun gptel-model-updater--max-models (backend-name)
  "Return effective maximum model count for BACKEND-NAME."
  (gptel-model-updater--filter-value
   backend-name :max gptel-model-updater-max-models))

(defun gptel-model-updater--model-allowed-p (model backend-name)
  "Return non-nil when MODEL passes ingress filters for BACKEND-NAME."
  (let ((model-name (symbol-name model))
        (include-regexp (gptel-model-updater--include-regexp backend-name))
        (exclude-regexp (gptel-model-updater--exclude-regexp backend-name)))
    (and (or (not include-regexp)
             (string-match-p include-regexp model-name))
         (or (not exclude-regexp)
             (not (string-match-p exclude-regexp model-name))))))

(defun gptel-model-updater--filter-models (models backend-name)
  "Return MODELS that pass ingress filters for BACKEND-NAME."
  (cl-remove-if-not
   (lambda (model)
     (gptel-model-updater--model-allowed-p model backend-name))
   models))

(defun gptel-model-updater--limit-models (models backend-name)
  "Return MODELS limited by the effective maximum for BACKEND-NAME."
  (let ((max-models (gptel-model-updater--max-models backend-name)))
    (if (and (integerp max-models)
             (natnump max-models))
        (seq-take models max-models)
      models)))

(defun gptel-model-updater--prepare-models (models &optional model-list backend-name)
  "Filter, order, and limit MODELS for BACKEND-NAME.
MODEL-LIST contains preferred model entries moved to the front before the
maximum model count is applied."
  (gptel-model-updater--limit-models
   (gptel-model-updater--order-models
    (gptel-model-updater--filter-models models backend-name)
    model-list
    backend-name)
   backend-name))

(defun gptel-model-updater--merge-models-preserving-existing (old-models new-models)
  "Return OLD-MODELS with models from NEW-MODELS appended when missing."
  (let ((models (copy-sequence old-models)))
    (dolist (model new-models)
      (unless (memq model models)
        (setq models (append models (list model)))))
    models))

(defun gptel-model-updater--pick-backend-model (&optional model-list)
  "Pick an available backend/model.
When MODEL-LIST is non-nil, prefer models in that order.  Otherwise, pick
the first available managed backend and a random model."
  (or (and model-list
           (gptel-model-updater--pick-preferred-backend-model model-list))
      (catch 'found
        (dolist (backend-symbol (gptel-model-updater--backends))
          (when-let* ((backend (and (symbolp backend-symbol)
                                    (boundp backend-symbol)
                                    (symbol-value backend-symbol)))
                      (models (gptel-backend-models backend)))
            (throw 'found (cons backend (gptel-model-updater--random-model models))))))))

(defun gptel-model-updater--target-models (target)
  "Return preferred model list configured on external TARGET."
  (nth 3 target))

(defun gptel-model-updater--effective-model-list (&optional model-list)
  "Return MODEL-LIST or `gptel-model-updater-models'."
  (or model-list gptel-model-updater-models))

(defun gptel-model-updater--available-backends ()
  "Return configured backends that have model lists."
  (cl-loop for backend-symbol in (gptel-model-updater--backends)
           when (and (symbolp backend-symbol)
                     (boundp backend-symbol)
                     (gptel-backend-models (symbol-value backend-symbol)))
           collect (symbol-value backend-symbol)))

(defun gptel-model-updater--read-model-name (prompt models)
  "Read a model name from MODELS with metadata annotations."
  (let* ((model-names (mapcar #'symbol-name models))
         (models-alist (cl-mapcar #'cons model-names models))
         (completion-extra-properties
          `(:annotation-function
            ,(lambda (comp)
               (when-let* ((model (cdr (assoc comp models-alist))))
                 (gptel-model-updater-ui--format-model-annotation model))))))
    (completing-read prompt model-names nil t)))

(defun gptel-model-updater--read-backend-model (&optional prompt-prefix)
  "Read a backend and model interactively.
PROMPT-PREFIX is prepended to completion prompts."
  (let* ((backends (gptel-model-updater--available-backends))
         (prompt-prefix (or prompt-prefix ""))
         (backend-name (completing-read
                        (format "%sBackend: " prompt-prefix)
                        (mapcar #'gptel-backend-name backends)
                        nil t))
         (backend (cl-find backend-name backends
                           :key #'gptel-backend-name
                           :test #'string=))
         (model-name (gptel-model-updater--read-model-name
                      (format "%sModel: " prompt-prefix)
                      (gptel-backend-models backend))))
    (cons backend (intern model-name))))

(defun gptel-model-updater--set-choice (backend-variable model-variable choice)
  "Set BACKEND-VARIABLE and MODEL-VARIABLE from CHOICE."
  (when choice
    (set backend-variable (car choice))
    (set model-variable (cdr choice))))

(defun gptel-model-updater--target-label (target)
  "Return display label for external TARGET."
  (or (nth 2 target) (symbol-name (car target))))

(defun gptel-model-updater--default-target-fields ()
  "Return display fields for the default GPTel target."
  (list "GPTel"
        (and (boundp 'gptel-backend) gptel-backend
             (gptel-backend-name gptel-backend))
        (and (boundp 'gptel-model) gptel-model)))

(defun gptel-model-updater--external-target-fields (target)
  "Return display fields for external TARGET."
  (pcase-let ((`(,backend-variable ,model-variable . ,_) target))
    (list (gptel-model-updater--target-label target)
          (and (boundp backend-variable)
               (symbol-value backend-variable)
               (gptel-backend-name (symbol-value backend-variable)))
          (and (boundp model-variable)
               (symbol-value model-variable)))))

(defun gptel-model-updater--pad-target-field (field width)
  "Pad FIELD with spaces to WIDTH plus a two-column gap."
  (concat field (make-string (+ 2 (- width (string-width field))) ?\s)))

(defun gptel-model-updater--format-target-fields (targets &optional style)
  "Format TARGETS with aligned backend and model columns.
Each entry in TARGETS is (LABEL BACKEND MODEL).  STYLE `plain' omits
punctuation and field prefixes.  Any other non-nil STYLE also adds a header."
  (let* ((fields (mapcar (lambda (target)
                           (mapcar (lambda (field) (format "%s" field))
                                   target))
                         targets))
         (rows
          (cond
           ((eq style 'plain) fields)
           (style (cons '("Target" "Backend" "Model") fields))
           (t (mapcar (lambda (target)
                        (list (format "%s:" (nth 0 target))
                              (format "backend=%s" (nth 1 target))
                              (format "model=%s" (nth 2 target))))
                      targets))))
         (label-width
          (apply #'max (mapcar (lambda (row) (string-width (nth 0 row)))
                               rows)))
         (backend-width
          (apply #'max (mapcar (lambda (row) (string-width (nth 1 row)))
                               rows))))
    (mapconcat
     (lambda (row)
       (let ((label (nth 0 row))
             (backend (nth 1 row))
             (model (nth 2 row)))
         (concat (gptel-model-updater--pad-target-field label label-width)
                 (gptel-model-updater--pad-target-field backend backend-width)
                 model)))
     rows
     "\n")))

(defun gptel-model-updater--format-default-target ()
  "Return a display string for the default GPTel target."
  (gptel-model-updater--format-target-fields
   (list (gptel-model-updater--default-target-fields))))

(defun gptel-model-updater--format-external-target (target)
  "Return a display string for external TARGET."
  (gptel-model-updater--format-target-fields
   (list (gptel-model-updater--external-target-fields target))))

(defun gptel-model-updater--format-external-targets ()
  "Return a display string for all configured external targets."
  (gptel-model-updater--format-target-fields
   (mapcar #'gptel-model-updater--external-target-fields
           gptel-model-updater-external-targets)
   t))

(defun gptel-model-updater--format-all-targets ()
  "Return a display string for all configured targets."
  (gptel-model-updater--format-target-fields
   (cons (gptel-model-updater--default-target-fields)
         (mapcar #'gptel-model-updater--external-target-fields
                 gptel-model-updater-external-targets))
   t))

(defun gptel-model-updater--read-target ()
  "Read one configured target interactively."
  (let* ((targets
          (cons '("GPTel" . gptel)
                (mapcar (lambda (target)
                          (cons (gptel-model-updater--target-label target)
                                target))
                        gptel-model-updater-external-targets)))
         (label (completing-read "Target: " targets nil t)))
    (cdr (assoc label targets))))

(defun gptel-model-updater--select-external-target
    (target interactivep &optional model-list)
  "Set external TARGET.
When INTERACTIVEP is non-nil, read its backend and model with completion;
otherwise select them from MODEL-LIST or randomly."
  (pcase-let ((`(,backend-variable ,model-variable . ,_) target))
    (when (and (symbolp backend-variable) (symbolp model-variable))
      (gptel-model-updater--set-choice
       backend-variable model-variable
       (if interactivep
           (gptel-model-updater--read-backend-model
            (format "%s " (gptel-model-updater--target-label target)))
         (gptel-model-updater--pick-backend-model
          (or (gptel-model-updater--target-models target)
              model-list)))))))

(defun gptel-model-updater--select-external-targets (interactivep &optional model-list)
  "Set configured external targets.
When INTERACTIVEP is non-nil, read each target with completion;
otherwise select each target from MODEL-LIST or randomly."
  (dolist (target gptel-model-updater-external-targets)
    (gptel-model-updater--select-external-target
     target interactivep model-list)))

;;;###autoload
(defun gptel-model-updater-select-default-target (&optional quiet interactivep model-list)
  "Select the default GPTel backend/model target from refreshed model lists.
Interactively, read backend and model with completion.  Otherwise, entries
in MODEL-LIST are tried in order.  Each entry may be BACKEND:MODEL, or just
MODEL to search across `gptel-model-updater-backends'.  If MODEL-LIST is
nil, use `gptel-model-updater-models'.  If neither list selects a model,
the first backend with models is selected, and one model is chosen randomly.

When QUIET is non-nil, do not print the final selection.  When INTERACTIVEP
is non-nil, read backend and model with completion."
  (interactive (list nil t))
  (setq model-list (gptel-model-updater--effective-model-list model-list))
  (gptel-model-updater--set-choice
   'gptel-backend 'gptel-model
   (if interactivep
       (gptel-model-updater--read-backend-model "GPTel ")
     (gptel-model-updater--pick-backend-model model-list)))
  (unless quiet
    (message "GPTel target set\n%s"
             (gptel-model-updater--format-default-target))))

;;;###autoload
(defun gptel-model-updater-select-external-targets (&optional quiet interactivep model-list)
  "Select configured external target backend/model variables.
External targets are configured with `gptel-model-updater-external-targets'.
When INTERACTIVEP is non-nil, read each target with completion.  Otherwise,
entries in MODEL-LIST or `gptel-model-updater-models' are tried first.
When QUIET is non-nil, do not print the final selections."
  (interactive (list nil t))
  (setq model-list (gptel-model-updater--effective-model-list model-list))
  (gptel-model-updater--select-external-targets interactivep model-list)
  (when (and gptel-model-updater-external-targets (not quiet))
    (message "GPTel external targets set\n%s"
             (gptel-model-updater--format-external-targets))))

;;;###autoload
(defun gptel-model-updater-select-all-targets (&optional quiet interactivep model-list)
  "Select all configured backend/model targets.
The global `gptel-backend' and `gptel-model' variables are selected first.
Then `gptel-model-updater-external-targets' are selected.  MODEL-LIST
overrides `gptel-model-updater-models'.  When QUIET is non-nil, do not print
selection messages.  When INTERACTIVEP is non-nil, select one target, then
read its backend and model with completion.

With \\[universal-argument], interactively select which target to update."
  (interactive (list nil current-prefix-arg))
  (setq model-list (gptel-model-updater--effective-model-list model-list))
  (if interactivep
      (let ((target (if gptel-model-updater-external-targets
                        (gptel-model-updater--read-target)
                      'gptel)))
        (if (eq target 'gptel)
            (gptel-model-updater-select-default-target t t model-list)
          (gptel-model-updater--select-external-target target t model-list))
        (unless quiet
          (message "GPTel target set\n%s"
                   (if (eq target 'gptel)
                       (gptel-model-updater--format-default-target)
                     (gptel-model-updater--format-external-target target)))))
    (gptel-model-updater-select-default-target t nil model-list)
    (gptel-model-updater-select-external-targets t nil model-list)
    (unless quiet
      (message "GPTel targets set\n%s"
               (gptel-model-updater--format-all-targets)))))

;;;###autoload
(defun gptel-model-updater-update-backend
    (backend-name &optional provider-type url model-list done-callback)
  "Update models for BACKEND-NAME.
PROVIDER-TYPE can be `openai', `ollama', or `gemini'.
If nil, it is auto-detected from the backend struct type.
URL overrides the default endpoint.  MODEL-LIST orders available models.
DONE-CALLBACK is called after this backend update finishes."
  (interactive
   (let ((backends (gptel-model-updater--get-backends)))
     (list (completing-read "Backend: " backends nil t))))
  (let* ((backend (gptel-get-backend backend-name))
         (provider (or provider-type (gptel-model-updater--detect-provider backend)))
         (key-source (gptel-backend-key backend))
         (api-key (gptel-model-updater--get-api-key backend key-source)))
    (if (and (memq provider '(openai gemini)) key-source (not api-key))
        (progn
          (message "GPTel-Model-Updater: Skipping %s, no API key found" backend-name)
          (when done-callback
            (funcall done-callback)))
      (let ((fetch-url (or url (gptel-model-updater--build-url backend provider api-key)))
            (headers (gptel-model-updater--build-headers provider api-key)))
        (gptel-model-updater--fetch-models
         backend-name provider fetch-url headers
         (lambda (success raw-data error-msg)
           (unwind-protect
               (if (not success)
                   (message "GPTel-Model-Updater Error: %s (%s)" backend-name error-msg)
                (let* ((parsed-models (gptel-model-updater--parse-models raw-data provider))
                       (new-models (gptel-model-updater--prepare-models
                                    parsed-models
                                    (gptel-model-updater--effective-model-list model-list)
                                    backend-name))
                       (merged-models
                        (gptel-model-updater--merge-models-preserving-existing
                         (gptel-backend-models backend)
                         new-models)))
                  (if (not new-models)
                      (message "GPTel-Model-Updater: No models found for %s" backend-name)
                    (gptel-model-updater-metadata-apply merged-models backend provider)
                    (setf (gptel-backend-models backend) merged-models)
                    (message "GPTel-Model-Updater: Updated %s with %d models%s"
                             backend-name
                             (length merged-models)
                             (if (= (length new-models) (length parsed-models))
                                 ""
                               (format " from %d fetched models" (length parsed-models))))
                    (run-hook-with-args 'gptel-model-updater-after-update-hook
                                        backend-name backend merged-models))))
             (when done-callback
               (funcall done-callback)))))))))

;;;###autoload
(defun gptel-model-updater-update-all (&optional model-list)
  "Update models for all configured GPTel backends.
MODEL-LIST orders available models."
  (interactive)
  (let* ((backend-names (cl-loop for sym in (gptel-model-updater--backends)
                                 when (and (symbolp sym) (boundp sym))
                                 collect (gptel-backend-name (symbol-value sym))))
         (remaining (length backend-names)))
    (cl-labels ((done ()
                  (cl-decf remaining)
                  (when (<= remaining 0)
                    (run-hooks 'gptel-model-updater-after-update-all-hook))))
      (if (zerop remaining)
          (run-hooks 'gptel-model-updater-after-update-all-hook)
        (dolist (name backend-names)
          (condition-case err
              (gptel-model-updater-update-backend name nil nil model-list #'done)
            (error
             (message "GPTel-Model-Updater: Failed to update %s: %s" name err)
             (done))))))))

(provide 'gptel-model-updater)
;;; gptel-model-updater.el ends here
