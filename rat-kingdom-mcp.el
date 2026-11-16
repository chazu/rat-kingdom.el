;;; rat-kingdom-mcp.el --- Tools for agents, by role -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A small Model Context Protocol endpoint inside Emacs (DESIGN.md,
;; section 9).  Each run is granted a token, and its agent is given the
;; URL http://127.0.0.1:PORT/mcp/TOKEN.  The token tells the endpoint
;; which run is calling and in which role, so an agent is offered only
;; its role's tools, and a tool knows who called it without being told.
;;
;; A tool is defined with `rat-kingdom-mcp-define-tool'.  Its function
;; takes the caller's context, a property list with `:run' and `:role',
;; and the arguments as an alist, and returns the text to show the agent.
;; If it signals an error, the agent sees the message as a failed call.
;;
;; The endpoint listens on the loopback interface only and answers
;; plain JSON over HTTP POST, which is all an agent needs for tools.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst rat-kingdom-mcp-server-name "rat-kingdom"
  "The name agents know the endpoint by.
Claude Code calls its tools mcp__rat-kingdom__NAME.")

;;;; Tools

(defvar rat-kingdom-mcp--tools nil
  "The defined tools, as property lists, in definition order.")

(cl-defun rat-kingdom-mcp-define-tool (name &key description args roles function)
  "Define the tool NAME, replacing any tool of that name offered to ROLES.
Tools of one name may be defined for different roles, so that a role
is offered its own version: the foreman's `status' is not the king's.
A role is never offered two tools of one name: a definition replaces
every tool of its name that shares a role with it.
DESCRIPTION tells the agent what it does.  ARGS is a list of property
lists with `:name', `:type' (a symbol such as `string', `integer',
`array' or `object'), `:description' and `:optional'.  An argument of
the type `array' may have `:items', the schema of its elements: a
property list like an argument's, without `:name' and `:optional'.
One of the type `object' may have `:properties', a list like ARGS.
ROLES lists the roles, as symbols, that are offered the tool.
FUNCTION is called with the caller's context and an alist of
arguments, and returns text.  An array argument arrives as a list and
an object as an alist."
  (let ((tool (list :name name :description description :args args
                    :roles roles :function function)))
    (setq rat-kingdom-mcp--tools
          (append (cl-remove-if
                   (lambda (other)
                     (and (equal (plist-get other :name) name)
                          (or (cl-intersection (plist-get other :roles) roles)
                              (equal (plist-get other :roles) roles))))
                   rat-kingdom-mcp--tools)
                  (list tool)))
    tool))

(defun rat-kingdom-mcp-tool-names (role)
  "Return the names of the tools offered to ROLE, in definition order."
  (mapcar (lambda (tool) (plist-get tool :name))
          (rat-kingdom-mcp--tools-for role)))

(defun rat-kingdom-mcp--tools-for (role)
  "Return the tools offered to ROLE."
  (cl-remove-if-not (lambda (tool) (memq role (plist-get tool :roles)))
                    rat-kingdom-mcp--tools))

