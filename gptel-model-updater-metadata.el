;;; gptel-model-updater-metadata.el --- models.dev metadata for gptel-model-updater -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Misaka

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Fetch and translate models.dev metadata into gptel model properties.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'gptel)

(defcustom gptel-model-updater-model-metadata-url "https://models.dev/api.json"
  "URL for models.dev model metadata.
When nil, refreshed models are written without additional model properties."
  :type '(choice (const :tag "Disable metadata" nil)
                 string)
  :group 'gptel-model-updater)

(defvar gptel-model-updater-timeout)

(defvar gptel-model-updater-backends)

(declare-function gptel-model-updater--backend-providers "gptel-model-updater")

(defvar gptel-model-updater-metadata--cache nil
  "Cached models.dev provider metadata.")

(defvar gptel-model-updater-metadata--cache-url nil
  "URL used to populate `gptel-model-updater-metadata--cache'.")

(defconst gptel-model-updater-metadata--known-provider-hosts
  '(("api.openai.com" . openai)
    ("generativelanguage.googleapis.com" . google)
    ("openrouter.ai" . openrouter)
    ("api.deepseek.com" . deepseek)
    ("api.moonshot.ai" . moonshotai)
    ("api.moonshot.cn" . moonshotai-cn)
    ("api.fireworks.ai" . fireworks-ai))
  "Known provider hosts for providers with missing or non-standard API fields.")

(defconst gptel-model-updater-metadata--mime-types
  '((image . ("image/jpeg" "image/png" "image/gif" "image/webp"))
    (pdf . ("application/pdf"))
    (audio . ("audio/mpeg" "audio/wav" "audio/mp4"))
    (video . ("video/mp4" "video/mpeg" "video/webm")))
  "MIME types inferred from models.dev modality names.")

(defun gptel-model-updater-metadata--curl-program ()
  "Return the curl executable configured by `gptel-use-curl'."
  (if (stringp gptel-use-curl) gptel-use-curl "curl"))

(defun gptel-model-updater-metadata--parse-json (body)
  "Parse BODY as JSON into an alist, or return nil."
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'symbol))
    (condition-case nil
        (json-read-from-string body)
      (error nil))))

(defun gptel-model-updater-metadata--fetch-with-curl (url)
  "Fetch URL with curl and return parsed JSON."
  (let* ((status-marker "\n__GPTEL_MODEL_UPDATER_HTTP_STATUS__:")
         (args (list "--silent" "--show-error"
                     "--max-time" (number-to-string gptel-model-updater-timeout)
                     "--write-out" (concat status-marker "%{http_code}")
                     url))
         (buffer (generate-new-buffer " *gptel-model-updater-metadata-curl*")))
    (unwind-protect
        (when (zerop (apply #'call-process
                            (gptel-model-updater-metadata--curl-program)
                            nil buffer nil args))
          (with-current-buffer buffer
            (let* ((output (buffer-string))
                   (status-pos (string-match (regexp-quote status-marker) output))
                   (body (if status-pos (substring output 0 status-pos) output))
                   (http-code (and status-pos
                                   (string-to-number
                                    (substring output
                                               (+ status-pos
                                                  (length status-marker)))))))
              (when (and (integerp http-code) (<= 200 http-code) (< http-code 300))
                (gptel-model-updater-metadata--parse-json body)))))
      (kill-buffer buffer))))

(defun gptel-model-updater-metadata--fetch-with-url (url)
  "Fetch URL with `url-retrieve-synchronously' and return parsed JSON."
  (let ((url-request-method "GET"))
    (with-current-buffer (url-retrieve-synchronously
                          url t t gptel-model-updater-timeout)
      (unwind-protect
          (let ((http-code (url-http-parse-response)))
            (when (and (integerp http-code) (<= 200 http-code) (< http-code 300))
              (goto-char (point-min))
              (when (re-search-forward "\r?\n\r?\n" nil t)
                (gptel-model-updater-metadata--parse-json
                 (buffer-substring-no-properties (point) (point-max))))))
        (kill-buffer (current-buffer))))))

(defun gptel-model-updater-metadata--fetch (url)
  "Fetch URL as JSON, respecting `gptel-use-curl'."
  (when url
    (if gptel-use-curl
        (gptel-model-updater-metadata--fetch-with-curl url)
      (gptel-model-updater-metadata--fetch-with-url url))))

