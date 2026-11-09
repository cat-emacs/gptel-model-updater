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
When nil, refreshed models are written without additional model properties.
A readable `gptel-model-updater-model-metadata-file' is preferred over this
URL."
  :type '(choice (const :tag "Disable metadata" nil)
                 string)
  :group 'gptel-model-updater)

(defcustom gptel-model-updater-model-metadata-file nil
  "File of models.dev JSON used before `gptel-model-updater-model-metadata-url'.
When the file is readable, model properties are loaded from it and the URL
is not fetched.  A missing file falls back to the URL.  When nil, only the
URL is used."
  :type '(choice (const :tag "Fetch the metadata URL" nil)
                 file)
  :group 'gptel-model-updater)

(defcustom gptel-model-updater-metadata-overwrite-existing nil
  "Whether models.dev metadata should replace existing model properties.
When nil, models.dev metadata only fills missing model properties.  When
non-nil, matching models.dev keys replace existing values while unrelated
existing keys are preserved."
  :type 'boolean
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

(defun gptel-model-updater-metadata--read-file (file)
  "Return parsed JSON from FILE, or nil when it cannot be read."
  (when (and (stringp file) (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (gptel-model-updater-metadata--parse-json (buffer-string)))))

(defun gptel-model-updater-metadata-get ()
  "Return cached models.dev metadata, reading a file or fetching the URL.
A readable `gptel-model-updater-model-metadata-file' wins over
`gptel-model-updater-model-metadata-url'."
  (let* ((file gptel-model-updater-model-metadata-file)
         (stamp (and (stringp file)
                     (file-readable-p file)
                     (list 'file file
                           (file-attribute-modification-time
                            (file-attributes file))))))
    (if (and stamp
             (equal gptel-model-updater-metadata--cache-url stamp))
        gptel-model-updater-metadata--cache
      (let ((parsed (and stamp
                         (gptel-model-updater-metadata--read-file file))))
        (if parsed
            (progn
              (setq gptel-model-updater-metadata--cache parsed
                    gptel-model-updater-metadata--cache-url stamp)
              gptel-model-updater-metadata--cache)
          (when gptel-model-updater-model-metadata-url
            (unless (and gptel-model-updater-metadata--cache
                         (equal gptel-model-updater-metadata--cache-url
                                gptel-model-updater-model-metadata-url))
              (setq gptel-model-updater-metadata--cache
                    (gptel-model-updater-metadata--fetch
                     gptel-model-updater-model-metadata-url)
                    gptel-model-updater-metadata--cache-url
                    gptel-model-updater-model-metadata-url))
            gptel-model-updater-metadata--cache))))))

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

(defun gptel-model-updater-metadata--context-tokens (tokens)
  "Return gptel's thousand-token context window for TOKENS, or nil."
  (when (and (numberp tokens) (> tokens 0))
    (if (and (integerp tokens) (zerop (mod tokens 1000)))
        (/ tokens 1000)
      (/ tokens 1000.0))))

(defun gptel-model-updater-metadata--context-window (model-entry)
  "Return gptel context window value for MODEL-ENTRY."
  (gptel-model-updater-metadata--context-tokens
   (alist-get 'context (alist-get 'limit model-entry))))

(defun gptel-model-updater-metadata--per-token-cost (value)
  "Return USD per million tokens for per-token VALUE, or nil.
VALUE may be a number or a numeric string.  List prices are USD per token;
gptel costs are USD per million tokens."
  (let ((number (cond
                 ((numberp value) value)
                 ((and (stringp value)
                       (string-match-p "\\`[+-]?[0-9]" value))
                  (string-to-number value)))))
    (when number
      (* 1000000.0 number))))

(defun gptel-model-updater-metadata--sequence (value)
  "Return VALUE as a list."
  (cond
   ((null value) nil)
   ((listp value) value)
   (t (append value nil))))

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

(defun gptel-model-updater-metadata--merge (old-plist new-plist)
  "Return OLD-PLIST merged with NEW-PLIST following user settings."
  (let ((plist (copy-sequence old-plist)))
    (while new-plist
      (when (or gptel-model-updater-metadata-overwrite-existing
                (not (plist-member plist (car new-plist))))
        (if (plist-member plist (car new-plist))
            (setf (plist-get plist (car new-plist)) (cadr new-plist))
          (setq plist (append plist (list (car new-plist) (cadr new-plist))))))
      (setq new-plist (cddr new-plist)))
    plist))

(defun gptel-model-updater-metadata--plist-set (plist key value)
  "Return PLIST with KEY set to VALUE.
Remove KEY when VALUE is nil."
  (let ((plist (copy-sequence plist)))
    (if value
        (plist-put plist key value)
      (cl-loop for (k v) on plist by #'cddr
               unless (eq k key)
               append (list k v)))))

(defun gptel-model-updater-metadata--adjust-capabilities (capabilities changes)
  "Return CAPABILITIES adjusted by CHANGES.
CHANGES is a list of (CAPABILITY . PRESENT).  Unmentioned capabilities are
kept."
  (let ((capabilities (copy-sequence capabilities)))
    (pcase-dolist (`(,capability . ,present) changes)
      (setq capabilities
            (if present
                (if (memq capability capabilities)
                    capabilities
                  (append capabilities (list capability)))
              (delq capability capabilities))))
    capabilities))

(defun gptel-model-updater-metadata--list-spec (entry model provider-type)
  "Return list-metadata overrides for MODEL from ENTRY.
PROVIDER-TYPE selects which name field is the description.  The plist may
contain :description, :context-window, :input-cost, :output-cost,
:mime-types, :set-mime-types, and :capability-changes."
  (let ((spec nil)
        (changes nil)
        (reasoning (or (assq 'reasoning entry) (assq 'thinking entry)))
        (tool-call (assq 'tool_call entry))
        (modalities (assq 'modalities entry))
        (pricing (alist-get 'pricing entry))
        (context (cl-loop for key in '(max_input_tokens context_length
                                                        context_window
                                                        inputTokenLimit)
                          for cell = (assq key entry)
                          when (and cell
                                    (numberp (cdr cell))
                                    (> (cdr cell) 0))
                          return (cdr cell)))
        (name (pcase provider-type
                ('gemini (alist-get 'displayName entry))
                (_ (or (alist-get 'name entry)
                       (alist-get 'display_name entry)
                       (alist-get 'displayName entry))))))
    (when (and (stringp name)
               (not (string-empty-p name))
               (not (equal name (symbol-name model))))
      (setq spec (append spec (list :description name))))
    (when-let* ((window (gptel-model-updater-metadata--context-tokens context)))
      (setq spec (append spec (list :context-window window))))
    (when-let* ((cell (assq 'prompt pricing))
                (cost (gptel-model-updater-metadata--per-token-cost (cdr cell))))
      (setq spec (append spec (list :input-cost cost))))
    (when-let* ((cell (assq 'completion pricing))
                (cost (gptel-model-updater-metadata--per-token-cost (cdr cell))))
      (setq spec (append spec (list :output-cost cost))))
    (when reasoning
      (push (cons 'reasoning
                  (gptel-model-updater-metadata--truthy-p (cdr reasoning)))
            changes))
    (when tool-call
      (push (cons 'tool-use
                  (gptel-model-updater-metadata--truthy-p (cdr tool-call)))
            changes))
    (when modalities
      (let* ((input (mapcar (lambda (item)
                              (if (symbolp item) item (intern (format "%s" item))))
                            (gptel-model-updater-metadata--sequence
                             (alist-get 'input (cdr modalities)))))
             (media (seq-intersection input '(image pdf audio video))))
        (setq spec (append spec
                           (list :set-mime-types t
                                 :mime-types
                                 (delete-dups
                                  (apply #'append
                                         (mapcar (lambda (modality)
                                                   (alist-get modality
                                                              gptel-model-updater-metadata--mime-types))
                                                 input))))))
        (push (cons 'media (and media t)) changes)))
    (when changes
      (setq spec (append spec (list :capability-changes (nreverse changes)))))
    spec))

(defun gptel-model-updater-metadata-apply-list
    (models raw-index provider-type originals)
  "Apply list metadata in RAW-INDEX onto MODELS.
RAW-INDEX is an alist of (MODEL . ENTRY).  PROVIDER-TYPE selects name
fields.  ORIGINALS is an alist of (MODEL . PLIST) taken before models.dev
metadata was applied.  List fields override models.dev.  When
`gptel-model-updater-metadata-overwrite-existing' is nil, properties already
present in ORIGINALS are left alone.  Capability flags carried by the list
change only those flags."
  (dolist (model models)
    (when-let* ((entry (alist-get model raw-index))
                (spec (gptel-model-updater-metadata--list-spec
                       entry model provider-type)))
      (let ((plist (copy-sequence (symbol-plist model)))
            (original (alist-get model originals))
            (overwrite gptel-model-updater-metadata-overwrite-existing))
        (dolist (key '(:description :context-window :input-cost :output-cost))
          (when (and (plist-member spec key)
                     (or overwrite (not (plist-member original key))))
            (setq plist (gptel-model-updater-metadata--plist-set
                         plist key (plist-get spec key)))))
        (when (and (plist-get spec :set-mime-types)
                   (or overwrite (not (plist-member original :mime-types))))
          (setq plist (gptel-model-updater-metadata--plist-set
                       plist :mime-types (plist-get spec :mime-types))))
        (when (and (plist-get spec :capability-changes)
                   (or overwrite
                       (not (plist-member original :capabilities))))
          (setq plist (gptel-model-updater-metadata--plist-set
                       plist :capabilities
                       (gptel-model-updater-metadata--adjust-capabilities
                        (plist-get plist :capabilities)
                        (plist-get spec :capability-changes)))))
        (setf (symbol-plist model) plist))))
  models)

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
                    (gptel-model-updater-metadata--merge
                     (symbol-plist model)
                     plist))
              (throw 'found t)))))))
  models)

(provide 'gptel-model-updater-metadata)
;;; gptel-model-updater-metadata.el ends here