(defun rat-kingdom-mcp--value-schema (spec)
  "Return the JSON Schema of a value SPEC describes.
SPEC is a property list with `:type' and, if it has them,
`:description', `:items' for an array and `:properties' for an object."
  (let ((type (plist-get spec :type)))
    (append (list :type (symbol-name type))
            (and (plist-get spec :description)
                 (list :description (plist-get spec :description)))
            (and (eq type 'array) (plist-get spec :items)
                 (list :items (rat-kingdom-mcp--value-schema
                               (plist-get spec :items))))
            (and (eq type 'object)
                 (cddr (rat-kingdom-mcp--schema (plist-get spec :properties)))))))

(defun rat-kingdom-mcp--schema (args)
  "Return the JSON Schema for a tool taking ARGS."
  (let ((properties (make-hash-table :test #'equal))
        required)
    (dolist (arg args)
      (puthash (plist-get arg :name) (rat-kingdom-mcp--value-schema arg)
               properties)
      (unless (plist-get arg :optional)
        (push (plist-get arg :name) required)))
    (list :type "object" :properties properties
          :required (vconcat (nreverse required)))))

(defun rat-kingdom-mcp-call (context name arguments)
  "Call the tool NAME for the caller CONTEXT with ARGUMENTS, an alist.
Return (TEXT . FAILED).  A tool the caller's role is not offered does
not exist as far as the caller can tell."
  (let ((tool (cl-find name (rat-kingdom-mcp--tools-for
                             (plist-get context :role))
                       :key (lambda (tool) (plist-get tool :name))
                       :test #'equal)))
    (if (not tool)
        (cons (format "Error: unknown tool %s" name) t)
      (condition-case err
          (progn
            (dolist (arg (plist-get tool :args))
              (unless (or (plist-get arg :optional)
                          (alist-get (intern (plist-get arg :name)) arguments))
                (error "Missing argument: %s" (plist-get arg :name))))
            (cons (funcall (plist-get tool :function) context arguments) nil))
        (error (cons (format "Error: %s" (error-message-string err)) t))))))

(defun rat-kingdom-mcp-tool-list (role)
  "Return the tools offered to ROLE as `tools/list' describes them.
Each is a property list with `:name', `:description' and
`:inputSchema'."
  (mapcar (lambda (tool)
            (list :name (plist-get tool :name)
                  :description (plist-get tool :description)
                  :inputSchema (rat-kingdom-mcp--schema (plist-get tool :args))))
          (rat-kingdom-mcp--tools-for role)))

;;;; Who is calling

(defvar rat-kingdom-mcp--grants (make-hash-table :test #'equal)
  "Hash table from token to the caller's context.")

(defun rat-kingdom-mcp-revoke (run)
  "Take away the token granted to RUN, if any."
  (maphash (lambda (token context)
             (when (equal (plist-get context :run) run)
               (remhash token rat-kingdom-mcp--grants)))
           (copy-hash-table rat-kingdom-mcp--grants)))

(defun rat-kingdom-mcp-grant (run role)
  "Grant RUN, in ROLE, a token and return it.
Any token RUN had before stops working."
  (rat-kingdom-mcp-revoke run)
  (let ((token (secure-hash 'sha256
                            (format "%s%s%s%s" run (random) (float-time)
                                    (emacs-pid)))))
    (puthash token (list :run run :role role) rat-kingdom-mcp--grants)
    token))

;;;; JSON-RPC

(defun rat-kingdom-mcp--rpc (context message)
  "Answer the JSON-RPC MESSAGE, an alist, for the caller CONTEXT.
Return the reply as a property list, or nil for a notification."
  (let ((id (alist-get 'id message 'none))
        (params (alist-get 'params message)))
    (cl-flet ((result (value) (list :jsonrpc "2.0" :id id :result value)))
      (unless (eq id 'none)
        (pcase (alist-get 'method message)
          ("initialize"
           (result (list :protocolVersion
                         (or (alist-get 'protocolVersion params) "2025-06-18")
                         :capabilities (list :tools (make-hash-table))
                         :serverInfo (list :name rat-kingdom-mcp-server-name
                                           :version "0.1.0"))))
          ("ping" (result (make-hash-table)))
          ("tools/list"
           (result (list :tools (vconcat (rat-kingdom-mcp-tool-list
                                          (plist-get context :role))))))
          ("tools/call"
           (pcase-let ((`(,text . ,failed)
                        (rat-kingdom-mcp-call context (alist-get 'name params)
                                              (alist-get 'arguments params))))
             (result (list :content (vector (list :type "text" :text text))
                           :isError (if failed t :false)))))
          (method
           (list :jsonrpc "2.0" :id id
                 :error (list :code -32601
                              :message (format "Method not found: %s"
                                               method)))))))))

;;;; HTTP

(defvar rat-kingdom-mcp--server nil
  "The listening process, or nil.")