(defun gptel-model-updater-metadata-get ()
  "Return cached models.dev metadata, fetching it when needed."
  (when gptel-model-updater-model-metadata-url
    (unless (and gptel-model-updater-metadata--cache
                 (equal gptel-model-updater-metadata--cache-url
                        gptel-model-updater-model-metadata-url))
      (setq gptel-model-updater-metadata--cache
            (gptel-model-updater-metadata--fetch
             gptel-model-updater-model-metadata-url)
            gptel-model-updater-metadata--cache-url
            gptel-model-updater-model-metadata-url))
    gptel-model-updater-metadata--cache))

(defun gptel-model-updater-clear-model-metadata-cache ()
  "Clear cached models.dev metadata used for model properties."
  (interactive)
  (setq gptel-model-updater-metadata--cache nil
        gptel-model-updater-metadata--cache-url nil))

(defun gptel-model-updater-metadata--host (backend)
  "Return normalized host for BACKEND."
  (downcase (or (gptel-backend-host backend) "")))

(defun gptel-model-updater-metadata--provider-api-host (provider-entry)
  "Return normalized API host from PROVIDER-ENTRY."
  (when-let* ((api (alist-get 'api provider-entry))
              (url (url-generic-parse-url api))
              (host (url-host url)))
    (downcase host)))

(defun gptel-model-updater-metadata--provider-list (providers)
  "Return PROVIDERS as a provider key list."
  (cond
   ((null providers) nil)
   ((listp providers) providers)
   (t (list providers))))

(defun gptel-model-updater-metadata--host-provider-entry (backend host-alist)
  "Return provider mapping entry for BACKEND from HOST-ALIST."
  (let ((host (gptel-model-updater-metadata--host backend)))
    (cl-find-if (lambda (entry)
                  (string-match-p (regexp-quote (car entry)) host))
                host-alist)))

(defun gptel-model-updater-metadata--dedupe-providers (providers)
  "Return PROVIDERS without duplicate provider keys."
  (let (result)
    (dolist (provider providers)
      (when (and provider (not (memq provider result)))
        (setq result (append result (list provider)))))
    result))

(defun gptel-model-updater-metadata--provider-keys (backend provider-type metadata)
  "Return candidate models.dev provider keys for BACKEND and PROVIDER-TYPE."
  (let ((host (gptel-model-updater-metadata--host backend)))
    (gptel-model-updater-metadata--dedupe-providers
     (append
      (gptel-model-updater-metadata--provider-list
       (gptel-model-updater--backend-providers backend))
      (gptel-model-updater-metadata--provider-list
       (pcase provider-type
         ('gemini 'google)
         ('ollama nil)
         (_ nil)))
      (gptel-model-updater-metadata--provider-list
       (cdr (gptel-model-updater-metadata--host-provider-entry
             backend gptel-model-updater-metadata--known-provider-hosts)))
      (cl-loop for entry in metadata
               for api-host = (gptel-model-updater-metadata--provider-api-host
                               (cdr entry))
               when (and api-host
                         (or (string= host api-host)
                             (string-suffix-p api-host host)
                             (string-suffix-p host api-host)))
               collect (car entry))))))

(defun gptel-model-updater-metadata--provider-key (backend provider-type metadata)
  "Return the first models.dev provider key for BACKEND.
This compatibility helper returns the first candidate from
`gptel-model-updater-metadata--provider-keys'."
  (car (gptel-model-updater-metadata--provider-keys
        backend provider-type metadata)))

(defun gptel-model-updater-metadata--model-entry (metadata provider-key model)
  "Return METADATA model entry for PROVIDER-KEY and MODEL."
  (when-let* ((provider (alist-get provider-key metadata))
              (models (alist-get 'models provider)))
    (alist-get (intern (symbol-name model)) models)))

(defun gptel-model-updater-metadata--find-model-entry (metadata provider-key model)
  "Return (PROVIDER-KEY . MODEL-ENTRY) for MODEL in METADATA.
When PROVIDER-KEY is `all', search all providers in metadata order."
  (if (eq provider-key 'all)
      (catch 'found
        (dolist (provider metadata)
          (when-let* ((model-entry (gptel-model-updater-metadata--model-entry
                                    metadata (car provider) model)))
            (throw 'found (cons (car provider) model-entry)))))
    (when-let* ((model-entry (gptel-model-updater-metadata--model-entry
                              metadata provider-key model)))
      (cons provider-key model-entry))))

(defun gptel-model-updater-metadata--truthy-p (value)
  "Return non-nil when VALUE is non-nil and not JSON false."
  (and value (not (eq value :json-false))))

(defun gptel-model-updater-metadata--modalities (model-entry direction)
  "Return modality symbols from MODEL-ENTRY for DIRECTION."
  (mapcar #'intern
          (or (alist-get direction (alist-get 'modalities model-entry))
              nil)))

(defun gptel-model-updater-metadata--context-window (model-entry)
  "Return gptel context window value for MODEL-ENTRY."
  (when-let* ((context (alist-get 'context (alist-get 'limit model-entry))))
    (if (zerop (% context 1000))
        (/ context 1000)
      (/ context 1000.0))))

(defun gptel-model-updater-metadata--capabilities
    (model-entry provider-key provider-type backend)
  "Return gptel capabilities for MODEL-ENTRY."
  (let ((input-modalities (gptel-model-updater-metadata--modalities model-entry 'input))
        capabilities)
    (when (gptel-model-updater-metadata--truthy-p
           (alist-get 'reasoning model-entry))
      (push 'reasoning capabilities))
    (when (seq-intersection input-modalities '(image pdf audio video))
      (push 'media capabilities))
    (when (gptel-model-updater-metadata--truthy-p
           (alist-get 'tool_call model-entry))
      (push 'tool-use capabilities))
    (when (gptel-model-updater-metadata--truthy-p
           (alist-get 'structured_output model-entry))
      (push 'json capabilities))
    (when (gptel-model-updater-metadata--truthy-p
           (alist-get 'attachment model-entry))
      (push 'url capabilities))
    (when (and (eq provider-key 'openai)
               (eq provider-type 'openai)
               (string-match-p "api\\.openai\\.com"
                               (gptel-model-updater-metadata--host backend)))
      (push 'responses-api capabilities))
    (nreverse capabilities)))

(defun gptel-model-updater-metadata--mime-types (model-entry)
  "Return MIME types inferred from MODEL-ENTRY."
  (let ((input-modalities (gptel-model-updater-metadata--modalities model-entry 'input)))
    (delete-dups
     (apply #'append
            (mapcar (lambda (modality)
                      (alist-get modality gptel-model-updater-metadata--mime-types))
                    input-modalities)))))

(defun gptel-model-updater-metadata--append (plist key value)
  "Append KEY VALUE to PLIST when VALUE is useful."
  (if (or (null value) (equal value '()))
      plist
    (append plist (list key value))))

(defun gptel-model-updater-metadata--model-plist
    (model-entry provider-key provider-type backend)
  "Return a gptel model plist for MODEL-ENTRY."
  (let* ((cost (alist-get 'cost model-entry))
         (plist nil))
    (setq plist (gptel-model-updater-metadata--append
                 plist :description (alist-get 'name model-entry)))
    (setq plist (gptel-model-updater-metadata--append
                 plist :capabilities
                 (gptel-model-updater-metadata--capabilities
                  model-entry provider-key provider-type backend)))
    (setq plist (gptel-model-updater-metadata--append
                 plist :mime-types
                 (gptel-model-updater-metadata--mime-types model-entry)))
    (setq plist (gptel-model-updater-metadata--append
                 plist :context-window
                 (gptel-model-updater-metadata--context-window model-entry)))
    (setq plist (gptel-model-updater-metadata--append
                 plist :input-cost (alist-get 'input cost)))
    (setq plist (gptel-model-updater-metadata--append
                 plist :output-cost (alist-get 'output cost)))
    (setq plist (gptel-model-updater-metadata--append
                 plist :cutoff-date (alist-get 'knowledge model-entry)))
    plist))

(defun gptel-model-updater-metadata--merge-missing (old-plist new-plist)
  "Return OLD-PLIST with keys from NEW-PLIST added when missing."
  (let ((plist (copy-sequence old-plist)))
    (while new-plist
      (unless (plist-member plist (car new-plist))
        (setq plist (append plist (list (car new-plist) (cadr new-plist)))))
      (setq new-plist (cddr new-plist)))
    plist))

(defun gptel-model-updater-metadata-apply (models backend provider-type)
  "Apply models.dev properties to MODELS for BACKEND and PROVIDER-TYPE.
Return MODELS unchanged when no matching metadata is available."
  (when-let* ((metadata (gptel-model-updater-metadata-get)))
    (let ((provider-keys (gptel-model-updater-metadata--provider-keys
                          backend provider-type metadata)))
      (dolist (model models)
        (catch 'found
          (dolist (provider-key provider-keys)
            (when-let* ((match (gptel-model-updater-metadata--find-model-entry
                                metadata provider-key model))
                        (matched-provider-key (car match))
                        (model-entry (cdr match))
                        (plist (gptel-model-updater-metadata--model-plist
                                model-entry matched-provider-key provider-type backend)))
              (setf (symbol-plist model)
                    (gptel-model-updater-metadata--merge-missing
                     (symbol-plist model)
                     plist))
              (throw 'found t)))))))
  models)

(provide 'gptel-model-updater-metadata)
;;; gptel-model-updater-metadata.el ends here