(defun rat-kingdom-mcp--respond (process status &optional body)
  "Send an HTTP response with STATUS and the JSON text BODY on PROCESS."
  (when (process-live-p process)
    (let ((bytes (if body (encode-coding-string body 'utf-8) "")))
      (process-send-string
       process
       (concat (format "HTTP/1.1 %s\r\n" status)
               (if body "Content-Type: application/json\r\n" "")
               (format "Content-Length: %d\r\n\r\n" (length bytes))
               bytes)))))

(defun rat-kingdom-mcp--handle (process method path headers body)
  "Answer the HTTP request METHOD PATH with HEADERS and BODY on PROCESS."
  (let* ((origin (cdr (assoc "origin" headers)))
         (token (and (string-prefix-p "/mcp/" path) (substring path 5)))
         (context (and token (gethash token rat-kingdom-mcp--grants))))
    (cond
     ;; Refuse web pages, as the protocol asks, against DNS rebinding.
     ((and origin
           (not (string-match-p
                 "\\`https?://\\(localhost\\|127\\.0\\.0\\.1\\)\\(:[0-9]+\\)?\\'"
                 origin)))
      (rat-kingdom-mcp--respond process "403 Forbidden"))
     ((not context) (rat-kingdom-mcp--respond process "404 Not Found"))
     ((equal method "DELETE") (rat-kingdom-mcp--respond process "200 OK"))
     ((not (equal method "POST"))
      (rat-kingdom-mcp--respond process "405 Method Not Allowed"))
     (t
      (let ((message (ignore-errors
                       (json-parse-string body :object-type 'alist
                                          :array-type 'list :null-object nil
                                          :false-object nil))))
        (if (not (and (consp message) (symbolp (caar message))))
            (rat-kingdom-mcp--respond process "400 Bad Request")
          (let ((reply (rat-kingdom-mcp--rpc context message)))
            (if reply
                (rat-kingdom-mcp--respond process "200 OK"
                                          (json-serialize reply))
              (rat-kingdom-mcp--respond process "202 Accepted")))))))))

(defun rat-kingdom-mcp--take-request (process)
  "Remove one whole HTTP request from PROCESS's input and return it.
Return nil if none has arrived in full.  The request is
\(METHOD PATH HEADERS BODY), the header names in lower case."
  (let* ((input (process-get process :input))
         (end (and input (string-search "\r\n\r\n" input))))
    (when end
      (let* ((lines (split-string (substring input 0 end) "\r\n"))
             (start (split-string (car lines) " "))
             (headers
              (delq nil
                    (mapcar
                     (lambda (line)
                       (when (string-match "\\`\\([^:]+\\):[ \t]*\\(.*\\)\\'"
                                           line)
                         (cons (downcase (match-string 1 line))
                               (match-string 2 line))))
                     (cdr lines))))
             (size (string-to-number
                    (or (cdr (assoc "content-length" headers)) "0")))
             (body (+ end 4)))
        (when (>= (length input) (+ body size))
          (process-put process :input (substring input (+ body size)))
          (list (car start) (cadr start) headers
                (decode-coding-string (substring input body (+ body size))
                                      'utf-8)))))))

(defun rat-kingdom-mcp--filter (process chunk)
  "Collect CHUNK on PROCESS and answer each whole HTTP request."
  (process-put process :input (concat (process-get process :input) chunk))
  (let (request)
    (while (setq request (rat-kingdom-mcp--take-request process))
      (condition-case err
          (apply #'rat-kingdom-mcp--handle process request)
        (error
         (rat-kingdom-mcp--respond
          process "500 Internal Server Error"
          (json-serialize (list :error (error-message-string err)))))))))

(defun rat-kingdom-mcp-url (token)
  "Return the endpoint's URL for TOKEN, starting the endpoint if needed."
  (unless (process-live-p rat-kingdom-mcp--server)
    (setq rat-kingdom-mcp--server
          (make-network-process
           :name "rat-kingdom-mcp" :server t :host "127.0.0.1" :service 0
           :family 'ipv4 :coding 'binary :noquery t
           :filter #'rat-kingdom-mcp--filter)))
  (format "http://127.0.0.1:%d/mcp/%s"
          (process-contact rat-kingdom-mcp--server :service) token))

(defun rat-kingdom-mcp-stop ()
  "Stop the endpoint and forget every token."
  (when (process-live-p rat-kingdom-mcp--server)
    (delete-process rat-kingdom-mcp--server))
  (setq rat-kingdom-mcp--server nil)
  (clrhash rat-kingdom-mcp--grants))

(provide 'rat-kingdom-mcp)
;;; rat-kingdom-mcp.el ends here
